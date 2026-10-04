# frozen_string_literal: true
require_relative 'slack_events_controller_test'
require_relative '../app/controllers/redmine_slack_commands_controller'
require_relative '../app/jobs/redmine_slack_command_job'

class SlashCommandsTest < Minitest::Test
  COMMANDS = RedmineSlackNotification::SlashCommands

  def setup
    @date_current = Date.method(:current) if Date.respond_to?(:current)
    Date.singleton_class.define_method(:current) { Date.new(2026, 10, 4) }
    @settings = { 'slack' => { 'slash_command' => '/redmine', 'events' => {
      'app_id' => 'ATEST', 'team_id' => 'TTEST', 'signing_secret' => 'secret' } } }
    @payload = { 'command' => '/redmine', 'api_app_id' => 'ATEST', 'team_id' => 'TTEST',
                 'user_id' => 'U123', 'channel_id' => 'C123', 'text' => 'my',
                 'token' => 'not-queued', 'response_url' => 'https://example.invalid/not-used' }
  end

  def teardown
    if @date_current
      Date.singleton_class.define_method(:current, @date_current)
    else
      Date.singleton_class.remove_method(:current)
    end
  end

  def dispatch(signature: nil, timestamp: Time.now.to_i)
    body = URI.encode_www_form(@payload)
    signature ||= 'v0=' + OpenSSL::HMAC.hexdigest('SHA256', 'secret', "v0:#{timestamp}:#{body}")
    controller = RedmineSlackCommandsController.new
    controller.request = OpenStruct.new(content_length: body.bytesize, raw_post: body, headers: {
      'X-Slack-Request-Timestamp' => timestamp.to_s, 'X-Slack-Signature' => signature })
    @queued = []
    RedmineSlackNotification.stub(:config, @settings) do
      RedmineSlackCommandJob.stub(:perform_later, ->(*args) { @queued << args }) { controller.receive }
    end
    controller
  end

  def test_signed_command_acks_and_only_queues_needed_fields
    assert_equal :ok, dispatch.status
    assert_equal ['ATEST', 'TTEST', @payload.slice('user_id', 'channel_id', 'text')], @queued.first
  end

  def test_direct_edit_uses_configured_command_and_a_server_derived_retry_key
    @settings['slack']['slash_command'] = '/tickets'
    @payload.merge!('command' => '/tickets', 'text' => 'status 7 終了', 'trigger_id' => 'fresh-trigger',
                    'request_key' => 'untrusted-key')
    timestamp = Time.now.to_i
    assert_equal :ok, dispatch(timestamp: timestamp).status
    queued = @queued.first.last
    assert_equal 'status 7 終了', queued['text']
    assert_match(/\A[0-9a-f]{64}\z/, queued['request_key'])
    refute queued.key?('response_url')
    refute queued.key?('token')
    refute queued.key?('trigger_id')
    key = queued['request_key']
    assert_equal :ok, dispatch(timestamp: timestamp).status
    assert_equal key, @queued.first.last['request_key']
    @payload['trigger_id'] = 'another-trigger'
    assert_equal :ok, dispatch(timestamp: timestamp).status
    refute_equal key, @queued.first.last['request_key']
  end

  def test_forged_expired_disabled_and_other_commands_never_queue
    assert_equal :unauthorized, dispatch(signature: 'v0=' + '0' * 64).status
    assert_empty @queued
    assert_equal :unauthorized, dispatch(timestamp: Time.now.to_i - 400).status
    @payload['command'] = '/other'
    assert_equal :forbidden, dispatch.status
    assert_empty @queued
    @payload['command'] = '/redmine'
    @settings['slack'].delete('slash_command')
    assert_equal :forbidden, dispatch.status
  end

  def test_unknown_identity_cannot_read_issues_or_projects
    RedmineSlackNotification::WorkObjects.stub(:viewer_for, nil) do
      %w[my due new 7].each do |text|
        assert_includes COMMANDS.run('ATEST', 'TTEST', 'U123', 'C123', text).to_json, 'Not available'
      end
    end
  end

  def test_results_are_ephemeral_and_use_requesting_user
    calls = []
    RedmineSlackNotification.stub(:config, @settings) do
      COMMANDS.stub(:run, ->(*) { [COMMANDS.section('Example')] }) do
        RedmineSlackNotification.stub(:slack_api, ->(*args) { calls << args }) do
          COMMANDS.deliver('ATEST', 'TTEST', @payload)
        end
      end
    end
    assert_equal 'chat.postEphemeral', calls.first[0]
    assert_equal 'U123', calls.first[1]['user']
    assert_equal 'C123', calls.first[1]['channel']
  end

  def test_single_issue_automatically_uses_configured_card_or_simple_fallback
    project = OpenStruct.new(identifier: 'example', name: 'Example')
    issue = OpenStruct.new(id: 7, subject: 'Task', project: project, status: OpenStruct.new(name: 'Open'), is_private?: false)
    @settings['slack'].merge!('bot_token' => 'token', 'work_object_previews' => true,
                              'work_object_fields' => { 'status' => true })
    RedmineSlackNotification.stub(:config, @settings) do
      RedmineSlackNotification::Formatter.stub(:url, ->(path) { "https://redmine.example#{path}" }) do
        card = COMMANDS.single_issue_payload(issue)
        assert_equal 'slack#/entities/task', card.dig('metadata', 'entities', 0, 'entity_type')
        assert_equal ['status'], card.dig('metadata', 'entities', 0, 'entity_payload', 'display_order')
        refute card.key?('blocks')
        @settings['projects'] = { 'example' => { 'slack' => { 'work_object_previews' => false } } }
        fallback = COMMANDS.single_issue_payload(issue)
        refute fallback.key?('metadata')
        assert_equal 'actions', fallback['blocks'].last['type']
        @settings.delete('projects')
        issue[:is_private?] = true
        refute COMMANDS.single_issue_payload(issue).key?('metadata')
      end
    end
  end

  def test_single_number_and_single_list_result_use_card_renderer_but_multiple_results_do_not
    issue = OpenStruct.new(id: 7, subject: 'Task', status: OpenStruct.new(name: 'Open'), project: OpenStruct.new(name: 'Example'), visible?: true)
    issue.define_singleton_method(:visible?) { |_| true }
    rows = [issue]
    scope = Object.new
    [:open, :where, :order, :limit].each { |method| scope.define_singleton_method(method) { |*| self } }
    scope.define_singleton_method(:to_a) { rows }
    viewer = OpenStruct.new(id: 3)
    added_visible = !Issue.respond_to?(:visible)
    added_sanitize = !Issue.respond_to?(:sanitize_sql_like)
    Issue.define_singleton_method(:visible) { |_| scope } if added_visible
    Issue.define_singleton_method(:sanitize_sql_like) { |value| value } if added_sanitize
    RedmineSlackNotification::WorkObjects.stub(:viewer_for, viewer) do
      COMMANDS.stub(:authorized_project?, true) do
        Issue.stub(:find_by, issue) do
          assert_equal :card, COMMANDS.run('ATEST', 'TTEST', 'U123', 'C123', '7') { :card }
        end
        Issue.stub(:visible, scope) do
          %w[my due search].each do |command|
            assert_equal :card, COMMANDS.run('ATEST', 'TTEST', 'U123', 'C123', "#{command} task") { :card }
          end
          rows << issue
          RedmineSlackNotification::Formatter.stub(:url, ->(path) { "https://redmine.example#{path}" }) do
            blocks = COMMANDS.run('ATEST', 'TTEST', 'U123', 'C123', 'my') { flunk 'multiple results rendered as a card' }
            assert_equal 1, blocks['attachments'].size
            assert_includes blocks['attachments'].to_json, '• '
            assert_includes blocks['attachments'].to_json, 'Example'
            refute_includes blocks.to_json, 'redmine_command_run'
          end
        end
      end
    end
  ensure
    Issue.singleton_class.remove_method(:visible) if added_visible
    Issue.singleton_class.remove_method(:sanitize_sql_like) if added_sanitize
  end

  def test_list_reuses_reminder_format_for_due_and_undated_issues
    project = OpenStruct.new(name: 'Example')
    issues = [nil, -2, 3].each_with_index.map do |days, index|
      OpenStruct.new(id: index + 1, subject: 'Task', project: project,
                     due_date: days && Date.current + days)
    end
    RedmineSlackNotification::Formatter.stub(:url, ->(path) { "https://redmine.example#{path}" }) do
      result = COMMANDS.issue_list_payload(issues, 'search')
      body = result['attachments'].to_json
      assert_includes body, 'Search results (3)'
      assert_includes body, '2d overdue'
      assert_includes body, '3d left'
      assert_includes body, '• <https://redmine.example/issues/1|#1 Task> · Example'
      refute_includes body, 'actions'
    end
  end

  def test_help_uses_configured_command_and_supports_custom_copy
    @settings['slack']['slash_command'] = '/tickets'
    RedmineSlackNotification.stub(:config, @settings) do
      help = COMMANDS.message('help')
      assert_includes help, '/tickets reminders'
      assert_includes help, '/tickets comment 123'
      refute_includes help, '%{command}'
      @settings['messages'] = { 'commands' => { 'help' => 'Try %{command} my' } }
      assert_equal 'Try /tickets my', COMMANDS.message('help')
    end
  end

  def test_help_buttons_have_unique_action_ids_and_route_their_commands
    RedmineSlackNotification.stub(:config, @settings) do
      RedmineSlackNotification::WorkObjects.stub(:viewer_for, OpenStruct.new(id: 3)) do
        ['', 'help'].each do |text|
          blocks = COMMANDS.run('ATEST', 'TTEST', 'U123', 'C123', text)
          buttons = blocks.last['elements']
          ids = buttons.map { |button| button['action_id'] }
          assert_equal ids.size, ids.uniq.size
          assert_equal %w[my due reminders new], buttons.map { |button| button['value'] }
          buttons.each do |button|
            assert_operator button['action_id'].length, :<=, 255
            payload = { 'type' => 'block_actions', 'user' => { 'id' => 'U123' },
                        'channel' => { 'id' => 'C123' }, 'actions' => [button] }
            assert COMMANDS.handles?(payload)
            queued = []
            RedmineSlackCommandJob.stub(:perform_later, ->(*args) { queued << args }) do
              COMMANDS.interaction('ATEST', 'TTEST', payload)
            end
            assert_equal button['value'], queued.first.last['text']
          end
        end
      end
    end
  end

  def reminder_delivery(groups, viewer: OpenStruct.new(id: 7), allowed: true)
    calls = []
    @payload['text'] = 'reminders'
    @settings['slack']['bot_token'] = 'token'
    job = RedmineSlackDueDigestJob.new
    job.define_singleton_method(:due_issues_for) do |user, today|
      raise 'wrong viewer or date' unless user.id == 7 && today == Date.current
      groups
    end
    RedmineSlackNotification.stub(:config, @settings) do
      RedmineSlackNotification::WorkObjects.stub(:viewer_for, viewer) do
        RedmineSlackDueDigestJob.stub(:new, job) do
          COMMANDS.stub(:authorized_project?, allowed) do
            COMMANDS.stub(:sleep, nil) do
              RedmineSlackNotification::Formatter.stub(:url, ->(path) { "https://redmine.example#{path}" }) do
                RedmineSlackNotification.stub(:slack_api, ->(*args) { calls << args }) do
                  COMMANDS.deliver('ATEST', 'TTEST', @payload)
                end
              end
            end
          end
        end
      end
    end
    calls
  end

  def test_reminders_only_return_matching_identity_and_integration
    project = OpenStruct.new(identifier: 'example', name: 'Example')
    issue = OpenStruct.new(id: 7, subject: 'Mine', project: project, due_date: Date.current)
    other = OpenStruct.new(id: 8, subject: 'Other identity', project: project, due_date: Date.current)
    groups = { ['token', 'U123'] => [issue], ['other-token', 'U123'] => [other], ['token', 'U456'] => [other] }
    calls = reminder_delivery(groups)
    assert_equal 1, calls.size
    assert_equal 'chat.postEphemeral', calls.first[0]
    assert_equal 'U123', calls.first[1]['user']
    assert_equal 'C123', calls.first[1]['channel']
    assert_includes calls.first[1].to_json, 'Mine'
    refute_includes calls.first[1].to_json, 'Other identity'
    assert_includes reminder_delivery(groups, allowed: false).first[1]['text'], 'No due reminders'
  end

  def test_reminders_respond_when_empty_or_identity_missing
    assert_includes reminder_delivery({}).first[1]['text'], 'No due reminders'
    assert_includes reminder_delivery({}, viewer: nil).first[1]['text'], 'Not available'
  end

  def test_reminders_batch_all_results_and_reuse_digest_sections
    project = OpenStruct.new(identifier: 'example', name: 'Example')
    issues = (1..101).map do |id|
      OpenStruct.new(id: id, subject: "Task #{id}", project: project, due_date: Date.current + (id % 3) - 1)
    end
    calls = reminder_delivery({ ['token', 'U123'] => issues.reverse })
    assert_equal 2, calls.size
    assert_equal 3, calls.first[1]['attachments'].size
    text = calls.map { |call| call[1].to_json }.join
    (1..101).each { |id| assert_includes text, "/issues/#{id}|" }
    assert calls.all? { |call| call[0] == 'chat.postEphemeral' && call[1]['user'] == 'U123' }
  end

  def test_create_rechecks_permission_and_only_accepts_allowed_tracker
    project = Object.new
    viewer = Object.new
    allowed = true
    viewer.define_singleton_method(:allowed_to?) { |*| allowed }
    saved = 0
    attrs = nil
    issue = Object.new
    issue.define_singleton_method(:allowed_target_trackers) { |*| [OpenStruct.new(id: 2)] }
    issue.define_singleton_method(:safe_attributes=) { |values, _user| attrs = values }
    issue.define_singleton_method(:save) { saved += 1; true }
    values = { 'subject' => { 'subject' => { 'value' => 'New task' } },
               'tracker' => { 'tracker' => { 'selected_option' => { 'value' => '2' } } } }
    Project.stub(:find_by, project) do
      COMMANDS.stub(:authorized_project?, true) do
        Issue.stub(:new, issue) do
          assert_equal({}, COMMANDS.save_form('create', '1', values, viewer, 'ATEST', 'TTEST', 'subject'))
          assert_equal 'New task', attrs['subject']
          assert_equal 1, saved
          allowed = false
          assert_equal 'errors', COMMANDS.save_form('create', '1', values, viewer, 'ATEST', 'TTEST', 'subject')['response_action']
          assert_equal 1, saved
          allowed = true
          values['tracker']['tracker']['selected_option']['value'] = '999'
          assert_equal 'errors', COMMANDS.save_form('create', '1', values, viewer, 'ATEST', 'TTEST', 'subject')['response_action']
          assert_equal 1, saved
        end
      end
    end
  end

  def test_hidden_issue_is_not_disclosed
    viewer = Object.new
    issue = Object.new
    issue.define_singleton_method(:visible?) { |_viewer| false }
    RedmineSlackNotification::WorkObjects.stub(:viewer_for, viewer) do
      Issue.stub(:find_by, issue) do
        assert_includes COMMANDS.run('ATEST', 'TTEST', 'U123', 'C123', '7').to_json, 'Not available'
      end
    end
  end
end
