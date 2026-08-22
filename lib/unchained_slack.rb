# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'yaml'

module UnchainedSlack
  module_function

  def config
    @config ||= begin
      path = config_paths.find { |candidate| File.exist?(candidate) }
      unless path
        Rails.logger.warn("UnchainedSlack: config file not found: #{config_paths.join(', ')}")
        {}
      else
        YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
      end
    rescue StandardError => e
      Rails.logger.error("UnchainedSlack: cannot load #{path}: #{e.class}: #{e.message}")
      {}
    end
  end

  def config_paths
    [
      Rails.root.join('config', 'unchained_slack.yml'),
      File.expand_path('../config/unchained_slack.yml', __dir__)
    ]
  end

  def config_path
    config_paths.first
  end

  def webhook_url(project)
    return '' unless project

    project_config = config.fetch('projects', {}).fetch(project.identifier.to_s, {})
    url = project_config.is_a?(Hash) ? project_config['webhook_url'] : project_config
    url.to_s.strip
  end

  def user_mapping
    config.fetch('users', {})
  end

  def configured?(project)
    webhook_url(project).present?
  end

  def notify(payload, project: nil)
    url = webhook_url(project)
    unless url.present?
      Rails.logger.warn("UnchainedSlack: webhook not configured for project #{project&.identifier || '(none)'} (#{config_path})")
      return
    end

    Rails.logger.warn("UnchainedSlack: sending notification for project #{project.identifier}")
    uri = URI.parse(url)
    request = Net::HTTP::Post.new(uri.request_uri)
    request['Content-Type'] = 'application/json'
    request.body = payload.to_json
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 3, read_timeout: 5) do |http|
      response = http.request(request)
      Rails.logger.warn("UnchainedSlack: Slack returned #{response.code}: #{response.body}") unless response.is_a?(Net::HTTPSuccess)
    end
  rescue StandardError => e
    Rails.logger.error("UnchainedSlack: #{e.class}: #{e.message}")
  end
end

require_relative 'unchained_slack/issue_patch'
require_relative 'unchained_slack/journal_patch'
require_relative 'unchained_slack/wiki_content_patch'


module UnchainedSlack
  module_function

  def install_patches
    Rails.logger.warn('UnchainedSlack: registering model callbacks')
    Issue.include UnchainedSlack::IssuePatch unless Issue < UnchainedSlack::IssuePatch
    Journal.include UnchainedSlack::JournalPatch unless Journal < UnchainedSlack::JournalPatch
    WikiContent.include UnchainedSlack::WikiContentPatch unless WikiContent < UnchainedSlack::WikiContentPatch
  end
end

if defined?(Issue) && defined?(Journal) && defined?(WikiContent)
  UnchainedSlack.install_patches
else
  Rails.application.config.to_prepare { UnchainedSlack.install_patches }
end
