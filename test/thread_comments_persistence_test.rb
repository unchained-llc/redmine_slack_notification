# frozen_string_literal: true

# Run separately from the stub suite, with ActiveRecord and sqlite3 available.
# Only these in-memory fixture tables are created; no Redmine DB is accessed.
require 'logger'
require 'active_record'
require 'sqlite3'
require 'minitest/autorun'
require 'ostruct'

module Rails
  def self.application
    OpenStruct.new(config: OpenStruct.new(to_prepare: nil, after_initialize: nil))
  end

  def self.logger
    @logger ||= Logger.new(File::NULL)
  end
end

module Setting
  def self.protocol; 'https'; end
  def self.host_name; 'redmine.example.com'; end
end

class Project < OpenStruct
  def self.find_by(**); nil; end
end

class User
  class << self
    attr_accessor :current
  end
end

require_relative '../lib/redmine_slack_notification'

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table(:issues) { |t| t.string :subject }
  create_table(:journals) do |t|
    t.integer :issue_id
    t.integer :user_id
    t.text :notes
    t.datetime :created_on, precision: 6
  end
end

class Issue < ActiveRecord::Base
  has_many :journals
  attr_accessor :project, :private_issue, :can_view, :can_comment, :pending_journal
  after_save do
    if pending_journal
      pending_journal.save!
      self.pending_journal = nil
    end
  end

  def is_private?; !!private_issue; end
  def visible?(_viewer); can_view; end
  def notes_addable?(_viewer); can_comment; end
  def init_journal(viewer, notes); self.pending_journal = journals.build(user_id: viewer.id, notes: notes); end
end

class Journal < ActiveRecord::Base
  belongs_to :issue
  include RedmineSlackNotification::JournalPatch
  def journalized; issue; end
  def private_notes?; false; end
end

