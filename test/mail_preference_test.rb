# frozen_string_literal: true
require_relative 'slash_commands_edit_test'

class MailPreferenceTest < Minitest::Test
  POLICY = Slackmine::MailPreference

  def setup
    @pref = Class.new(Hash) { include Slackmine::UserPreferencePatch }.new
    @pref.slack_suppress_mail = '1'
    @user = OpenStruct.new(login: 'example', mail: 'example@example.com', pref: @pref)
    @project = OpenStruct.new(identifier: 'example', active?: true)
    @issue = Issue.new(7)
    @issue.project = @project
    @settings = { 'slack' => { 'bot_token' => 'test-token', 'default_channel_id' => 'C123' },
                  'users' => { 'example' => 'U123' } }
    @responses = [{ 'members' => ['U123'] }]
    @calls = []
    @disabled = []
  end

  def configured
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:event_enabled?, ->(_project, event) { !@disabled.include?(event) }) do
        Slackmine.stub(:slack_api, ->(method, params, token, **options) {
          @calls << [method, params, token, options]
          result = @responses.shift
          raise result if result.is_a?(Exception)
          result
        }) { yield }
      end
    end
  end

  def suppress(action = :issue_add, object = @issue)
    configured { POLICY.suppress?(@user, action, object) }
  end

  def journal(notes: '', private_notes: false, details: [])
    object = OpenStruct.new(journalized: @issue, notes: notes, private_notes?: private_notes)
    object.extend(Slackmine::JournalPatch)
    object.define_singleton_method(:visible_details) { |_user| details }
    object
  end

  def test_opt_in_is_off_by_default_and_accepts_form_boolean
    pref = @pref.class.new
    refute pref.slack_suppress_mail
    pref.slack_suppress_mail = '1'
    assert pref.slack_suppress_mail
    pref.slack_suppress_mail = '0'
    refute pref.slack_suppress_mail
    pref.slack_suppress_mail = true
    assert pref.slack_suppress_mail
  end

  def test_opted_in_member_suppresses_supported_mail
    assert suppress
    assert_equal 'conversations.members', @calls.first[0]
  end

  def test_disabled_preference_makes_no_api_request
    @pref.slack_suppress_mail = '0'
    refute suppress
    assert_empty @calls
  end

  def test_disabled_event_retains_mail
    @disabled << 'issue_created'
    refute suppress
    assert_empty @calls
  end

  def test_missing_or_ambiguous_name_match_retains_mail
    @settings['users'] = {}
    @settings['slack']['auto_map_users_by_name'] = true
    Slackmine.stub(:slack_user_id_for_name, nil) { refute suppress }
    assert_empty @calls
  end

  def automatic_identity
    @settings['users'] = {}
    @settings['slack']['auto_map_users_by_name'] = true
    { 'user' => { 'id' => 'U123', 'profile' => { 'email' => 'EXAMPLE@example.com' } } }
  end

  def with_name_match
    Slackmine.stub(:slack_user_id_for_name, 'U123') { yield }
  end

  def test_automatic_name_match_with_verified_email_suppresses_mail
    @responses.unshift(automatic_identity)
    with_name_match { assert suppress }
    assert_equal ['users.info', 'conversations.members'], @calls.map(&:first)
  end

  def test_automatic_identity_with_missing_or_different_email_retains_mail
    ['', 'other@example.com'].each do |email|
      response = automatic_identity
      response['user']['profile']['email'] = email
      @responses = [response]
      with_name_match { refute suppress }
    end
    refute @calls.any? { |call| call.first == 'conversations.members' }
  end

  def test_inactive_bot_app_and_foreign_users_do_not_suppress_mail
    %w[deleted is_bot is_app_user is_stranger].each do |flag|
      response = automatic_identity
      response['user'][flag] = true
      @responses = [response]
      with_name_match { refute suppress }
    end
  end

  def test_automatic_identity_must_match_id_and_configured_workspace
    response = automatic_identity
    response['user']['id'] = 'U999'
    @responses = [response]
    with_name_match { refute suppress }
    response = automatic_identity
    @settings['slack']['events'] = { 'team_id' => 'T123' }
    response['user']['team_id'] = 'T999'
    @responses = [response]
    with_name_match { refute suppress }
    response['user']['team_id'] = 'T123'
    @responses = [response, { 'members' => ['U123'] }]
    with_name_match { assert suppress }
  end

  def test_missing_email_scope_keeps_mail
    automatic_identity
    @responses = [IOError.new('missing_scope')]
    with_name_match { refute suppress }
  end

  def test_manual_mapping_blocks_automatic_fallback_when_invalid
    automatic_identity
    @settings['users'][@user.login] = false
    Slackmine.stub(:slack_user_id_for_name, ->(*) { flunk 'Manual mapping must win' }) do
      refute suppress
    end
    assert_empty @calls
  end

  def test_automatic_identity_is_reverified_for_next_mail
    response = automatic_identity
    changed = Marshal.load(Marshal.dump(response))
    changed['user']['profile']['email'] = 'other@example.com'
    @responses = [response, { 'members' => ['U123'] }, changed]
    with_name_match do
      assert suppress
      refute suppress
    end
    assert_equal 2, @calls.count { |call| call.first == 'users.info' }
  end

  def test_email_mapping_is_supported
    @settings['users'] = { @user.mail => 'U123' }
    assert suppress
  end

  def test_invalid_mapping_does_not_fall_back_to_email
    @settings['users'] = { @user.login => 'invalid', @user.mail => 'U123' }
    refute suppress
  end

  def test_nonmember_retains_mail
    @responses = [{ 'members' => ['U999'] }]
    refute suppress
  end

  def test_malformed_membership_response_retains_mail
    @responses = [{ 'members' => 'U123' }]
    refute suppress
  end

  def test_missing_token_retains_mail
    Slackmine.stub(:bot_token, '') { refute suppress }
    assert_empty @calls
  end

  def test_parent_channel_and_project_user_mapping_are_used
    parent = OpenStruct.new(identifier: 'parent', active?: true)
    @project.parent = parent
    @settings['users'] = {}
    @settings['projects'] = { 'parent' => { 'channel_id' => 'C999' },
                              'example' => { 'users' => { @user.login => 'U123' } } }
    assert suppress
    assert_equal 'C999', @calls.first[1]['channel']
  end

  def test_real_event_configuration_can_retain_mail
    @settings['events'] = { 'issue' => { 'created' => false } }
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:slack_api, ->(*) { flunk 'Disabled event must not check Slack' }) do
        refute POLICY.suppress?(@user, :issue_add, @issue)
      end
    end
  end

  def test_member_on_second_page
    @responses = [{ 'members' => ['U999'], 'response_metadata' => { 'next_cursor' => 'page2' } },
                  { 'members' => ['U123'] }]
    assert suppress
    assert_equal 'page2', @calls.last[1]['cursor']
  end

  def test_repeated_cursor_retains_mail
    response = { 'members' => [], 'response_metadata' => { 'next_cursor' => 'repeat' } }
    @responses = [response, response]
    refute suppress
    assert_equal 2, @calls.size
  end

  def test_page_limit_retains_mail
    @responses = 10.times.map { |n| { 'members' => [], 'response_metadata' => { 'next_cursor' => n.to_s } } }
    refute suppress
    assert_equal 10, @calls.size
  end

  def test_api_failure_retains_mail_and_restores_project_context
    @responses = [IOError.new('unavailable')]
    refute suppress
    assert_nil Thread.current[:slackmine_project]
  end

  def test_membership_is_checked_again_for_next_mail
    @responses = [{ 'members' => ['U123'] }, { 'members' => [] }]
    assert suppress
    refute suppress
  end

  def test_missing_channel_token_and_inactive_project_retain_mail
    @settings['slack']['default_channel_id'] = ''
    refute suppress
    @settings['slack']['default_channel_id'] = 'D123'
    refute suppress
    @project.active = false
    refute suppress
    assert_empty @calls
  end

  def test_private_issue_and_private_notes_retain_mail
    issue = Issue.new(8, private_issue: true)
    issue.project = @project
    refute suppress(:issue_add, issue)
    refute suppress(:issue_edit, journal(notes: 'Private', private_notes: true))
    assert_empty @calls
  end

  def test_all_visible_journal_components_must_be_enabled
    details = [OpenStruct.new(property: 'attr', prop_key: 'status_id', value: '2')]
    object = journal(notes: 'A comment', details: details)
    @disabled << 'comment_added'
    refute suppress(:issue_edit, object)
    @disabled = ['status_changed']
    refute suppress(:issue_edit, object)
    @disabled.clear
    assert suppress(:issue_edit, object)
  end

  def test_empty_journal_and_slack_origin_keep_mail
    refute suppress(:issue_edit, journal)
    Thread.current[:slackmine_thread_comment] = true
    refute suppress
  ensure
    Thread.current[:slackmine_thread_comment] = nil
  end

  def test_supported_wiki_and_news_actions
    wiki = OpenStruct.new(page: OpenStruct.new(wiki: OpenStruct.new(project: @project)))
    assert suppress(:wiki_content_added, wiki)
    @responses << { 'members' => ['U123'] }
    assert suppress(:wiki_content_updated, wiki)
    @responses << { 'members' => ['U123'] }
    assert suppress(:news_added, OpenStruct.new(project: @project))
    @disabled << 'wiki_updated'
    refute suppress(:wiki_content_updated, wiki)
  end

  def test_news_comment_mail_requires_supported_news_and_event
    comment = OpenStruct.new(commented: News.new(project: @project), comments: 'A comment')
    assert suppress(:news_comment_added, comment)
    @disabled << 'news_comment_added'
    refute suppress(:news_comment_added, comment)
    refute suppress(:news_comment_added, OpenStruct.new(commented: Object.new, comments: 'A comment'))
  end

  def test_mailer_patch_skips_only_supported_actions_and_preserves_arguments
    klass = Class.new do
      def issue_add(user, issue)
        [user, issue]
      end
      def lost_password(user)
        [:password, user]
      end
      prepend Slackmine::MailerPatch
    end
    mailer = klass.new
    configured { assert_nil mailer.issue_add(@user, @issue) }
    @pref.slack_suppress_mail = '0'
    configured { assert_equal [@user, @issue], mailer.issue_add(@user, @issue) }
    assert_equal [:password, @user], mailer.lost_password(@user)
  end
end
