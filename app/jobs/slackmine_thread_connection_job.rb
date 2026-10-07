# frozen_string_literal: true

class SlackmineThreadConnectionJob < ApplicationJob
  queue_as :slack

  def perform(app, team, source, view_id = nil, step = nil)
    case step
    when 'picker' then Slackmine::ThreadConnections.prepare_picker(app, team, source, view_id)
    when 'preview' then Slackmine::ThreadConnections.prepare_preview(app, team, source, view_id)
    else Slackmine::ThreadConnections.finish(app, team, source)
    end
  end
end
