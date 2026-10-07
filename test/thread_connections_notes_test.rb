# frozen_string_literal: true
# Exercise the real note-building/deduplication code with plain Ruby fixtures.
# No ActiveRecord connection, SQLite, additional DB, or migration is used.
require_relative 'thread_comments_url_test'

class ThreadConnectionsNotesTest < Minitest::Test
  def setup
    fixture = ThreadCommentsUrlTest.new('fixture')
    fixture.setup
    %i[@event @viewer @journal @issue].each { |name| instance_variable_set(name, fixture.instance_variable_get(name)) }
    @stored = []
    @calls = []
    rows = @stored
    @issue.journals.define_singleton_method(:where) do |filter, *|
      filter.is_a?(Hash) ? rows.select { |j| j.user_id == filter[:user_id] && j.created_on == filter[:created_on] } : []
    end
    journal = @journal
    @issue.define_singleton_method(:save!) { journal[:persisted?] = true; rows << journal }
    @time = Slackmine::ThreadComments.posted_at('1791115675.999999')
    other = @event.merge('user' => 'U456', 'ts' => '1791115675.755580', 'text' => 'Second speaker')
    @entries = [@event, other].each_with_index.map do |event, index|
      { 'event' => event, 'card' => { 'author' => index.zero? ? 'Alice' : 'Bob', 'text' => event['text'],
        'timestamp' => Slackmine::ThreadComments.posted_at(event['ts']).iso8601,
        'channel' => 'discussion', 'thread_connection_nonce' => 'a' * 32 } }
    end
  end

  def persist
    Slackmine.stub(:config, { 'slack' => { 'thread_connections' => true, 'thread_comments' => false, 'bot_token' => 'token' } }) do
      Slackmine.stub(:slack_api, ->(method, body, *) {
        @calls << method
        { 'permalink' => "https://example.slack.com/archives/C123/p#{body['message_ts'].delete('.')}" }
      }) do
        Slackmine::ThreadComments.persist_reply(@issue, @event, 'TTEST', events: @entries.map { |e| e['event'] },
          connected: true, import_viewer: @viewer, history_cards: @entries, import_timestamp: @time)
      end
    end
  end

  def test_history_builds_one_journal_with_each_original_speaker_and_connecting_author
    previous = User.current
    assert_equal :saved, persist
    assert_equal 1, @stored.size
    assert_equal @viewer.id, @journal.user_id
    assert_equal @time, @journal.created_on
    cards = Slackmine::LinkQuotes.blocks(@journal.notes).map(&:last)
    assert_equal ['Alice', 'Bob'], cards.map { |c| c['author'] }
    assert_equal ['Reply body', 'Second speaker'], cards.map { |c| c['text'] }
    assert_equal ['a' * 32], cards.map { |c| c['thread_connection_nonce'] }.uniq
    assert_same previous, User.current
    assert_nil Thread.current[:slackmine_thread_comment]
  end

  def test_retry_uses_existing_journal_identity_without_an_additional_store
    assert_equal :saved, persist
    @calls.clear
    assert_equal :duplicate, persist
    assert_equal 1, @stored.size
    assert_empty @calls
  end
end
