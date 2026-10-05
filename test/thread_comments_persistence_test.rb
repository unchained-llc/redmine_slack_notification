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
  def self.text_formatting; 'markdown'; end
end

class Project < OpenStruct
  def self.find_by(**); nil; end
  def self.active; []; end
end

class User < ActiveRecord::Base
  def active?; status == 1; end
  has_many :email_addresses
  scope :active, -> { where(status: 1) }
  class << self
    attr_accessor :current
  end
end

require_relative '../lib/slackmine'

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table(:users) { |t| t.string :login; t.integer :status; t.string :mail }
  create_table(:email_addresses) { |t| t.integer :user_id; t.string :address }
  create_table(:issues) { |t| t.string :subject }
  create_table(:journals) do |t|
    t.integer :issue_id
    t.integer :user_id
    t.text :notes
    t.datetime :created_on, precision: 6
    t.datetime :updated_on, precision: 6
  end
  create_table(:attachments) do |t|
    t.integer :issue_id
    t.integer :author_id
    t.string :filename
    t.binary :content
  end
end

class EmailAddress < ActiveRecord::Base
end

class Issue < ActiveRecord::Base
  has_many :journals
  has_many :attachments
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
  def attachments_addable?(_viewer); can_comment; end
  def init_journal(viewer, notes); self.pending_journal = journals.build(user_id: viewer.id, notes: notes); end
end

# Minimal real-DB attachment fixture: the production Redmine Attachment model
# owns disk storage, filename/extension validation and rollback cleanup.
class Attachment < ActiveRecord::Base
  validates_presence_of :filename, :content
  def file=(upload)
    self.filename = upload.original_filename
    self.content = upload.read
    upload.rewind
  end
  def author=(viewer); self.author_id = viewer.id; end
end

class Journal < ActiveRecord::Base
  belongs_to :issue
  include Slackmine::JournalPatch
  def journalized; issue; end
  def private_notes?; false; end
end

