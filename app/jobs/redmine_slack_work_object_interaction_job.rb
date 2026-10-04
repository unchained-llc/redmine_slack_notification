# frozen_string_literal: true

class RedmineSlackWorkObjectInteractionJob < ApplicationJob
  queue_as :slack

  def perform(app_id, team_id, payload)
    RedmineSlackNotification::WorkObjects.process_interaction(app_id, team_id, payload)
  rescue RedmineSlackNotification::SlackApiError => e
    Rails.logger.error("RedmineSlackNotification: Work Object interaction failed: #{e.code}")
  end
end
