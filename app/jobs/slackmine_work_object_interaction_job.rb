# frozen_string_literal: true

class SlackmineWorkObjectInteractionJob < ApplicationJob
  queue_as :slack

  def perform(app_id, team_id, payload)
    Slackmine::WorkObjects.process_interaction(app_id, team_id, payload)
  rescue Slackmine::SlackApiError => e
    Rails.logger.error("Slackmine: Work Object interaction failed: #{e.code}")
  end
end
