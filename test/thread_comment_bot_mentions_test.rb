# frozen_string_literal: true
require_relative 'thread_comment_batch_test'

class ThreadCommentBotMentionsTest < Minitest::Test
  COMMENTS = Slackmine::ThreadComments

  def setup
    @project = OpenStruct.new(identifier: 'example')
    @issue = OpenStruct.new(id: 7, project: @project)
    @event = { 'type' => 'message', 'user' => 'U123', 'channel' => 'C123',
               'thread_ts' => '1000.000001', 'ts' => '1001.000002', 'text' => 'Please report this <@UBOT>' }
  end

  def test_mentions_are_classified_by_identity_not_display_name
    profiles = { 'UBOT' => { 'id' => 'UBOT', 'is_bot' => true },
                 'UAPP' => { 'id' => 'UAPP', 'is_app_user' => true },
                 'UHUMAN' => { 'id' => 'UHUMAN', 'is_bot' => false } }
    Slackmine.stub(:slack_api, ->(method, body, *, **_) {
      assert_equal 'users.info', method
      { 'user' => profiles.fetch(body['user']) }
    }) do
      assert COMMENTS.addressed_to_bot?(@event, @project)
      assert COMMENTS.addressed_to_bot?(@event.merge('text' => '<@UAPP|Assistant>'), @project)
      refute COMMENTS.addressed_to_bot?(@event.merge('text' => 'Hello <@UHUMAN>'), @project)
      assert COMMENTS.addressed_to_bot?(@event.merge('text' => '<@UHUMAN> ask <@UBOT>'), @project)
    end
  end

  def test_plain_text_and_non_user_mentions_do_not_lookup_slack
    Slackmine.stub(:slack_api, ->(*) { flunk 'No recipient to lookup' }) do
      refute COMMENTS.addressed_to_bot?(@event.merge('text' => 'Bot said hello'), @project)
      refute COMMENTS.addressed_to_bot?(@event.merge('text' => '<!channel> <#C123>'), @project)
    end
  end

  def test_unverified_recipient_or_api_failure_never_counts_as_human
    [{}, { 'user' => { 'id' => 'UOTHER', 'is_bot' => false } }].each do |response|
      Slackmine.stub(:slack_api, response) do
        assert_raises(IOError) { COMMENTS.addressed_to_bot?(@event, @project) }
      end
    end
    Slackmine.stub(:slack_api, ->(*) { raise IOError, 'Temporary API failure' }) do
      assert_raises(IOError) { COMMENTS.addressed_to_bot?(@event, @project) }
    end
  end

  def test_bot_request_does_not_schedule_import_save_comment_or_send_feedback
    settings = { 'slack' => { 'thread_comments' => true,
                            'thread_comment_batch' => { 'wait_seconds' => 60 } } }
    Slackmine.stub(:config, settings) do
      Slackmine.stub(:bot_token, 'test-token') do
        Slackmine.stub(:channel_id, 'C123') do
          Slackmine.stub(:slack_api, ->(method, *, **_) {
            case method
            when 'conversations.history' then { 'messages' => [{}] }
            when 'users.info' then { 'user' => { 'id' => 'UBOT', 'is_bot' => true } }
            else flunk "Unexpected API: #{method}"
            end
          }) do
            COMMENTS.stub(:contexts, [@project]) do
              COMMENTS.stub(:issue_from_parent, @issue) do
                Slackmine::WorkObjects.stub(:integration_for, true) do
                  COMMENTS.stub(:persist_reply, ->(*) { flunk 'Bot request saved' }) do
                    COMMENTS.stub(:feedback, ->(*) { flunk 'Bot request sent feedback' }) do
                      Slackmine::ThreadCommentBatch.stub(:schedule, ->(*) { flunk 'Bot request scheduled' }) do
                        assert_equal :ignored, COMMENTS.process('ATEST', 'TTEST', @event)
                        assert_equal :ignored, COMMENTS.process('ATEST', 'TTEST', @event, batch_ready: true)
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
  end
end
