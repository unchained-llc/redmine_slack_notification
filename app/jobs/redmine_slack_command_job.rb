# frozen_string_literal: true

class RedmineSlackCommandJob < ApplicationJob
  queue_as :slack

  def perform(app_id, team_id, payload)
    RedmineSlackNotification::SlashCommands.deliver(app_id, team_id, payload)
  end
end
