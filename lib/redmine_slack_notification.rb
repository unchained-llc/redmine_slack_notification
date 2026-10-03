# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'yaml'
require 'digest'

module RedmineSlackNotification
  EVENT_PATHS = {
    'issue_created' => %w[issue created],
    'issue_updated' => %w[issue updated other_changed],
    'issue_deleted' => %w[issue deleted],
    'comment_added' => %w[issue comment added],
    'comment_updated' => %w[issue comment updated],
    'comment_deleted' => %w[issue comment deleted],
    'relation_added' => %w[issue updated relation added],
    'relation_removed' => %w[issue updated relation removed],
    'status_changed' => %w[issue updated status_changed],
    'assignee_changed' => %w[issue updated assignee_changed],
    'priority_changed' => %w[issue updated priority_changed],
    'category_changed' => %w[issue updated category_changed],
    'due_date_changed' => %w[issue updated due_date_changed],
    'start_date_changed' => %w[issue updated start_date_changed],
    'version_changed' => %w[issue updated version_changed],
    'subject_changed' => %w[issue updated subject_changed],
    'description_changed' => %w[issue updated description_changed],
    'custom_field_changed' => %w[issue updated custom_field_changed],
    'attachment_added' => %w[issue updated attachment added],
    'attachment_removed' => %w[issue updated attachment removed],
    'parent_changed' => %w[issue updated parent_changed],
    'child_added' => %w[issue updated child added],
    'child_removed' => %w[issue updated child removed],
    'wiki_created' => %w[wiki created],
    'wiki_updated' => %w[wiki updated],
    'wiki_deleted' => %w[wiki deleted],
    'news_created' => %w[news created],
    'news_updated' => %w[news updated],
    'news_deleted' => %w[news deleted],
    'news_comment_added' => %w[news comment added],
    'news_comment_updated' => %w[news comment updated],
    'news_comment_deleted' => %w[news comment deleted],
    'time_entry_created' => %w[time_entry created],
    'time_entry_updated' => %w[time_entry updated],
    'time_entry_deleted' => %w[time_entry deleted],
    'version_created' => %w[version created],
    'version_updated' => %w[version updated],
    'version_deleted' => %w[version deleted],
    'project_updated' => %w[project updated]
  }.transform_values(&:freeze).freeze
  EVENT_KEYS = EVENT_PATHS.keys.freeze
  ISSUE_DETAIL_EVENTS = EVENT_PATHS.select do |key, path|
    key != 'issue_updated' && path.first(2) == %w[issue updated]
  end.keys.freeze
  ISSUE_UPDATE_PARENT_PATH = %w[issue updated enabled].freeze
  DEFAULT_DISABLED_EVENTS = %w[wiki_deleted news_deleted time_entry_deleted version_deleted].freeze
  BODY_DIFF_PATHS = {
    issue_description: %w[issue description], issue_comment: %w[issue comment],
    wiki_body: %w[wiki body], news_description: %w[news description], news_comment: %w[news comment]
  }.freeze

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
        Rails.logger&.warn("RedmineSlackNotification: config file not found: #{config_paths.join(', ')}")
        {}
      else
        YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
      end
    rescue StandardError => e
      Rails.logger&.error("RedmineSlackNotification: cannot load #{path}: #{e.class}: #{e.message}")
      {}
    end
  end

  def config_paths
    [
      (Rails.root.join('config', 'redmine_slack_notification.yml') if Rails.respond_to?(:root)),
      File.expand_path('../config/redmine_slack_notification.yml', __dir__)
    ].compact
  end

  def config_path
    config_paths.first
  end

  def project_config(project)
    return {} unless project

    projects = config['projects']
    settings = projects[project.identifier.to_s] if projects.is_a?(Hash)
    settings.is_a?(Hash) ? settings : {}
  end

  def merge_config(base, overrides)
    return overrides unless base.is_a?(Hash) && overrides.is_a?(Hash)

    base.merge(overrides) do |_key, original, replacement|
      merge_config(original, replacement)
    end
  end

  def with_project(project)
    previous = Thread.current[:redmine_slack_notification_project]
    Thread.current[:redmine_slack_notification_project] = project
    yield
  ensure
    Thread.current[:redmine_slack_notification_project] = previous
  end

  def effective_config(project = Thread.current[:redmine_slack_notification_project])
    project ? merge_config(config, project_config(project)) : config
  end

  def bot_token(project = Thread.current[:redmine_slack_notification_project])
    project_slack = project_config(project)['slack']
    project_token = project_slack['bot_token'] if project_slack.is_a?(Hash)
    project_token.to_s.strip.presence || ENV['SLACK_BOT_TOKEN'].to_s.strip.presence ||
      config.dig('slack', 'bot_token').to_s.strip
  end

  def body_diff_enabled?(kind = nil)
    setting = effective_config.dig('slack', 'body_diff')
    return setting != false unless setting.is_a?(Hash)
    return true unless kind

    path = BODY_DIFF_PATHS.fetch(kind)
    path.each do |key|
      return false if setting == false
      return true unless setting.is_a?(Hash) && setting.key?(key)

      setting = setting[key]
    end
    setting != false
  end

  def channel_id(project)
    return '' unless project

    settings = project_config(project)
    project_slack = settings['slack']
    project_channel = project_slack['default_channel_id'].to_s.strip.presence if project_slack.is_a?(Hash)
    project_channel ||= settings['channel_id'].to_s.strip.presence
    (project_channel.presence || config.dig('slack', 'default_channel_id')).to_s.strip
  end

  def user_mapping
    mapping = effective_config['users']
    mapping.is_a?(Hash) ? mapping : {}
  end

  def slack_user_id_for(user)
    return unless user.is_a?(User)

    mapping = user_mapping
    id = mapping[user.login.to_s] || mapping[user.mail.to_s]
    id = slack_user_id_for_name(user.login) if id == false || id.to_s.strip.empty?
    id = id.to_s.strip
    id if id.match?(/\A[UW][A-Z0-9]+\z/)
  end

  def due_reminder_settings(project = nil)
    settings = effective_config(project)['due_reminders']
    settings = {} unless settings.is_a?(Hash)
    days = Integer(settings.fetch('days', 3), exception: false)
    { enabled: settings['enabled'] != false, days: days && days.between?(0, 365) ? days : 3 }
  end

  def due_reminder_max_days
    projects = config['projects']
    project_days = projects.is_a?(Hash) ? projects.values.each_with_object([]) do |settings, days_list|
      next unless settings.is_a?(Hash) && settings['due_reminders'].is_a?(Hash)

      days = Integer(settings['due_reminders']['days'], exception: false)
      days_list << days if days && days.between?(0, 365)
    end : []
    ([due_reminder_settings[:days]] + project_days).max
  end

  def due_reminder_filter_scope(scope, options)
    scope = scope.where(project_id: options['project_id']) if options.key?('project_id')
    scope = scope.where(tracker_id: options['tracker_id']) if options.key?('tracker_id')
    scope = scope.where(fixed_version_id: options['version_ids']) if options.key?('version_ids')
    scope
  end

  def slack_user_id_for_name(name)
    return nil unless effective_config.dig('slack', 'auto_map_users_by_name') == true

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
    bot_token(project).present? && channel_id(project).present?
  end

  def event_enabled?(project, event)
    key = event.to_s
    raise ArgumentError, "Unknown Slack notification event: #{key}" unless EVENT_KEYS.include?(key)

    projects = config['projects']
    project_config = projects[project.identifier.to_s] if projects.is_a?(Hash) && project
    project_events = project_config['events'] if project_config.is_a?(Hash)
    events = config['events']
    if key == 'issue_updated' || ISSUE_DETAIL_EVENTS.include?(key)
      return false unless configured_event_enabled?(project_events, events, ISSUE_UPDATE_PARENT_PATH,
                                                    legacy_key: 'issue_updated', default: true)
    end

    configured_event_enabled?(project_events, events, EVENT_PATHS.fetch(key),
                              legacy_key: key == 'issue_updated' ? nil : key,
                              default: !DEFAULT_DISABLED_EVENTS.include?(key))
  end

  def configured_event_enabled?(project_events, events, path, legacy_key:, default:)
    [project_events, events].each do |scope|
      next unless scope.is_a?(Hash)

      found, value = nested_event_value(scope, path)
      return value != false if found
      return scope[legacy_key] != false if legacy_key && scope.key?(legacy_key)
    end

    default
  end

  def nested_event_value(scope, path)
    path.each do |part|
      return [false, nil] unless scope.is_a?(Hash) && scope.key?(part)

      scope = scope[part]
    end
    [true, scope]
  end

  def enqueue(payload, project:, event: nil, image_names: [], journal_id: nil, issue_id: nil)
    return unless project
    return if event && !event_enabled?(project, event)

    # Keep the four-argument job contract for workers still running the
    # previous release. Journal IDs are positive; a negative ID identifies
    # an Issue whose attachments belong to its creation notification.
    image_source_id = issue_id ? -issue_id : journal_id
    RedmineSlackNotificationJob.perform_later(payload, project.id, image_names, image_source_id)
  end

  def notify(payload, project: nil, image_names: [], journal_id: nil, issue_id: nil)
    with_project(project) do
      token = bot_token(project)
      channel = channel_id(project)
      unless token.present? && channel.present?
        Rails.logger.warn("RedmineSlackNotification: Slack API is not configured for project #{project&.identifier || '(none)'} (token/channel missing)")
        return
      end

      add_images(payload, image_names, journal_id, token, issue_id: issue_id) if image_names.present? && (journal_id || issue_id)
      post_message(payload, channel, token)
    end
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
          'text' => { 'type' => 'plain_text', 'text' => Formatter.message('images', 'preparing') },
          'accessory' => { 'type' => 'image', 'slack_file' => { 'id' => file_id }, 'alt_text' => Formatter.message('images', 'alt') }
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
      if payload.key?('metadata')
        update['metadata'] = payload['metadata']
        update['text'] = payload['text']
      end
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
      # Match Slack's Work Object documentation and official SDK transport:
      # entity metadata is JSON-serialized inside a URL-encoded form.
      work_object = request.dig('metadata', 'entities').is_a?(Array)
      result = work_object ? slack_api(method, request, token, form: true) : slack_api(method, request, token)
      if work_object
        message = result['message'].is_a?(Hash) ? result['message'] : {}
        metadata = message['metadata'].is_a?(Hash) ? message['metadata'] : {}
        summary = {
          method: method, ts: result['ts'], metadata_keys: metadata.keys,
          returned_entity_count: Array(metadata['entities']).length,
          attachment_count: Array(message['attachments']).length,
          warnings: Array(result.dig('response_metadata', 'warnings')),
          messages: Array(result.dig('response_metadata', 'messages'))
        }
        Rails.logger&.info("RedmineSlackNotification: Work Object response #{JSON.generate(summary)}")
      end
      result
    rescue SlackApiError => e
      image_message = Array(request['blocks']).any? { |block| block['type'] == 'image' || block.dig('accessory', 'slack_file', 'id') } ||
        Array(request.dig('attachments', 0, 'blocks')).any? { |block| block['type'] == 'image' }
      raise unless image_message && e.unready_image_file? && retries < 3

      sleep([1, 2, 4][retries])
      retries += 1
      retry
    end
  end

  def add_images(payload, image_names, journal_id, token, issue_id: nil)
    journal = Journal.find_by(id: journal_id) if journal_id
    issue = journal ? journal.journalized : Issue.find_by(id: issue_id)
    return unless issue.is_a?(Issue) && !issue.is_private?
    return if journal&.private_notes?

    source_attachments = journal ? journal.attachments : issue.attachments
    attachments = source_attachments.each_with_object({}) { |attachment, indexed| indexed[attachment.filename.downcase] = attachment }
    blocks = payload['blocks'] || payload.dig('attachments', 0, 'blocks')
    return unless blocks

    eligible_names = image_names.to_h { |name| [name.downcase, name] }
    upload_results = {}
    ordered_blocks = blocks.flat_map do |block|
      markdown_block = block['type'] == 'markdown'
      content = markdown_block ? block['text'] : block.dig('text', 'text')
      next [block] unless content.is_a?(String)
      next [block] if content.match?(/\A\*{1,2}[^\n]+\*{1,2}\n\n?`{3,}(?:diff)?\n/)

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
          attachment = attachments[name.downcase]
          file_id = upload_results.fetch(name) { upload_results[name] = upload_image(attachment, token) if attachment }
          if file_id
            text_before = current_text.strip
            pieces << with_text.call(text_before) unless text_before.empty?
            pieces << { 'type' => 'image', 'slack_file' => { 'id' => file_id }, 'alt_text' => name[0, 2000] }
            current_text = +''
          else
            path = attachment ? "/attachments/#{attachment.id}" : "/issues/#{issue.id}"
            if markdown_block
              label = name.gsub(/[\\\[\]]/) { |character| "\\#{character}" }
              image_label = Formatter.interpolate(Formatter.message('images', 'link_label'), { name: label },
                                                  fallback: Formatter::DEFAULT_MESSAGES.dig('images', 'link_label'))
              current_text << "[#{image_label}](#{Formatter.url(path)})"
            else
              image_label = Formatter.interpolate(Formatter.message('images', 'link_label'), { name: Formatter.text(name) },
                                                  fallback: Formatter::DEFAULT_MESSAGES.dig('images', 'link_label'))
              current_text << "<#{Formatter.url(path)}|#{image_label}>"
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
require_relative 'redmine_slack_notification/work_objects'
require_relative 'redmine_slack_notification/thread_comments'


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
