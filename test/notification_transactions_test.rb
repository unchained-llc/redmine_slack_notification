# frozen_string_literal: true
# Run separately from the stub-model suite, with ActiveRecord and sqlite3 installed.
require 'logger'
require 'active_record'
require 'minitest/autorun'
require 'ostruct'
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :notification_records do |t|
    t.string :title
    t.string :name
    t.string :subject
    t.text :description
    t.text :content
    t.text :comments
    t.string :status
    t.date :effective_date
    t.date :spent_on
    t.integer :hours
    t.integer :board_id
    t.integer :parent_id
  end
end
module Slackmine
  class << self
    attr_accessor :deliveries
    def enqueue(payload, **options); deliveries << [payload, options]; end
  end
  module Formatter
    def self.url(path); path; end
    def self.generic_payload(**options); options; end
    def self.issue_payload(issue, **options); options; end
    def self.image_references(*); []; end
  end
end
require_relative '../lib/slackmine/generic_patches'
# IssuePatch requires the formatter, so load it before replacing its builder in tests.
require_relative '../lib/slackmine/issue_patch'
class User
  def self.current; :editor; end
end
class NotificationRecord < ActiveRecord::Base
  self.table_name = 'notification_records'
  def project; OpenStruct.new(id: 9, identifier: 'example'); end
  def author; :original_author; end
  def user; :original_author; end
end
class News < NotificationRecord
  include Slackmine::NewsPatch
end
class TimeEntry < NotificationRecord
  include Slackmine::TimeEntryPatch
end
class Version < NotificationRecord
  include Slackmine::VersionPatch
end
class Document < NotificationRecord
  include Slackmine::DocumentPatch
end
class Message < NotificationRecord
  include Slackmine::MessagePatch
end
class Project < NotificationRecord
  include Slackmine::ProjectPatch
  def identifier; 'example'; end
end
class Comment < NotificationRecord
  include Slackmine::CommentPatch
  def commented; News.new(title: 'News'); end
  def comments; content; end
end
class Issue < NotificationRecord
  include Slackmine::IssuePatch
  def will_save_change_to_description?; false; end
  def is_private?; false; end
end
class NotificationTransactionsTest < Minitest::Test
  CASES = {
    News => [:title, 'news_created', 'news_updated', 'news_deleted'],
    TimeEntry => [:comments, 'time_entry_created', 'time_entry_updated', 'time_entry_deleted'],
    Version => [:name, 'version_created', 'version_updated', 'version_deleted'],
    Document => [:title, 'document_created', 'document_updated', 'document_deleted'],
    Message => [:subject, 'message_posted', 'message_updated', 'message_deleted'],
    Comment => [:content, 'news_comment_added', 'news_comment_updated', 'news_comment_deleted'],
    Project => [:name, nil, 'project_updated', nil],
    Issue => [:subject, 'issue_created', nil, 'issue_deleted']
  }.freeze
  def setup
    Slackmine.deliveries = []
  end
  def capture
    Slackmine::Formatter.stub(:generic_payload, ->(**options) { options }) do
      Slackmine::Formatter.stub(:issue_payload, ->(_record, **options) { options }) do
        Slackmine::Formatter.stub(:url, ->(path) { path }) { yield }
      end
    end
  end
  def test_all_model_notifications_wait_for_commit_and_ignore_rollback
    capture do
      CASES.each do |klass, (field, created, updated, deleted)|
        attributes = { field => 'before', description: 'body', content: 'comment', board_id: 2, hours: 1 }
        Slackmine.deliveries.clear
        klass.transaction do
          klass.create!(attributes)
          assert_empty Slackmine.deliveries, "#{klass} before create commit"
          raise ActiveRecord::Rollback
        end
        assert_empty Slackmine.deliveries, "#{klass} create rollback"
        record = klass.create!(attributes)
        assert_equal [created].compact, Slackmine.deliveries.map { |_, opts| opts[:event] }, klass.name
        Slackmine.deliveries.clear
        klass.transaction do
          record.update!(field => 'after')
          assert_empty Slackmine.deliveries, "#{klass} before update commit"
          raise ActiveRecord::Rollback
        end
        assert_empty Slackmine.deliveries, "#{klass} update rollback"
        record.reload.update!(field => 'after')
        assert_equal [updated].compact, Slackmine.deliveries.map { |_, opts| opts[:event] }, klass.name
        Slackmine.deliveries.clear
        klass.transaction do
          record.destroy!
          assert_empty Slackmine.deliveries, "#{klass} before delete commit"
          raise ActiveRecord::Rollback
        end
        assert_empty Slackmine.deliveries, "#{klass} delete rollback"
        record.reload.destroy!
        assert_equal [deleted].compact, Slackmine.deliveries.map { |_, opts| opts[:event] }, klass.name
      end
    end
  end
end