class ThreadCommentsPersistenceTest < Minitest::Test
  COMMENTS = RedmineSlackNotification::ThreadComments

  def setup
    Journal.delete_all
    Issue.delete_all
    @project = Project.new(identifier: 'agentic', active?: true)
    @issue = Issue.create!(subject: 'Thread target')
    @issue.project = @project
    @issue.can_view = @issue.can_comment = true
    @viewer = OpenStruct.new(id: 3)
    @previous_user = OpenStruct.new(id: 99)
    User.current = @previous_user
    @event = { 'type' => 'message', 'user' => 'U123', 'channel' => 'C123', 'text' => 'Reply from Slack',
               'thread_ts' => '1000.000001', 'ts' => '1000.000002' }
    @settings = { 'slack' => { 'thread_comments' => true, 'bot_token' => 'test-token',
                              'default_channel_id' => 'C123', 'events' => {
                                'app_id' => 'ATEST', 'team_id' => 'TTEST', 'signing_secret' => 'test-secret' } } }
    @parent = { 'ts' => @event['thread_ts'], 'bot_id' => 'B123', 'app_id' => 'ATEST', 'attachments' => [
      { 'blocks' => [{ 'text' => { 'text' => 'Issue updated' } },
                    { 'text' => { 'text' => "*<https://redmine.example.com/issues/#{@issue.id}|Issue>*" } }] }
    ] }
  end

  def persist
    RedmineSlackNotification::WorkObjects.stub(:viewer_for, @viewer) do
      RedmineSlackNotification.stub(:config, @settings) do
        RedmineSlackNotification.stub(:enqueue, ->(*) { flunk 'Comment notification loop' }) do
          COMMENTS.persist_reply(@issue, @event, 'TTEST')
        end
      end
    end
  end

  def test_author_identity_duplicate_suppression_and_context_restoration
    assert_equal :saved, persist
    assert_equal 1, Journal.count
    assert_equal 3, Journal.first.user_id
    assert_equal "Reply from Slack", Journal.first.notes
    assert_equal :duplicate, persist
    assert_equal 1, Journal.count
    assert_same @previous_user, User.current
    assert_nil Thread.current[:redmine_slack_thread_comment]
    @event['ts'] = '1000.000003'
    assert_equal :saved, persist
    assert_equal 2, Journal.count
  end

  def test_restricted_users_private_issues_and_long_text_never_save
    @issue.can_comment = false
    assert_equal :restricted, persist
    @issue.can_comment = true
    @issue.can_view = false
    assert_equal :restricted, persist
    @issue.can_view = true
    @issue.private_issue = true
    assert_equal :restricted, persist
    @issue.private_issue = false
    @event['text'] = 'x' * 10_001
    assert_equal :restricted, persist
    assert_equal 0, Journal.count
    assert_same @previous_user, User.current
  end

  def test_validation_failure_does_not_save_and_restores_user
    @issue.define_singleton_method(:save!) { raise ActiveRecord::RecordInvalid.new(self) }
    assert_equal :restricted, persist
    assert_equal 0, Journal.count
    assert_same @previous_user, User.current
    assert_nil Thread.current[:redmine_slack_thread_comment]
  end

  def test_parent_identity_exact_timestamp_host_and_subject_position_are_required
    assert_equal @issue, COMMENTS.issue_from_parent(@parent, 'ATEST', @event['thread_ts'])
    assert_nil COMMENTS.issue_from_parent(@parent, 'AOTHER', @event['thread_ts'])
    assert_nil COMMENTS.issue_from_parent(@parent, 'ATEST', '1000.999999')
    @parent.delete('bot_id')
    assert_nil COMMENTS.issue_from_parent(@parent, 'ATEST', @event['thread_ts'])
    @parent['bot_id'] = 'B123'
    @parent['attachments'][0]['blocks'][1]['text']['text'] = '*<https://evil.example/issues/1|Issue>*'
    assert_nil COMMENTS.issue_from_parent(@parent, 'ATEST', @event['thread_ts'])
  end

  def test_message_edits_bots_files_and_root_posts_are_ignored
    assert COMMENTS.reply_event?(@event)
    [{ 'bot_id' => 'B123' }, { 'subtype' => 'message_changed' }, { 'subtype' => 'file_share' },
     { 'ts' => @event['thread_ts'] }, { 'edited' => {} }, { 'text' => '' }].each do |override|
      refute COMMENTS.reply_event?(@event.merge(override))
    end
  end

  def test_disabled_feature_and_unmapped_viewer_do_not_save
    @settings['slack']['thread_comments'] = false
    assert_equal :restricted, persist
    @settings['slack']['thread_comments'] = true
    @viewer = nil
    assert_equal :restricted, persist
    assert_equal 0, Journal.count
  end

  def test_original_microsecond_timestamp_is_preserved_and_survives_comment_edits
    @event['ts'] = '1791028111.695359'
    assert_equal :saved, persist
    assert_equal Time.at(1791028111, 695359, :microsecond).utc, Journal.first.created_on
    Journal.first.update_columns(notes: 'Edited text')
    assert_equal :duplicate, persist
    assert_equal 1, Journal.count
  end

  def test_failure_after_journal_save_rolls_back_and_can_be_retried
    original_save = @issue.method(:save!)
    @issue.stub(:save!, -> { original_save.call; raise IOError, 'simulated crash' }) do
      assert_raises(IOError) { persist }
    end
    assert_equal 0, Journal.count
    assert_same @previous_user, User.current
    assert_nil Thread.current[:redmine_slack_thread_comment]
    assert_equal :saved, persist
    assert_equal 1, Journal.count
  end

  def test_invalid_timestamp_does_not_save
    ['broken', '1000.0000001', '1000', '-1000.000001'].each do |timestamp|
      @event['ts'] = timestamp
      refute COMMENTS.reply_event?(@event)
      assert_equal :restricted, persist
    end
    assert_equal 0, Journal.count
  end

  def test_same_timestamp_from_a_different_author_is_a_separate_comment
    assert_equal :saved, persist
    @viewer = OpenStruct.new(id: 4)
    assert_equal :saved, persist
    assert_equal [3, 4], Journal.order(:id).pluck(:user_id)
  end

  def test_legacy_marker_comments_are_still_recognized_as_duplicates
    Journal.insert_all!([{ issue_id: @issue.id, user_id: 3,
                          notes: "Legacy\n\n#{COMMENTS.source_marker('TTEST', @event)}" }])
    assert_equal :duplicate, persist
    assert_equal 1, Journal.count
  end

  def test_configured_app_team_and_channel_are_required_before_history_access
    RedmineSlackNotification.stub(:config, @settings) do
      assert COMMENTS.accepted_reply?('ATEST', 'TTEST', @event)
      refute COMMENTS.accepted_reply?('AOTHER', 'TTEST', @event)
      refute COMMENTS.accepted_reply?('ATEST', 'TOTHER', @event)
      refute COMMENTS.accepted_reply?('ATEST', 'TTEST', @event.merge('channel' => 'COTHER'))
      @settings['slack']['thread_comments'] = false
      RedmineSlackNotification.stub(:slack_api, ->(*) { flunk 'History should not be fetched' }) do
        assert_nil COMMENTS.process('ATEST', 'TTEST', @event)
      end
    end
  end

  def test_processing_fetches_only_parent_and_does_not_post_feedback_twice
    @settings['messages'] = { 'work_objects' => { 'product_name' => 'Redmine' },
                              'thread_comments' => { 'saved' => '✅ %{product_name} #%{id} にコメントを追加しました。' } }
    calls = []
    api = ->(method, body, token, **_options) do
      calls << [method, body, token]
      method == 'conversations.history' ? { 'messages' => [@parent] } : { 'ts' => '1000.000004' }
    end
    RedmineSlackNotification.stub(:config, @settings) do
      Issue.stub(:find_by, @issue) do
        RedmineSlackNotification::WorkObjects.stub(:viewer_for, @viewer) do
          RedmineSlackNotification.stub(:slack_api, api) do
            2.times { COMMENTS.process('ATEST', 'TTEST', @event) }
          end
        end
      end
    end
    assert_equal 1, Journal.count
    assert_equal 1, calls.count { |call| call[0] == 'chat.postMessage' }
    feedback = calls.find { |call| call[0] == 'chat.postMessage' }
    assert_equal "✅ Redmine ##{@issue.id} にコメントを追加しました。", feedback[1]['text']
    history = calls.first[1]
    assert_equal @event['thread_ts'], history['oldest']
    assert_equal @event['thread_ts'], history['latest']
    assert_equal 1, history['limit']
    assert_equal true, history['inclusive']
  end
end
