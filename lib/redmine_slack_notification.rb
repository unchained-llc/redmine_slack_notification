# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'yaml'

module RedmineSlackNotification
  class SlackApiError < StandardError
    attr_reader :code

    def initialize(method, status, result)
      @code = result['error']
      details = Array(result.dig('response_metadata', 'messages')).join('; ')
      super("Slack #{method} returned #{status}: #{@code || 'unknown error'}#{details.empty? ? '' : " (#{details})"}")
    end

    def invalid_slack_file?
      code == 'invalid_blocks' && message.include?('invalid slack file')
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

  def configured?(project)
    bot_token.present? && channel_id(project).present?
  end

  def enqueue(payload, project:, image_names: [], journal_id: nil)
    return unless project

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
    retries = 0
    begin
      slack_api('chat.postMessage', payload.merge('channel' => channel), token)
    rescue SlackApiError => e
      image_message = payload['blocks']&.any? { |block| block['type'] == 'image' }
      raise unless image_message && e.invalid_slack_file? && retries < 3

      sleep([1, 2, 4][retries])
      retries += 1
      retry
    end
  end

  def add_images(payload, image_names, journal_id, token)
    journal = Journal.find_by(id: journal_id)
    return unless journal && journal.journalized.is_a?(Issue) && !journal.private_notes? && !journal.journalized.is_private?

    attachments = journal.attachments.each_with_object({}) { |attachment, indexed| indexed[attachment.filename] = attachment }
    blocks = payload.dig('attachments', 0, 'blocks')
    return unless blocks

    image_added = false
    eligible_names = image_names.to_h { |name| [name.downcase, name] }
    upload_results = {}
    ordered_blocks = blocks.flat_map do |block|
      content = block.dig('text', 'text')
      next [block] unless content.is_a?(String)

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
            pieces << block.merge('text' => block['text'].merge('text' => text_before)) unless text_before.empty?
            pieces << { 'type' => 'image', 'slack_file' => { 'id' => file_id }, 'alt_text' => name[0, 2000] }
            current_text = +''
            image_added = true
          else
            path = attachment ? "/attachments/#{attachment.id}" : "/issues/#{journal.journalized.id}"
            current_text << "<#{RedmineSlackNotification::Formatter.url(path)}|画像: #{RedmineSlackNotification::Formatter.text(name)}>"
          end
        else
          current_text << match[0]
        end
        cursor = match.end(0)
      end
      next [block] unless found_eligible

      current_text << content[cursor..]
      final_text = current_text.strip
      pieces << block.merge('text' => block['text'].merge('text' => final_text)) unless final_text.empty?
      pieces.empty? ? [block] : pieces
    end
    blocks.replace(ordered_blocks)

    # Slack rejects secure image blocks inside a legacy attachment. Put the
    # complete notification in top-level blocks when it contains an image.
    if image_added
      payload['text'] = payload.dig('attachments', 0, 'fallback')
      payload['blocks'] = blocks
      payload.delete('attachments')
    end
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

  def slack_api(method, body, token, form: false)
    uri = URI("https://slack.com/api/#{method}")
    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    if form
      request.set_form_data(body.transform_values { |value| value.is_a?(Array) || value.is_a?(Hash) ? value.to_json : value.to_s })
    else
      request['Content-Type'] = 'application/json; charset=utf-8'
      request.body = body.to_json
    end
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 10) do |http|
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
    News.include RedmineSlackNotification::NewsPatch if defined?(News) && !(News < RedmineSlackNotification::NewsPatch)
    TimeEntry.include RedmineSlackNotification::TimeEntryPatch if defined?(TimeEntry) && !(TimeEntry < RedmineSlackNotification::TimeEntryPatch)
    Version.include RedmineSlackNotification::VersionPatch if defined?(Version) && !(Version < RedmineSlackNotification::VersionPatch)
    Project.include RedmineSlackNotification::ProjectPatch if defined?(Project) && !(Project < RedmineSlackNotification::ProjectPatch)
    Comment.include RedmineSlackNotification::CommentPatch if defined?(Comment) && !(Comment < RedmineSlackNotification::CommentPatch)
  end
end

Rails.application.config.to_prepare { RedmineSlackNotification.install_patches }
Rails.application.config.after_initialize { RedmineSlackNotification.install_patches }
