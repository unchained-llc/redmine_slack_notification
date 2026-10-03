# frozen_string_literal: true

# This plugin's standalone suite has no Rails installation. Exercise the actual
# controller method with a minimal request/response adapter; production Rails
# supplies the routing, headers, and ActiveJob adapter.
require_relative 'image_notification_test'

module ActionController
  class Base
    def self.protect_from_forgery(*)
    end

    attr_accessor :request
    attr_reader :status, :response_body

    def head(status)
      @status = status
    end

    def render(json:)
      @status = :ok
      @response_body = json
    end
  end
end

require_relative '../app/controllers/redmine_slack_events_controller'
require_relative '../app/jobs/redmine_slack_work_object_details_job'

class SlackEventsControllerTest < Minitest::Test
  def setup
    @settings = { 'slack' => { 'events' => {
      'app_id' => 'ATEST', 'team_id' => 'TTEST', 'signing_secret' => 'test-secret'
    } } }
    @payload = { 'type' => 'event_callback', 'api_app_id' => 'ATEST', 'team_id' => 'TTEST',
                 'event' => { 'type' => 'entity_details_requested', 'trigger_id' => 'test-trigger',
                              'user' => 'U123', 'entity_url' => 'https://example.com/issues/7',
                              'external_ref' => { 'id' => 'issue7', 'type' => 'redmine_issue' },
                              'unused_field' => 'do not queue' } }
  end

  def dispatch(payload = @payload, signature: nil, timestamp: Time.now.to_i, raw: nil, length: nil)
    body = raw || JSON.generate(payload)
    signature ||= 'v0=' + OpenSSL::HMAC.hexdigest('SHA256', 'test-secret', "v0:#{timestamp}:#{body}")
    controller = RedmineSlackEventsController.new
    controller.request = OpenStruct.new(content_length: length || body.bytesize, raw_post: body,
                                        headers: { 'X-Slack-Request-Timestamp' => timestamp.to_s,
                                                   'X-Slack-Signature' => signature })
    @jobs = []
    RedmineSlackNotification.stub(:config, @settings) do
      RedmineSlackWorkObjectDetailsJob.stub(:perform_later, ->(*args) { @jobs << args }) { controller.receive }
    end
    controller
  end

  def test_signed_challenge_without_app_ids_returns_challenge_and_does_not_queue
    response = dispatch({ 'type' => 'url_verification', 'challenge' => 'verify-me' })
    assert_equal :ok, response.status
    assert_equal({ challenge: 'verify-me' }, response.response_body)
    assert_empty @jobs
  end

  def test_signed_details_event_is_acknowledged_and_only_necessary_fields_are_queued
    response = dispatch
    assert_equal :ok, response.status
    assert_equal 1, @jobs.length
    app_id, team_id, event = @jobs.first
    assert_equal 'ATEST', app_id
    assert_equal 'TTEST', team_id
    assert_equal 'test-trigger', event['trigger_id']
    refute event.key?('unused_field')
  end

  def test_invalid_signature_expired_timestamp_and_wrong_app_are_not_queued
    [dispatch(signature: 'v0=' + '0' * 64), dispatch(timestamp: Time.now.to_i - 301),
     dispatch(@payload.merge('api_app_id' => 'AOTHER'))].each do |response|
      assert_equal :unauthorized, response.status
    end
    assert_empty @jobs
  end

  def test_invalid_json_and_oversized_requests_are_rejected
    assert_equal :bad_request, dispatch(raw: '{').status
    assert_equal :bad_request, dispatch(raw: '[]').status
    assert_equal :payload_too_large, dispatch(length: 65_537).status
    assert_equal :payload_too_large, dispatch(raw: ' ' * 65_537).status
    assert_empty @jobs
  end

  def test_missing_trigger_and_unrelated_events_do_not_queue
    event = @payload['event'].merge('trigger_id' => '')
    assert_equal :bad_request, dispatch(@payload.merge('event' => event)).status
    assert_empty @jobs
    event = @payload['event'].merge('type' => 'app_mention')
    assert_equal :ok, dispatch(@payload.merge('event' => event)).status
    assert_empty @jobs
  end

  def test_signed_callback_without_app_and_team_ids_is_forbidden
    assert_equal :forbidden, dispatch(@payload.reject { |key, _| %w[api_app_id team_id].include?(key) }).status
    assert_empty @jobs
  end

  def test_job_passes_event_to_details_handler
    arguments = nil
    RedmineSlackNotification::WorkObjects.stub(:present_details, ->(*args) { arguments = args }) do
      RedmineSlackWorkObjectDetailsJob.new.perform('ATEST', 'TTEST', @payload['event'])
    end
    assert_equal ['ATEST', 'TTEST', @payload['event']], arguments
  end
end
