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

  def webhook_url(project)
    return '' unless project

    project_config = config.fetch('projects', {}).fetch(project.identifier.to_s, {})
    project_url = project_config.is_a?(Hash) ? project_config['webhook_url'] : project_config
    (project_url.presence || config['default_webhook_url']).to_s.strip
  end

  def user_mapping
    config.fetch('users', {})
  end

  def configured?(project)
    webhook_url(project).present?
  end

  def enqueue(payload, project:)
    return unless project

    RedmineSlackNotificationJob.perform_later(payload, project.id)
  end

  def notify(payload, project: nil)
    url = webhook_url(project)
    unless url.present?
      Rails.logger.warn("RedmineSlackNotification: webhook not configured for project #{project&.identifier || '(none)'} (#{config_path})")
      return
    end

    Rails.logger.warn("RedmineSlackNotification: sending notification for project #{project.identifier}")
    uri = URI.parse(url)
    request = Net::HTTP::Post.new(uri.request_uri)
    request['Content-Type'] = 'application/json'
    request.body = payload.to_json
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 3, read_timeout: 5) do |http|
      response = http.request(request)
      Rails.logger.warn("RedmineSlackNotification: Slack returned #{response.code}: #{response.body}") unless response.is_a?(Net::HTTPSuccess)
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
    Rails.logger.warn('RedmineSlackNotification: registering model callbacks')
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

if defined?(Issue) && defined?(Journal) && defined?(WikiContent) && defined?(Comment) && defined?(News) && defined?(TimeEntry) && defined?(Version) && defined?(Project)
  RedmineSlackNotification.install_patches
else
  Rails.application.config.to_prepare { RedmineSlackNotification.install_patches }
end
