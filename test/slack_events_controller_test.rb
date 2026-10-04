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
require_relative '../app/jobs/redmine_slack_work_object_interaction_job'
require_relative '../app/jobs/redmine_slack_thread_comment_job'

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

  def test_signed_work_object_interaction_is_queued_from_form_payload
    interaction = { 'type' => 'block_actions', 'api_app_id' => 'ATEST',
                    'team' => { 'id' => 'TTEST' }, 'user' => { 'id' => 'U123' },
                    'container' => { 'type' => 'entity_detail', 'entity_url' => 'https://example.com/issues/7' },
                    'actions' => [{ 'action_id' => 'redmine_assign_to_me' }], 'token' => 'do-not-queue' }
    body = URI.encode_www_form('payload' => JSON.generate(interaction))
    queued = []
    RedmineSlackWorkObjectInteractionJob.stub(:perform_later, ->(*args) { queued << args }) do
      assert_equal :ok, dispatch(raw: body).status
      assert_equal 'ATEST', queued.first[0]
      assert_equal 'TTEST', queued.first[1]
      assert_equal 'redmine_assign_to_me', queued.first[2].dig('actions', 0, 'action_id')
      refute queued.first[2].key?('token')
      assert_equal :unauthorized, dispatch(raw: body, signature: 'v0=' + '0' * 64).status
      assert_equal :bad_request, dispatch(raw: body + '&other=1').status
      assert_equal 1, queued.length
    end
  end

  def test_signed_detail_edit_queues_only_editable_values
    interaction = { 'type' => 'view_submission', 'api_app_id' => 'ATEST',
                    'team' => { 'id' => 'TTEST' }, 'user' => { 'id' => 'U123' },
                    'view' => { 'type' => 'entity_detail', 'entity_url' => 'https://example.com/issues/7',
                                'state' => { 'values' => {
                                  'new_comment' => { 'new_comment.input' => { 'value' => 'Test note' } },
                                  'unrelated' => { 'value' => 'do-not-queue' }
                                } } }, 'token' => 'do-not-queue' }
    body = URI.encode_www_form('payload' => JSON.generate(interaction))
    queued = []
    RedmineSlackWorkObjectInteractionJob.stub(:perform_later, ->(*args) { queued << args }) do
      assert_equal :ok, dispatch(raw: body).status
      values = queued.first[2].dig('view', 'state', 'values')
      assert_equal 'Test note', values.dig('new_comment', 'new_comment.input', 'value')
      refute values.key?('unrelated')
      refute queued.first[2].key?('token')
    end
  end

  def test_thread_reply_is_queued_only_when_enabled_and_for_the_configured_channel
    @settings['slack'].merge!('thread_comments' => true, 'default_channel_id' => 'C123')
    @payload['event'] = { 'type' => 'message', 'user' => 'U123', 'text' => 'Reply',
                          'channel' => 'C123', 'ts' => '1000.000002', 'thread_ts' => '1000.000001' }
    queued = []
    RedmineSlackThreadCommentJob.stub(:perform_later, ->(*args) { queued << args }) do
      assert_equal :ok, dispatch.status
      assert_equal 1, queued.length
      assert_equal @payload['event'], queued.first.last
      @settings['slack']['thread_comments'] = false
      dispatch
      assert_equal 1, queued.length
      @settings['slack']['thread_comments'] = true
      @payload['event']['channel'] = 'COTHER'
      dispatch
      assert_equal 1, queued.length
      @payload['event']['channel'] = 'C123'
      @payload['event']['bot_id'] = 'B123'
      dispatch
      assert_equal 1, queued.length
    end
  end
end
