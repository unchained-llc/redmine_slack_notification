# frozen_string_literal: true

class RedmineSlackEventsController < ActionController::Base
  # This endpoint uses Slack signatures, never a browser session or Redmine's
  # login cookie. Other Redmine controllers keep their normal CSRF protection.
  protect_from_forgery with: :null_session

  def receive
    return head :payload_too_large if request.content_length.to_i > 65_536
    body = request.raw_post
    return head :payload_too_large if body.bytesize > 65_536
    payload = JSON.parse(body)
    return head :bad_request unless payload.is_a?(Hash)

    integration = RedmineSlackNotification::WorkObjects.verified_integration(
      body, request.headers['X-Slack-Request-Timestamp'], request.headers['X-Slack-Signature'],
      app_id: payload['api_app_id'], team_id: payload['team_id']
    )
    return head :unauthorized unless integration

    if payload['type'] == 'url_verification'
      return render json: { challenge: payload['challenge'] } if payload['challenge'].is_a?(String)
      return head :bad_request
    end
    return head :forbidden unless payload['api_app_id'] == integration['app_id'] && payload['team_id'] == integration['team_id']

    event = payload['event']
    if payload['type'] == 'event_callback' && event.is_a?(Hash) && event['type'] == 'entity_details_requested'
      return head :bad_request if event['trigger_id'].to_s.empty? || event['user'].to_s.empty?

      # ACK immediately; external HTTP calls run on the existing Slack queue.
      RedmineSlackWorkObjectDetailsJob.perform_later(payload['api_app_id'], payload['team_id'], event.slice(
        'type', 'trigger_id', 'user', 'entity_url', 'external_ref'
      ))
    elsif payload['type'] == 'event_callback' && RedmineSlackNotification::ThreadComments.accepted_reply?(payload['api_app_id'], payload['team_id'], event)
      RedmineSlackThreadCommentJob.perform_later(payload['api_app_id'], payload['team_id'], event.slice(
        'type', 'subtype', 'user', 'text', 'channel', 'ts', 'thread_ts'
      ))
    end
    head :ok
  rescue JSON::ParserError
    head :bad_request
  end
end
