# frozen_string_literal: true

class RedmineSlackAppHomeJob < ApplicationJob
  queue_as :slack

  def perform(app_id, team_id, user_id, filter = 'all')
    RedmineSlackNotification::AppHome.publish(app_id, team_id, user_id, filter)
  rescue RedmineSlackNotification::SlackApiError => e
    Rails.logger.error("RedmineSlackNotification: App Home publish failed: #{e.code}")
  end
end
