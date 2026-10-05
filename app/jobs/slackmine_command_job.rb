# frozen_string_literal: true

class SlackmineCommandJob < ApplicationJob
  queue_as :slack

  def perform(app_id, team_id, payload)
    Slackmine::SlashCommands.deliver(app_id, team_id, payload)
  end
end
