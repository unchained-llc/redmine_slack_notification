# frozen_string_literal: true

class RedmineSlackWorkObjectUnfurlJob < ApplicationJob
  queue_as :slack

  def perform(app_id, team_id, event)
    RedmineSlackNotification::WorkObjects.unfurl_links(app_id, team_id, event)
  rescue RedmineSlackNotification::SlackApiError => e
    Rails.logger.error("RedmineSlackNotification: Work Object unfurl failed: #{e.code}")
  end
end