class ThreadCommentsPersistenceTest < Minitest::Test
  COMMENTS = Slackmine::ThreadComments

  def setup
    EmailAddress.delete_all
    User.delete_all
    Journal.delete_all
    Attachment.delete_all
    Issue.delete_all
    @project = Project.new(identifier: 'agentic', active?: true)
    @issue = Issue.create!(subject: 'Thread target')
    @issue.project = @project
    @issue.can_view = @issue.can_comment = true
    @viewer = OpenStruct.new(id: 3, logged?: true)
    @previous_user = OpenStruct.new(id: 99)
    User.current = @previous_user
    @event = { 'type' => 'message', 'user' => 'U123', 'channel' => 'C123', 'text' => 'Reply from Slack',
               'thread_ts' => '1791001000.000001', 'ts' => '1791001000.000002' }
    @settings = { 'slack' => { 'thread_comments' => true, 'bot_token' => 'test-token',
                              'default_channel_id' => 'C123', 'events' => {
                                'app_id' => 'ATEST', 'team_id' => 'TTEST', 'signing_secret' => 'test-secret' } } }
    @parent = { 'ts' => @event['thread_ts'], 'bot_id' => 'B123', 'app_id' => 'ATEST', 'attachments' => [
      { 'blocks' => [{ 'text' => { 'text' => 'Issue updated' } },
                    { 'text' => { 'text' => "*<https://redmine.example.com/issues/#{@issue.id}|Issue>*" } }] }
    ] }
  end

  def reply_url(timestamp)
    "https://example.slack.com/archives/C123/p#{timestamp.delete('.')}"
  end

  def persist
    Slackmine::WorkObjects.stub(:viewer_for, @viewer) do
      Slackmine.stub(:config, @settings) do
        Slackmine.stub(:enqueue, ->(*) { flunk 'Comment notification loop' }) do
          Slackmine.stub(:slack_api, ->(method, body, *_args, **_options) {
            raise "Unexpected API: #{method}" unless method == 'chat.getPermalink'
            { 'permalink' => reply_url(body['message_ts']) }
          }) do
            # Card acquisition is tested separately from persistence.
            Slackmine::LinkQuotes.stub(:import, ->(text, *) { text }) do
              COMMENTS.persist_reply(@issue, @event, 'TTEST')
            end
          end
        end
      end
    end
  end

  def test_author_identity_duplicate_suppression_and_context_restoration
    assert_equal :saved, persist
    assert_equal 1, Journal.count
    assert_equal 3, Journal.first.user_id
    assert_equal reply_url(@event['ts']) + '?thread_ts=' + @event['thread_ts'], Journal.first.notes
    assert_equal :duplicate, persist
    assert_equal 1, Journal.count
    assert_same @previous_user, User.current
    assert_nil Thread.current[:slackmine_thread_comment]
    @event['ts'] = '1791001000.000003'
    assert_equal :saved, persist
    assert_equal 2, Journal.count
  end

  def image_upload(name = 'F123-screen.png')
    file = Tempfile.new('thread-image-db-test')
    file.binmode
    file.write("\x89PNG\r\n\x1a\nimage".b)
    file.rewind
    file.define_singleton_method(:original_filename) { name }
    file
  end

  def test_image_only_reply_persists_attachment_and_inline_reference_once
    @event['text'] = ''
    @event['subtype'] = 'file_share'
    @event['files'] = [{ 'id' => 'F123' }]
    file = image_upload
    assert COMMENTS.reply_event?(@event)
    Slackmine::ThreadImages.stub(:download, [file]) { assert_equal :saved, persist }
    assert_equal 1, Attachment.count
    assert_equal @issue.id, Attachment.first.issue_id
    assert_equal 3, Attachment.first.author_id
    assert_includes Journal.first.notes, "![](#{Attachment.first.filename})"
    assert file.closed?
    Slackmine::ThreadImages.stub(:download, ->(*) { flunk 'Duplicate downloaded images' }) do
      assert_equal :duplicate, persist
    end
    assert_equal 1, Journal.count
    assert_equal 1, Attachment.count
  ensure
    file.close! if file && !file.closed?
  end

  def test_image_failure_after_attachment_save_rolls_back_every_record
    @event['files'] = [{ 'id' => 'F123' }]
    file = image_upload
    original_save = @issue.method(:save!)
    Slackmine::ThreadImages.stub(:download, [file]) do
      @issue.stub(:save!, -> { original_save.call; raise IOError, 'simulated crash' }) do
        assert_raises(IOError) { persist }
      end
    end
    assert_equal 0, Journal.count
    assert_equal 0, Attachment.count
    assert file.closed?
    assert_same @previous_user, User.current
    # A fresh model, as on a Sidekiq retry, can save both records successfully.
    @issue.reload
    file = image_upload
    Slackmine::ThreadImages.stub(:download, [file]) { assert_equal :saved, persist }
    assert_equal 1, Journal.count
    assert_equal 1, Attachment.count
  ensure
    file.close! if file && !file.closed?
  end

  def test_invalid_attachment_rejects_all_images_and_comment
    @event['files'] = [{ 'id' => 'F123' }, { 'id' => 'F124' }]
    files = [image_upload, image_upload('')]
    Slackmine::ThreadImages.stub(:download, files) { assert_equal :restricted, persist }
    assert_equal 0, Attachment.count
    assert_equal 0, Journal.count
    assert files.all?(&:closed?)
  ensure
    files.each { |file| file.close! unless file.closed? } if files
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
    assert_nil Thread.current[:slackmine_thread_comment]
  end

  def test_parent_identity_exact_timestamp_host_and_subject_position_are_required
    assert_equal @issue, COMMENTS.issue_from_parent(@parent, 'ATEST', @event['thread_ts'])
    assert_nil COMMENTS.issue_from_parent(@parent, 'AOTHER', @event['thread_ts'])
    assert_nil COMMENTS.issue_from_parent(@parent, 'ATEST', '1791001000.999999')
    @parent.delete('bot_id')
    assert_nil COMMENTS.issue_from_parent(@parent, 'ATEST', @event['thread_ts'])
    @parent['bot_id'] = 'B123'
    @parent['attachments'][0]['blocks'][1]['text']['text'] = '*<https://evil.example/issues/1|Issue>*'
    assert_nil COMMENTS.issue_from_parent(@parent, 'ATEST', @event['thread_ts'])
  end

  def test_message_edits_bots_and_root_posts_are_ignored
    assert COMMENTS.reply_event?(@event)
    [{ 'bot_id' => 'B123' }, { 'subtype' => 'message_changed' },
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
    assert_equal Journal.first.created_on, Journal.first.updated_on
    journal = Journal.first
    # Exercise ActiveRecord's edit timestamps without formatting an unrelated
    # outbound Slack notification in this minimal database fixture.
    journal.stub(:notify_slack_journal_comment_changed, nil) { journal.update!(notes: 'Edited text') }
    refute_equal Journal.first.created_on, Journal.first.updated_on
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
    assert_nil Thread.current[:slackmine_thread_comment]
    assert_equal :saved, persist
    assert_equal 1, Journal.count
  end

  def test_invalid_timestamp_does_not_save
    ['broken', '1791001000.0000001', '1000', '-1791001000.000001'].each do |timestamp|
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
    Slackmine.stub(:config, @settings) do
      assert COMMENTS.accepted_reply?('ATEST', 'TTEST', @event)
      refute COMMENTS.accepted_reply?('AOTHER', 'TTEST', @event)
      refute COMMENTS.accepted_reply?('ATEST', 'TOTHER', @event)
      refute COMMENTS.accepted_reply?('ATEST', 'TTEST', @event.merge('channel' => 'COTHER'))
      @settings['slack']['thread_comments'] = false
      Slackmine.stub(:slack_api, ->(*) { flunk 'History should not be fetched' }) do
        assert_nil COMMENTS.process('ATEST', 'TTEST', @event)
      end
    end
  end

  def test_automatic_channel_projects_accept_replies_without_project_yaml_entries
    @settings['slack']['auto_map_channels_by_name'] = true
    Slackmine.stub(:config, @settings) do
      Project.stub(:active, [@project]) do
        Slackmine::ChannelMatching.stub(:channel_for, 'C123') do
          assert_includes COMMENTS.contexts('ATEST', 'TTEST', 'C123'), @project
          assert COMMENTS.accepted_reply?('ATEST', 'TTEST', @event)
        end
      end
    end
  end

  def email_viewer(member = {})
    profile = { 'id' => 'U123', 'team_id' => 'TTEST', 'profile' => { 'email' => 'ALICE@EXAMPLE.COM' } }.merge(member)
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:slack_api, ->(*) { { 'user' => profile } }) do
        Slackmine::WorkObjects.viewer_for('U123')
      end
    end
  end

  def create_email_user(login: 'alice', status: 1)
    user = User.create!(login: login, status: status, mail: 'alice@example.com')
    user.email_addresses.create!(address: 'alice@example.com')
    user
  end

  def test_email_matching_is_opt_in_and_requires_unique_active_user
    user = create_email_user
    assert_nil email_viewer
    @settings['slack']['auto_map_users_by_email'] = true
    assert_equal user, email_viewer
    create_email_user(login: 'duplicate')
    assert_nil email_viewer
    User.where(login: 'duplicate').update_all(status: 3)
    assert_equal user, email_viewer
    user.update!(status: 3)
    assert_nil email_viewer
  end

  def test_email_matching_rejects_foreign_bot_deleted_and_missing_email_identities
    create_email_user
    @settings['slack']['auto_map_users_by_email'] = true
    [{ 'id' => 'UOTHER' }, { 'team_id' => 'TOTHER' }, { 'is_bot' => true },
     { 'is_app_user' => true }, { 'deleted' => true }, { 'is_stranger' => true },
     { 'profile' => {} }].each { |member| assert_nil email_viewer(member) }
  end

  def test_explicit_user_mapping_wins_even_when_invalid_or_locked
    user = create_email_user
    @settings['slack']['auto_map_users_by_email'] = true
    @settings['users'] = { 'alice' => 'UOTHER' }
    assert_nil email_viewer
    @settings['users'] = { 'alice' => 'U123' }
    assert_equal user, email_viewer
    user.update!(status: 3)
    assert_nil email_viewer
    @settings['users'] = { 'missing-user' => 'U123' }
    assert_nil email_viewer
  end

  def test_email_api_failure_denies_access_without_saving
    @settings['slack']['auto_map_users_by_email'] = true
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:slack_api, ->(*) { raise IOError, 'Unavailable' }) do
        assert_nil Slackmine::WorkObjects.viewer_for('U123')
      end
    end
    assert_equal 0, Journal.count
  end

  def test_processing_fetches_only_parent_and_does_not_post_feedback_twice
    @settings['messages'] = { 'work_objects' => { 'product_name' => 'Example Tracker' },
                              'thread_comments' => { 'saved' => '✅ %{product_name} #%{id} にコメントを追加しました。' } }
    calls = []
    api = ->(method, body, token, **_options) do
      calls << [method, body, token]
      case method
      when 'conversations.history' then { 'messages' => [@parent] }
      when 'chat.getPermalink' then { 'permalink' => reply_url(body['message_ts']) }
      else { 'ts' => '1791001000.000004' }
      end
    end
    Slackmine.stub(:config, @settings) do
      Issue.stub(:find_by, @issue) do
        Slackmine::WorkObjects.stub(:viewer_for, @viewer) do
          Slackmine.stub(:slack_api, api) do
            Slackmine::LinkQuotes.stub(:import, ->(text, *) { text }) do
              2.times { COMMENTS.process('ATEST', 'TTEST', @event) }
            end
          end
        end
      end
    end
    assert_equal 1, Journal.count
    assert_equal 1, calls.count { |call| call[0] == 'chat.postMessage' }
    feedback = calls.find { |call| call[0] == 'chat.postMessage' }
    assert_equal "✅ Example Tracker <https://redmine.example.com/issues/#{@issue.id}|##{@issue.id}> にコメントを追加しました。", feedback[1]['text']
    history = calls.first[1]
    assert_equal @event['thread_ts'], history['oldest']
    assert_equal @event['thread_ts'], history['latest']
    assert_equal 1, history['limit']
    assert_equal true, history['inclusive']
  end
end
