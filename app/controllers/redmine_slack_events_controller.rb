# frozen_string_literal: true

require 'uri'

class RedmineSlackEventsController < ActionController::Base
  # This endpoint uses Slack signatures, never a browser session or Redmine's
  # login cookie. Other Redmine controllers keep their normal CSRF protection.
  protect_from_forgery with: :null_session

  def receive
    return head :payload_too_large if request.content_length.to_i > 65_536
    body = request.raw_post
    return head :payload_too_large if body.bytesize > 65_536
    form = body.start_with?('payload=')
    if form
      pairs = URI.decode_www_form(body)
      return head :bad_request unless pairs.length == 1 && pairs.first[0] == 'payload'
      payload = JSON.parse(pairs.first[1])
    else
      payload = JSON.parse(body)
    end
    return head :bad_request unless payload.is_a?(Hash)

    team_id = form ? payload.dig('team', 'id') : payload['team_id']

    integration = RedmineSlackNotification::WorkObjects.verified_integration(
      body, request.headers['X-Slack-Request-Timestamp'], request.headers['X-Slack-Signature'],
      app_id: payload['api_app_id'], team_id: team_id
    )
    return head :unauthorized unless integration

    if payload['type'] == 'url_verification'
      return render json: { challenge: payload['challenge'] } if payload['challenge'].is_a?(String)
      return head :bad_request
    end
    return head :forbidden unless payload['api_app_id'] == integration['app_id'] && team_id == integration['team_id']

    if form
      return head :bad_request unless %w[block_actions view_submission].include?(payload['type'])
      source_key = payload['type'] == 'block_actions' ? 'container' : 'view'
      source = payload[source_key]
      return head :bad_request unless source.is_a?(Hash)
      interaction = payload.slice('type', 'trigger_id')
      interaction['user'] = { 'id' => payload.dig('user', 'id') }
      interaction[source_key] = source.slice('type', 'entity_url', 'external_ref', 'channel_id', 'message_ts',
                                              'callback_id', 'private_metadata')
      if source_key == 'container'
        interaction['actions'] = Array(payload['actions']).map { |action| action.is_a?(Hash) ? action.slice('action_id') : {} }
      else
        values = source.dig('state', 'values')
        return head :bad_request unless values.is_a?(Hash)
        interaction['view']['state'] = { 'values' => values.slice('status', 'priority', 'assignee', 'due_date', 'new_comment') }
      end
      RedmineSlackWorkObjectInteractionJob.perform_later(payload['api_app_id'], team_id, interaction)
      return head :ok
    end

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
  rescue JSON::ParserError, ArgumentError
    head :bad_request
  end
end
