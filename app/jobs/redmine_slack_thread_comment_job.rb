# frozen_string_literal: true

class RedmineSlackThreadCommentJob < ApplicationJob
  queue_as :slack

  def perform(app_id, team_id, event)
    RedmineSlackNotification::ThreadComments.process(app_id, team_id, event)
  end
end
