# frozen_string_literal: true

class RedmineSlackNotificationJob < ApplicationJob
  queue_as :slack

  def perform(payload, project_id)
    project = Project.find_by(id: project_id)
    return unless project

    RedmineSlackNotification.notify(payload, project: project)
  end
end
