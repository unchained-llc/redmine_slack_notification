# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'yaml'

module RedmineSlackNotification
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

  def enqueue(payload, project:)
    return unless project

    RedmineSlackNotificationJob.perform_later(payload, project.id)
  end

  def notify(payload, project: nil)
    token = bot_token
    channel = channel_id(project)
    unless token.present? && channel.present?
      Rails.logger.warn("RedmineSlackNotification: Slack API is not configured for project #{project&.identifier || '(none)'} (token/channel missing)")
      return
    end


    uri = URI('https://slack.com/api/chat.postMessage')
    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    request['Content-Type'] = 'application/json; charset=utf-8'
    request.body = payload.merge('channel' => channel).to_json
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 5) do |http|
      response = http.request(request)
      result = JSON.parse(response.body)
      unless response.is_a?(Net::HTTPSuccess) && result['ok']
        Rails.logger.warn("RedmineSlackNotification: Slack API returned #{response.code}: #{result['error'] || response.body}")
      end
    end
  rescue StandardError => e
    Rails.logger.error("RedmineSlackNotification: #{e.class}: #{e.message}")
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
