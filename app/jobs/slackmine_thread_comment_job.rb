# frozen_string_literal: true

class SlackmineThreadCommentJob < ApplicationJob
  queue_as :slack

  def perform(app_id, team_id, event)
    Slackmine::ThreadComments.process(app_id, team_id, event)
  end
end
