# frozen_string_literal: true

class SlackmineWorkObjectRefreshJob < ApplicationJob
  queue_as :slack

  def perform(app, team, issue_id, slack_user, context, outcome, modal)
    Slackmine::WorkObjects.refresh_after_interaction(app, team, issue_id, slack_user, context, outcome, modal)
  end
end
