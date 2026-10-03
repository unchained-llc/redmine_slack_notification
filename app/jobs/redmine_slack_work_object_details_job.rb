# frozen_string_literal: true

class RedmineSlackWorkObjectDetailsJob < ApplicationJob
  queue_as :slack

  def perform(app_id, team_id, event)
    RedmineSlackNotification::WorkObjects.present_details(app_id, team_id, event)
  rescue RedmineSlackNotification::SlackApiError => e
    # Trigger-based requests should be retried by refreshing the detail pane,
    # rather than replaying an expired trigger through Sidekiq retries.
    Rails.logger.error("RedmineSlackNotification: Work Object details failed: #{e.code}")
  end
end
