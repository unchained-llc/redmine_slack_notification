# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'yaml'
require 'digest'

module RedmineSlackNotification
  EVENT_KEYS = %w[
    issue_created issue_updated issue_deleted comment_added relation_added relation_removed
    status_changed assignee_changed priority_changed due_date_changed start_date_changed
    version_changed subject_changed description_changed custom_field_changed
    attachment_added attachment_removed parent_changed child_added child_removed
    wiki_created wiki_updated wiki_deleted news_created news_updated news_deleted news_comment_added
    time_entry_created time_entry_updated time_entry_deleted
    version_created version_updated version_deleted project_updated
  ].freeze
  ISSUE_DETAIL_EVENTS = %w[
    relation_added relation_removed status_changed assignee_changed priority_changed
    due_date_changed start_date_changed version_changed subject_changed description_changed
    custom_field_changed attachment_added attachment_removed parent_changed child_added child_removed
  ].freeze
  EVENT_FALLBACKS = ISSUE_DETAIL_EVENTS.to_h { |event| [event, 'issue_updated'] }.freeze
  DEFAULT_DISABLED_EVENTS = %w[wiki_deleted news_deleted time_entry_deleted version_deleted].freeze

  class SlackApiError < StandardError
    attr_reader :code

    def initialize(method, status, result)
      @code = result['error']
      details = Array(result.dig('response_metadata', 'messages')).join('; ')
      super("Slack #{method} returned #{status}: #{@code || 'unknown error'}#{details.empty? ? '' : " (#{details})"}")
    end

    def unready_image_file?
      %w[invalid_blocks invalid_attachments].include?(code) && message.match?(/invalid (?:slack file|file type)/)
    end
  end

  module_function

  def config
    @config ||= begin
      path = config_paths.find { |candidate| File.exist?(candidate) }
      unless path
        Rails.logger.warn("RedmineSlackNotification: config file not found: #{config_paths.join(', ')}")
        {}
      else
        YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
      end
    rescue StandardError => e
      Rails.logger.error("RedmineSlackNotification: cannot load #{path}: #{e.class}: #{e.message}")
      {}
    end
  end

  def config_paths
    [
      Rails.root.join('config', 'redmine_slack_notification.yml'),
      File.expand_path('../config/redmine_slack_notification.yml', __dir__)
    ]
  end

  def config_path
    config_paths.first
  end

  def bot_token
    ENV['SLACK_BOT_TOKEN'].to_s.strip.presence || config.dig('slack', 'bot_token').to_s.strip
  end

  def channel_id(project)
    return '' unless project

    project_config = config.fetch('projects', {}).fetch(project.identifier.to_s, {})
    project_channel = project_config.is_a?(Hash) ? project_config['channel_id'] : nil
    (project_channel.presence || config.dig('slack', 'default_channel_id')).to_s.strip
  end

  def user_mapping
    config.fetch('users', {})
  end

  def slack_user_id_for_name(name)
    return nil unless config.dig('slack', 'auto_map_users_by_name') == true

    key = name.to_s.strip.downcase
    return nil if key.empty?

    ids = slack_user_directory[key]
    ids.first if ids&.length == 1
  end

  def slack_user_directory
    token = bot_token
    return {} if token.empty?

    cache_key = "redmine_slack_notification/users/#{Digest::SHA256.hexdigest(token)}"
    Rails.cache.fetch(cache_key, expires_in: 600) do
      fetch_slack_user_directory(token)
    rescue StandardError => e
      Rails.logger.warn("RedmineSlackNotification: could not load Slack users: #{e.class}: #{e.message}")
      {}
    end
  end

  def fetch_slack_user_directory(token)
    directory = Hash.new { |hash, name| hash[name] = [] }
    cursor = nil
    seen_cursors = {}
    loop do
      params = { 'limit' => 200 }
      params['cursor'] = cursor if cursor
      response = slack_api('users.list', params, token, form: true, open_timeout: 2, read_timeout: 3)
      Array(response['members']).each do |member|
        next unless member.is_a?(Hash) && member['id'].to_s != ''
        next if member['deleted'] || member['is_bot'] || member['is_app_user'] || member['is_stranger']

        profile = member['profile'].is_a?(Hash) ? member['profile'] : {}
        [profile['display_name'], member['name']].each do |value|
          name = value.to_s.strip.downcase
          directory[name] << member['id'] unless name.empty? || directory[name].include?(member['id'])
        end
      end
      cursor = response.dig('response_metadata', 'next_cursor').to_s
      break if cursor.empty?

      raise 'Slack users.list returned a repeated cursor' if seen_cursors[cursor]

      seen_cursors[cursor] = true
    end
    directory.each_with_object({}) { |(name, ids), result| result[name] = ids }
  end

  def configured?(project)
    bot_token.present? && channel_id(project).present?
  end

  def event_enabled?(project, event)
    key = event.to_s
    raise ArgumentError, "Unknown Slack notification event: #{key}" unless EVENT_KEYS.include?(key)

    projects = config['projects']
    project_config = projects[project.identifier.to_s] if projects.is_a?(Hash) && project
    project_events = project_config['events'] if project_config.is_a?(Hash)
    fallback = EVENT_FALLBACKS[key]
    if project_events.is_a?(Hash)
      return project_events[key] != false if project_events.key?(key)
      return project_events[fallback] != false if fallback && project_events.key?(fallback)
    end

    events = config['events']
    if events.is_a?(Hash)
      return events[key] != false if events.key?(key)
      return events[fallback] != false if fallback && events.key?(fallback)
    end

    !DEFAULT_DISABLED_EVENTS.include?(key)
  end

  def enqueue(payload, project:, event: nil, image_names: [], journal_id: nil)
    return unless project
    return if event && !event_enabled?(project, event)

    RedmineSlackNotificationJob.perform_later(payload, project.id, image_names, journal_id)
  end

  def notify(payload, project: nil, image_names: [], journal_id: nil)
    token = bot_token
    channel = channel_id(project)
    unless token.present? && channel.present?
      Rails.logger.warn("RedmineSlackNotification: Slack API is not configured for project #{project&.identifier || '(none)'} (token/channel missing)")
      return
    end


    add_images(payload, image_names, journal_id, token) if image_names.present? && journal_id
    post_message(payload, channel, token)
  rescue StandardError => e
    Rails.logger.error("RedmineSlackNotification: #{e.class}: #{e.message}")
    raise
  end

  def post_message(payload, channel, token)
    image_ids = Array(payload.dig('attachments', 0, 'blocks')).each_with_object([]) do |block, ids|
      ids << block.dig('slack_file', 'id') if block['type'] == 'image'
    end.compact.uniq
    request = payload.merge('channel' => channel)
    if image_ids.any?
      # A private Slack file becomes available to the channel when referenced
      # in a top-level image element. Keep the colored attachment from the
      # first post, then remove these temporary small previews.
      request['blocks'] = image_ids.map do |file_id|
        {
          'type' => 'section',
          'text' => { 'type' => 'plain_text', 'text' => '画像を準備中' },
          'accessory' => { 'type' => 'image', 'slack_file' => { 'id' => file_id }, 'alt_text' => '画像' }
        }
      end
    end

    posted = post_with_image_retry(request, token)
    return posted if image_ids.empty?

    begin
      update = {
        'channel' => channel,
        'ts' => posted.fetch('ts'),
        'text' => '',
        'blocks' => [],
        'attachments' => payload.fetch('attachments')
      }
      post_with_image_retry(update, token, method: 'chat.update')
    rescue StandardError => e
      # The initial message already contains the complete colored card. Do
      # not retry the job and post a second notification if cleanup fails.
      Rails.logger.error("RedmineSlackNotification: could not remove temporary image previews from #{channel}/#{posted['ts']}: #{e.class}: #{e.message}")
    end
    posted
  end

  def post_with_image_retry(request, token, method: 'chat.postMessage')
    retries = 0
    begin
      slack_api(method, request, token)
    rescue SlackApiError => e
      image_message = Array(request['blocks']).any? { |block| block['type'] == 'image' || block.dig('accessory', 'slack_file', 'id') } ||
        Array(request.dig('attachments', 0, 'blocks')).any? { |block| block['type'] == 'image' }
      raise unless image_message && e.unready_image_file? && retries < 3

      sleep([1, 2, 4][retries])
      retries += 1
      retry
    end
  end

  def add_images(payload, image_names, journal_id, token)
    journal = Journal.find_by(id: journal_id)
    return unless journal && journal.journalized.is_a?(Issue) && !journal.private_notes? && !journal.journalized.is_private?

    attachments = journal.attachments.each_with_object({}) { |attachment, indexed| indexed[attachment.filename] = attachment }
    blocks = payload['blocks'] || payload.dig('attachments', 0, 'blocks')
    return unless blocks

    eligible_names = image_names.to_h { |name| [name.downcase, name] }
    upload_results = {}
    ordered_blocks = blocks.flat_map do |block|
      markdown_block = block['type'] == 'markdown'
      content = markdown_block ? block['text'] : block.dig('text', 'text')
      next [block] unless content.is_a?(String)

      with_text = lambda do |value|
        markdown_block ? block.merge('text' => value) : block.merge('text' => block['text'].merge('text' => value))
      end

      pieces = []
      current_text = +''
      cursor = 0
      found_eligible = false
      content.to_enum(:scan, /!\[[^\]\n]*\]\(([^)\n]+)\)/i).each do
        match = Regexp.last_match
        current_text << content[cursor...match.begin(0)]
        name = eligible_names[match[1].downcase]
        if name
          found_eligible = true
          attachment = attachments[name]
          file_id = upload_results.fetch(name) { upload_results[name] = upload_image(attachment, token) if attachment }
          if file_id
            text_before = current_text.strip
            pieces << with_text.call(text_before) unless text_before.empty?
            pieces << { 'type' => 'image', 'slack_file' => { 'id' => file_id }, 'alt_text' => name[0, 2000] }
            current_text = +''
          else
            path = attachment ? "/attachments/#{attachment.id}" : "/issues/#{journal.journalized.id}"
            if markdown_block
              label = name.gsub(/[\\\[\]]/) { |character| "\\#{character}" }
              current_text << "[画像: #{label}](#{RedmineSlackNotification::Formatter.url(path)})"
            else
              current_text << "<#{RedmineSlackNotification::Formatter.url(path)}|画像: #{RedmineSlackNotification::Formatter.text(name)}>"
            end
          end
        else
          current_text << match[0]
        end
        cursor = match.end(0)
      end
      next [block] unless found_eligible

      current_text << content[cursor..]
      final_text = current_text.strip
      pieces << with_text.call(final_text) unless final_text.empty?
      pieces.empty? ? [block] : pieces
    end
    blocks.replace(ordered_blocks)
  end

  def upload_image(attachment, token)
    return unless attachment.filename.match?(/\.(?:png|jpe?g|gif)\z/i)

    path = attachment.diskfile
    size = File.size(path)
    return if size.zero? || size > 20 * 1024 * 1024

    ticket = slack_api('files.getUploadURLExternal', { 'filename' => attachment.filename, 'length' => size }, token, form: true)
    upload_uri = URI(ticket.fetch('upload_url'))
    raise 'Unexpected Slack upload URL' unless upload_uri.is_a?(URI::HTTPS) && upload_uri.host == 'files.slack.com'

    File.open(path, 'rb') do |file|
      request = Net::HTTP::Post.new(upload_uri.request_uri)
      request['Content-Type'] = 'application/octet-stream'
      request.body_stream = file
      request.content_length = size
      Net::HTTP.start(upload_uri.host, upload_uri.port, use_ssl: true, open_timeout: 3, read_timeout: 30) do |http|
        response = http.request(request)
        raise "Slack upload returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      end
    end

    file_id = ticket.fetch('file_id')
    slack_api('files.completeUploadExternal', { 'files' => [{ 'id' => file_id, 'title' => attachment.filename }] }, token, form: true)
    file_id
  rescue StandardError => e
    Rails.logger.warn("RedmineSlackNotification: image upload failed for attachment #{attachment.id}: #{e.class}: #{e.message}")
    nil
  end

  def slack_api(method, body, token, form: false, open_timeout: 3, read_timeout: 10)
    uri = URI("https://slack.com/api/#{method}")
    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    if form
      request.set_form_data(body.transform_values { |value| value.is_a?(Array) || value.is_a?(Hash) ? value.to_json : value.to_s })
    else
      request['Content-Type'] = 'application/json; charset=utf-8'
      request.body = body.to_json
    end
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: open_timeout, read_timeout: read_timeout) do |http|
      response = http.request(request)
      result = JSON.parse(response.body)
      unless response.is_a?(Net::HTTPSuccess) && result['ok']
        raise SlackApiError.new(method, response.code, result)
      end

      result
    end
  end
