# frozen_string_literal: true
require_relative 'slash_commands_test'

module Rails
  def self.cache; nil; end unless respond_to?(:cache)
end

class SlashCommandsCacheTest < Minitest::Test
  COMMANDS = Slackmine::SlashCommands
  class Cache
    def initialize; @data = {}; end
    def read(key); @data[key]; end
    def write(key, value, unless_exist: false, expires_in:)
      return false if unless_exist && @data.key?(key)
      @data[key] = value
      true
    end
    def delete(key); @data.delete(key); end
  end

  def setup
    @cache = Cache.new
    @viewer = OpenStruct.new(id: 123)
    @payload = { 'type' => 'view_submission', 'user' => { 'id' => 'U123' }, 'view' => {
      'id' => 'V123', 'callback_id' => 'slackmine_command_create', 'private_metadata' => '1',
      'state' => { 'values' => {} } } }
  end

  def submit(&save)
    Rails.stub(:cache, @cache) do
      COMMANDS.stub(:enabled?, true) do
        COMMANDS.stub(:integration?, true) do
          Slackmine::WorkObjects.stub(:viewer_for, @viewer) do
            COMMANDS.stub(:save_form, save) { COMMANDS.interaction('ATEST', 'TTEST', @payload) }
          end
        end
      end
    end
  end

  def test_successful_submission_is_not_repeated
    count = 0
    previous = User.current
    2.times { assert_equal({}, submit { |*| count += 1; {} }) }
    assert_equal 1, count
    assert_same previous, User.current
  end

  def test_validation_error_allows_correction
    assert_equal 'errors', submit { |*| { 'response_action' => 'errors' } }['response_action']
    count = 0
    assert_equal({}, submit { |*| count += 1; {} })
    assert_equal 1, count
  end

  def test_uncertain_failure_does_not_immediately_repeat_write
    assert_raises(RuntimeError) { submit { |*| raise 'Uncertain outcome' } }
    count = 0
    result = submit { |*| count += 1; {} }
    assert_equal 'errors', result['response_action']
    assert_equal 0, count
  end
end
