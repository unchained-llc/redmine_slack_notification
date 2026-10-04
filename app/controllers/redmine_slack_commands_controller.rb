# frozen_string_literal: true

class RedmineSlackCommandsController < ActionController::Base
  protect_from_forgery with: :null_session

  def receive
    return head :payload_too_large if request.content_length.to_i > 65_536
    body = request.raw_post
    return head :payload_too_large if body.bytesize > 65_536
    pairs = URI.decode_www_form(body)
    return head :bad_request unless pairs.map(&:first).uniq.length == pairs.length
    payload = pairs.to_h
    integration = RedmineSlackNotification::WorkObjects.verified_integration(
      body, request.headers['X-Slack-Request-Timestamp'], request.headers['X-Slack-Signature'],
      app_id: payload['api_app_id'], team_id: payload['team_id']
    )
    return head :unauthorized unless integration && payload['api_app_id'] == integration['app_id'] && payload['team_id'] == integration['team_id']
    return head :forbidden unless RedmineSlackNotification::SlashCommands.integration?(payload['api_app_id'], payload['team_id'])
    expected = RedmineSlackNotification.effective_config.dig('slack', 'slash_command')
    return head :forbidden unless expected.to_s.start_with?('/') && payload['command'] == expected
    return head :bad_request unless payload['user_id'].to_s.match?(/\A[UW][A-Z0-9]+\z/) && payload['channel_id'].to_s.match?(/\A[CDG][A-Z0-9]+\z/) && payload['text'].to_s.length <= 1000
    RedmineSlackCommandJob.perform_later(payload['api_app_id'], payload['team_id'], payload.slice('user_id', 'channel_id', 'text'))
    head :ok
  rescue ArgumentError
    head :bad_request
  end
end