end

require_relative 'redmine_slack_notification/issue_patch'
require_relative 'redmine_slack_notification/journal_patch'
require_relative 'redmine_slack_notification/wiki_content_patch'
require_relative 'redmine_slack_notification/generic_patches'


module RedmineSlackNotification
  module_function

  def install_patches

    Issue.include RedmineSlackNotification::IssuePatch if defined?(Issue) && !(Issue < RedmineSlackNotification::IssuePatch)
    Journal.include RedmineSlackNotification::JournalPatch if defined?(Journal) && !(Journal < RedmineSlackNotification::JournalPatch)
    WikiContent.include RedmineSlackNotification::WikiContentPatch if defined?(WikiContent) && !(WikiContent < RedmineSlackNotification::WikiContentPatch)
    WikiPage.include RedmineSlackNotification::WikiPagePatch if defined?(WikiPage) && !(WikiPage < RedmineSlackNotification::WikiPagePatch)
    News.include RedmineSlackNotification::NewsPatch if defined?(News) && !(News < RedmineSlackNotification::NewsPatch)
    TimeEntry.include RedmineSlackNotification::TimeEntryPatch if defined?(TimeEntry) && !(TimeEntry < RedmineSlackNotification::TimeEntryPatch)
    Version.include RedmineSlackNotification::VersionPatch if defined?(Version) && !(Version < RedmineSlackNotification::VersionPatch)
    Project.include RedmineSlackNotification::ProjectPatch if defined?(Project) && !(Project < RedmineSlackNotification::ProjectPatch)
    Comment.include RedmineSlackNotification::CommentPatch if defined?(Comment) && !(Comment < RedmineSlackNotification::CommentPatch)
  end
end

Rails.application.config.to_prepare { RedmineSlackNotification.install_patches }
Rails.application.config.after_initialize { RedmineSlackNotification.install_patches }
