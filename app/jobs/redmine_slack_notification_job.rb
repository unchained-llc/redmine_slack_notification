# frozen_string_literal: true

class RedmineSlackNotificationJob < ApplicationJob
  queue_as :slack

  def perform(payload, project_id, image_names = [], journal_id = nil)
    project = Project.find_by(id: project_id)
    return unless project

    RedmineSlackNotification.notify(payload, project: project, image_names: image_names, journal_id: journal_id)
  end
end
