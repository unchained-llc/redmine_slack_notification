# frozen_string_literal: true
require_relative 'admin_overview_test'
require_relative '../app/jobs/slackmine_test_notification_job'

class JobMonitorTest < Minitest::Test
  def test_global_test_destination_uses_shared_fallback
    Slackmine.stub(:config, {'slack' => {'default_channel_id' => ' C123 '}}) do
      assert_equal 'C123', Slackmine::JobMonitor.test_channel(nil)
    end
  end

  def test_only_safe_identifiers_are_extracted_from_jobs
    row = Slackmine::JobMonitor.summary({'wrapped' => 'SlackmineCommandJob', 'jid' => '123',
      'args' => [{'job_id' => '456', 'job_class' => 'SlackmineCommandJob', 'arguments' => ['secret', 'private message']}],
      'error_message' => 'sensitive details', 'error_class' => 'Timeout'}, 'retry', 12)
    assert_equal %w[error id job status timestamp], row.keys.sort
    assert_equal '456', row['id']
    refute_includes row.to_json, 'secret'
    refute_includes row.to_json, 'private message'
    assert_nil Slackmine::JobMonitor.summary({'class' => 'OtherJob', 'args' => [1]}, 'queued')
  end

  def test_tracking_records_outcomes_without_swallowing_job_failures
    job = SlackmineTestNotificationJob.new
    job.extend(Slackmine::JobTracking)
    calls = []
    Slackmine::JobMonitor.stub(:record, ->(*args) { calls << args }) do
      assert_equal :result, job.record_slackmine_execution { :result }
      assert_raises(ArgumentError) { job.record_slackmine_execution { raise ArgumentError, 'private text' } }
    end
    assert_equal %w[completed failed], calls.map { |args| args[1] }
    assert_kind_of ArgumentError, calls.last[3]
  end

  def test_test_notification_refuses_destination_changes
    project = OpenStruct.new(id: 1)
    Project.stub(:find, project) do
      Slackmine.stub(:channel_id, 'CNEW') do
        Slackmine.stub(:bot_token, 'token') do
          Slackmine.stub(:post_message, ->(*) { flunk 'must not send' }) do
            assert_raises(ArgumentError) { SlackmineTestNotificationJob.new.perform(1, 'COLD', 'test') }
          end
        end
      end
    end
  end

  def test_test_notification_uses_selected_destination_and_color
    calls = []
    Slackmine::JobMonitor.stub(:test_channel, 'C123') do
      Slackmine.stub(:bot_token, 'token') do
        Slackmine::Formatter.stub(:attachment_color, '#123456') do
          Slackmine.stub(:post_message, ->(*args) { calls << args }) do
            SlackmineTestNotificationJob.new.perform(nil, 'C123', 'test')
          end
        end
      end
    end
    assert_equal 'C123', calls.first[1]
    assert_equal '#123456', calls.first[0].dig('attachments', 0, 'color')
  end
end

# Minimal Sidekiq API/Redis adapters; the production dependency is optional.
module Sidekiq
  class << self
    attr_accessor :connection
    def redis
      yield connection
    end
  end
  class TestSet
    include Enumerable
    class << self
      attr_accessor :records
    end
    def initialize(*)
    end
    def each(&block)
      Array(self.class.records).each(&block)
    end
    def size
      Array(self.class.records).size
    end
    def latency
      2.0
    end
  end
  class Queue < TestSet; end
  class ScheduledSet < TestSet; end
  class RetrySet < TestSet; end
  class DeadSet < TestSet; end
  class WorkSet < TestSet; end
end


class JobMonitorStorageTest < Minitest::Test
  class Connection
    attr_reader :calls
    def initialize(history = [])
      @calls = []
      @history = history
    end
    def multi
      yield self
    end
    def lpush(*args); @calls << [:lpush, *args]; end
    def ltrim(*args); @calls << [:ltrim, *args]; end
    def expire(*args); @calls << [:expire, *args]; end
    def lrange(*); @history; end
  end

  def test_history_is_bounded_and_contains_no_job_arguments
    Sidekiq.connection = Connection.new
    job = OpenStruct.new(job_id: 'id', arguments: ['secret'])
    Slackmine::JobMonitor.stub(:load_api, nil) do
    Slackmine::JobMonitor.stub(:available?, true) do
      Slackmine::JobMonitor.record(job, 'completed', Process.clock_gettime(Process::CLOCK_MONOTONIC))
    end
    end
    calls = Sidekiq.connection.calls
    assert_equal [:ltrim, Slackmine::JobMonitor::HISTORY_KEY, 0, 99], calls[1]
    assert_equal [:expire, Slackmine::JobMonitor::HISTORY_KEY, 604800], calls[2]
    refute_includes calls[0].last, 'secret'
  end

  def test_snapshot_filters_other_jobs_and_expired_history
    payload = {'class' => 'SlackmineNotificationJob', 'jid' => 'id', 'enqueued_at' => Time.now.to_f}
    Sidekiq::Queue.records = [OpenStruct.new(item: payload), OpenStruct.new(item: {'class' => 'MailerJob', 'args' => [123]})]
    [Sidekiq::ScheduledSet, Sidekiq::RetrySet, Sidekiq::DeadSet, Sidekiq::WorkSet].each { |klass| klass.records = [] }
    Sidekiq.connection = Connection.new([JSON.generate('finished_at' => Time.now.to_f), JSON.generate('finished_at' => 1)])
    Slackmine::JobMonitor.stub(:load_api, nil) do
    Slackmine::JobMonitor.stub(:available?, true) do
      snapshot = Slackmine::JobMonitor.snapshot
      assert snapshot[:available]
      assert_equal 2, snapshot[:queue_size]
      assert_equal 1, snapshot[:entries].length
      assert_equal 1, snapshot[:history].length
      assert_equal 'SlackmineNotificationJob', snapshot[:entries].first['job']
    end
    end
  end
end
