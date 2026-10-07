# frozen_string_literal: true
require_relative 'image_notification_test'
require_relative '../app/jobs/slackmine_thread_comment_job'

class ThreadCommentBatchTest < Minitest::Test
  BATCH = Slackmine::ThreadCommentBatch

  def setup
    @project = OpenStruct.new(identifier: 'example')
    @issue = OpenStruct.new(project: @project)
    @start = Time.utc(2026, 10, 6).to_i
    @settings = { 'slack' => { 'bot_token' => 'test-token',
                              'thread_comment_batch' => { 'wait_seconds' => 15, 'max_wait_seconds' => 60 } } }
    @event = reply(0)
    @scheduled = []
    @members = {}
    @mention_lookups = []
  end

  def reply(seconds, user = 'U123')
    { 'type' => 'message', 'user' => user, 'channel' => 'C123', 'text' => "Reply #{seconds}",
      'thread_ts' => "#{@start - 1}.000001", 'ts' => "#{@start + seconds}.000001" }
  end

  def collect(messages, now, event = @event, previous: false)
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:slack_api, ->(method, body, *_args, **_options) {
        if method == 'users.info'
          @mention_lookups << body['user']
          next { 'user' => @members.fetch(body['user']) }
        end
        assert_equal 'C123', body['channel']
        { 'messages' => messages }
      }) do
        BATCH.stub(:schedule, ->(*args) { @scheduled << args }) do
          Time.stub(:now, Time.at(@start + now).utc) do
            previous ? BATCH.previous_turn(@issue, event) : BATCH.collect(@issue, 'ATEST', 'TTEST', event)
          end
        end
      end
    end
  end

  def test_quiet_period_extends_and_all_jobs_reconstruct_the_same_group
    messages = [reply(0), reply(10)]
    assert_nil collect(messages, 15)
    assert_in_delta 10, @scheduled.last.last, 0.01
    assert_equal messages, collect(messages, 26)
    assert_equal messages, collect(messages, 26, messages.last)
  end

  def test_maximum_wait_splits_continuous_messages
    messages = [0, 10, 20, 30, 40, 50, 59, 60].map { |second| reply(second) }
    assert_nil collect(messages, 59)
    assert_in_delta 1, @scheduled.last.last, 0.01
    assert_equal messages.first(7), collect(messages, 61)
    assert_nil collect(messages, 61, messages.last)
  end

  def test_author_changes_split_turns_and_bots_do_not_merge_or_split_human_turns
    messages = [reply(0), reply(5, 'UOTHER'), reply(7).merge('bot_id' => 'B123'), reply(10)]
    assert_equal [messages.first], collect(messages, 12)
    assert_equal [messages[1]], collect(messages, 12, messages[1])
    assert_nil collect(messages, 12, messages.last)
    assert_equal [messages.last], collect(messages, 26, messages.last)
    assert_equal [messages.first, messages.last], collect([messages.first, messages[2], messages.last], 26)
  end

  def test_only_adjacent_posts_are_combined_in_conversation_order
    messages = [reply(0), reply(3), reply(5, 'UOTHER'), reply(8)]
    groups = messages.map { |message| collect(messages, 30, message) }.uniq
    assert_equal [messages.first(2), [messages[2]], [messages[3]]], groups
  end

  def test_new_author_closes_previous_turn_before_its_quiet_deadline
    messages = [reply(0), reply(3), reply(5, 'UOTHER'), reply(8)]
    assert_equal messages.first(2), collect(messages, 5, messages[2], previous: true)
    assert_equal [messages[2]], collect(messages, 8, messages.last, previous: true)
    assert_nil collect(messages, 3, messages[1], previous: true)
    assert_nil collect(messages, 0, messages.first, previous: true)
    # A signed event need not already appear in conversations.replies.
    assert_equal messages.first(2), collect(messages.first(2), 5, messages[2], previous: true)
    assert_empty @scheduled
  end

  def test_bots_and_bot_directed_messages_do_not_close_a_human_turn
    @members['UBOT'] = { 'id' => 'UBOT', 'is_bot' => true }
    request = reply(5, 'UOTHER').merge('text' => 'Ask <@UBOT>')
    messages = [reply(0), request, reply(7, 'UBOT').merge('bot_id' => 'B123'), reply(10)]
    assert_nil collect(messages, 5, request, previous: true)
    assert_nil collect(messages, 10, messages.last, previous: true)
  end

  def test_author_change_saves_previous_batch_before_scheduling_new_turn_and_late_jobs_are_duplicates
    @settings['slack']['thread_comments'] = true
    messages = [reply(0), reply(3), reply(5, 'UOTHER')]
    actions = []
    saved = {}
    comments = Slackmine::ThreadComments
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:channel_id, 'C123') do
        Slackmine.stub(:slack_api, ->(method, *, **_) {
          { 'messages' => method == 'conversations.replies' ? messages : [] }
        }) do
          comments.stub(:contexts, [@project]) do
            comments.stub(:issue_from_parent, @issue) do
              Slackmine::WorkObjects.stub(:integration_for, true) do
                comments.stub(:persist_reply, ->(issue, event, team, events: [event]) {
                  next :duplicate if saved[event['ts']]
                  saved[event['ts']] = events
                  actions << [:save, events]
                  :saved
                }) do
                  comments.stub(:feedback, ->(_issue, event, result) { actions << [:feedback, event, result] }) do
                    BATCH.stub(:schedule, ->(*args) { actions << [:schedule, args[2]]; :waiting }) do
                      assert_equal :waiting, comments.process('ATEST', 'TTEST', messages.last)
                      assert_equal [:save, messages.first(2)], actions[0]
                      assert_equal :feedback, actions[1][0]
                      assert_equal [:schedule, messages.last], actions[2]
                      Time.stub(:now, Time.at(@start + 6).utc) do
                        assert_equal :duplicate, comments.process('ATEST', 'TTEST', messages.first, batch_ready: true)
                      end
                      assert_equal 3, actions.size
                      Time.stub(:now, Time.at(@start + 21).utc) do
                        assert_equal :saved, comments.process('ATEST', 'TTEST', messages.last, batch_ready: true)
                      end
                      assert_equal [messages.first(2), [messages.last]], saved.values
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  def test_bot_directed_posts_are_excluded_from_batches_but_human_mentions_remain
    @members = { 'UBOT' => { 'id' => 'UBOT', 'is_bot' => true },
                 'UHUMAN' => { 'id' => 'UHUMAN', 'is_bot' => false } }
    first = reply(0).merge('text' => 'Hello <@UHUMAN>')
    request = reply(5).merge('text' => 'Please report this <@UBOT>')
    last = reply(10).merge('text' => 'Thanks <@UHUMAN>')
    assert_equal [first, last], collect([first, request, last], 26, first)
    assert_equal %w[UHUMAN UBOT], @mention_lookups
    @mention_lookups.clear
    assert_equal [], collect([first, request, last], 26, request)
    assert_equal ['UBOT'], @mention_lookups
  end

  def test_silence_starts_a_new_batch_and_missing_source_uses_accepted_event
    messages = [reply(0), reply(20)]
    assert_equal [messages.first], collect(messages, 40)
    assert_equal [messages.last], collect(messages, 40, messages.last)
    assert_equal [@event], collect([], 40)
  end

  def test_reply_at_the_quiet_deadline_starts_a_new_group
    messages = [reply(0), reply(15)]
    assert_equal [messages.first], collect(messages, 31)
    assert_equal [messages.last], collect(messages, 31, messages.last)
  end

  def test_zero_disables_history_retrieval_and_project_timing_override
    @settings['slack']['thread_comment_batch'] = { 'wait_seconds' => 0 }
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:slack_api, ->(*) { flunk 'Immediate mode fetched history' }) do
        assert_equal [@event], BATCH.collect(@issue, 'ATEST', 'TTEST', @event)
      end
    end
    @settings['projects'] = { 'example' => { 'slack' => { 'thread_comment_batch' => { 'wait_seconds' => 5, 'max_wait_seconds' => 30 } } } }
    Slackmine.stub(:config, @settings) { assert_equal [5, 30], BATCH.timing(@project) }
  end

  def test_omitted_settings_save_immediately_and_maximum_defaults_to_five_minutes
    @settings['slack'].delete('thread_comment_batch')
    Slackmine.stub(:config, @settings) do
      assert_equal [0, 300], BATCH.timing(@project)
      Slackmine.stub(:slack_api, ->(*) { flunk 'Default immediate mode fetched history' }) do
        assert_equal [@event], BATCH.collect(@issue, 'ATEST', 'TTEST', @event)
      end
    end
    @settings['slack']['thread_comment_batch'] = { 'wait_seconds' => 60 }
    Slackmine.stub(:config, @settings) { assert_equal [60, 300], BATCH.timing(@project) }
  end

  def test_incomplete_pagination_does_not_save_a_partial_batch
    Slackmine.stub(:config, @settings) do
      Slackmine.stub(:slack_api, { 'messages' => [@event], 'has_more' => true }) do
        assert_raises(RuntimeError) { BATCH.collect(@issue, 'ATEST', 'TTEST', @event) }
      end
    end
  end

  def test_twenty_messages_flush_without_waiting_and_files_survive
    messages = 20.times.map { |i| reply(i).merge('files' => [{ 'id' => "F#{i}" }]) }
    assert_equal messages, collect(messages, 20)
  end

  def test_delayed_job_retains_identity_and_marks_the_flush_phase
    jobs = []
    SlackmineThreadCommentJob.stub(:set, ->(wait:) { assert_equal 15, wait; SlackmineThreadCommentJob }) do
      SlackmineThreadCommentJob.stub(:perform_later, ->(*args) { jobs << args }) do
        assert_equal :waiting, BATCH.schedule('ATEST', 'TTEST', @event, 15)
      end
    end
    assert_equal ['ATEST', 'TTEST', @event, true], jobs.first
    calls = []
    Slackmine::ThreadComments.stub(:process, ->(*args, **options) { calls << [args, options] }) do
      SlackmineThreadCommentJob.new.perform(*jobs.first)
    end
    assert_equal [['ATEST', 'TTEST', @event], { batch_ready: true }], calls.first
  end
end
