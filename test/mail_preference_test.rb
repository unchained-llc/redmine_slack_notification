# frozen_string_literal: true
require_relative 'slash_commands_edit_test'

class MailPreferenceTest < Minitest::Test
  POLICY = RedmineSlackNotification::MailPreference

  def setup
    @pref = Class.new(Hash) { include RedmineSlackNotification::UserPreferencePatch }.new
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
    RedmineSlackNotification.stub(:config, @settings) do
      RedmineSlackNotification.stub(:event_enabled?, ->(_project, event) { !@disabled.include?(event) }) do
        RedmineSlackNotification.stub(:slack_api, ->(method, params, token, **options) {
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
    object.extend(RedmineSlackNotification::JournalPatch)
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

  def test_missing_mapping_retains_mail_even_with_name_matching
    @settings['users'] = {}
    @settings['slack']['auto_map_users_by_name'] = true
    refute suppress
    assert_empty @calls
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
    RedmineSlackNotification.stub(:bot_token, '') { refute suppress }
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
    RedmineSlackNotification.stub(:config, @settings) do
      RedmineSlackNotification.stub(:slack_api, ->(*) { flunk 'Disabled event must not check Slack' }) do
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
    assert_nil Thread.current[:redmine_slack_notification_project]
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
    Thread.current[:redmine_slack_thread_comment] = true
    refute suppress
  ensure
    Thread.current[:redmine_slack_thread_comment] = nil
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
      prepend RedmineSlackNotification::MailerPatch
    end
    mailer = klass.new
    configured { assert_nil mailer.issue_add(@user, @issue) }
    @pref.slack_suppress_mail = '0'
    configured { assert_equal [@user, @issue], mailer.issue_add(@user, @issue) }
    assert_equal [:password, @user], mailer.lost_password(@user)
  end
end
