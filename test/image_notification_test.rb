# frozen_string_literal: true

require 'minitest/autorun'
require 'ostruct'
require 'date'
require 'rake'

class String
  def present?
    !strip.empty?
  end

  def presence
    present? ? self : nil
  end

  def truncate(length)
    self[0, length]
  end
end

class Array
  def present?
    !empty?
  end
end

class NilClass
  def presence
    nil
  end
end

module Rails
  def self.application
    @application ||= OpenStruct.new(config: OpenStruct.new(to_prepare: nil, after_initialize: nil))
  end

  def self.cache
    @cache
  end

  def self.logger
    @logger
  end
end

class Issue
  attr_reader :id
  attr_accessor :project

  def initialize(id, private_issue: false)
    @id = id
    @private_issue = private_issue
  end

  def is_private?
    @private_issue
  end

  def self.find_by(id:)
    nil
  end

  def self.joins(*)
    nil
  end
end

class CustomField
  def self.find_by(id:)
    OpenStruct.new(name: '顧客分類')
  end
end

class Version
  def self.find_by(id:)
    OpenStruct.new(name: '旧版')
  end

  def self.named(_name)
    nil
  end
end

class PresenceValue < String
  def present?
    !empty?
  end

  def presence
    present? ? self : nil
  end
end

class ApplicationJob
  def self.queue_as(*)
  end

  def self.perform_later(*)
  end
end

class Project
  def self.find_by(id:)
    nil
  end

  def self.find(_value)
    nil
  end
end

class Tracker
  def self.exists?(id:)
    false
  end
end

require_relative '../app/jobs/redmine_slack_notification_job'

class User
  attr_accessor :login, :mail, :name

  def self.find_by(id:)
    nil
  end

  def self.exists?(id:)
    false
  end

  def blank?
    false
  end

  def self.current
    OpenStruct.new(name: 'Kota')
  end
end

class Journal
  def self.find_by(id:)
    nil
  end
end

class News < OpenStruct
end

require_relative '../lib/redmine_slack_notification'

class AutomaticUserMappingTest < Minitest::Test
  class MemoryCache
    def initialize
      @entries = {}
    end

    def fetch(key, expires_in:)
      @entries[key] ||= yield
    end
  end

  def test_disabled_mapping_does_not_fetch_users
    RedmineSlackNotification.stub(:config, { 'slack' => { 'auto_map_users_by_name' => false } }) do
      RedmineSlackNotification.stub(:slack_user_directory, -> { flunk 'users.list was called' }) do
        assert_nil RedmineSlackNotification.slack_user_id_for_name('kota')
      end
    end
  end

  def test_matches_only_a_unique_name_without_case_sensitivity
    directory = { 'kota' => ['U123'], 'jun' => %w[U456 U789] }
    RedmineSlackNotification.stub(:config, { 'slack' => { 'auto_map_users_by_name' => true } }) do
      RedmineSlackNotification.stub(:slack_user_directory, directory) do
        assert_equal 'U123', RedmineSlackNotification.slack_user_id_for_name(' Kota ')
        assert_nil RedmineSlackNotification.slack_user_id_for_name('jun')
        assert_nil RedmineSlackNotification.slack_user_id_for_name('missing')
      end
    end
  end

  def test_explicit_mapping_takes_precedence_over_automatic_lookup
    user = User.new
    user.login = 'kota'
    user.mail = 'kota@example.com'
    user.name = 'Kota'
    RedmineSlackNotification.stub(:user_mapping, { 'kota' => PresenceValue.new('U123') }) do
      RedmineSlackNotification.stub(:slack_user_id_for_name, ->(*) { flunk 'automatic lookup ran' }) do
        assert_equal '<@U123>', RedmineSlackNotification::Formatter.user_mention(user)
      end
    end
  end

  def test_unmapped_user_uses_automatic_lookup
    user = User.new
    user.login = 'kota'
    user.mail = 'kota@example.com'
    user.name = 'Kota'
    RedmineSlackNotification.stub(:user_mapping, {}) do
      RedmineSlackNotification.stub(:slack_user_id_for_name, PresenceValue.new('U123')) do
        assert_equal '<@U123>', RedmineSlackNotification::Formatter.user_mention(user)
      end
    end
  end

  def test_user_directory_paginates_and_ignores_non_human_accounts
    calls = []
    responses = [
      { 'members' => [
          { 'id' => 'U123', 'name' => 'kota', 'profile' => { 'display_name' => 'Kota' } },
          { 'id' => 'B123', 'name' => 'bot', 'is_bot' => true },
          { 'id' => 'U456', 'name' => 'former', 'deleted' => true }
        ], 'response_metadata' => { 'next_cursor' => 'next' } },
      { 'members' => [
          { 'id' => 'U789', 'name' => 'jun', 'profile' => { 'display_name' => 'Kota' } },
          { 'id' => 'U999', 'name' => 'outsider', 'is_stranger' => true }
        ], 'response_metadata' => { 'next_cursor' => '' } }
    ]
    api = lambda do |method, params, token, **options|
      calls << [method, params, token, options]
      responses.shift
    end

    RedmineSlackNotification.stub(:slack_api, api) do
      directory = RedmineSlackNotification.fetch_slack_user_directory('token')
      assert_equal %w[U123 U789], directory['kota']
      assert_equal ['U789'], directory['jun']
      refute directory.key?('bot')
      refute directory.key?('former')
      refute directory.key?('outsider')
    end
    assert_equal [{ 'limit' => 200 }, { 'limit' => 200, 'cursor' => 'next' }], calls.map { |call| call[1] }
    assert calls.all? { |call| call[0] == 'users.list' && call[2] == 'token' && call[3][:form] }
  end

  def test_directory_is_cached_and_api_failure_falls_back_to_plain_name
    cache = MemoryCache.new
    warnings = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |message| warnings << message }
    attempts = 0
    api = lambda do |*|
      attempts += 1
      raise 'missing_scope'
    end

    Rails.stub(:cache, cache) do
      Rails.stub(:logger, logger) do
        RedmineSlackNotification.stub(:bot_token, 'token') do
          RedmineSlackNotification.stub(:slack_api, api) do
            assert_equal({}, RedmineSlackNotification.slack_user_directory)
            assert_equal({}, RedmineSlackNotification.slack_user_directory)
          end
        end
      end
    end
    assert_equal 1, attempts
    assert_equal 1, warnings.length
    assert_includes warnings.first, 'missing_scope'
  end
end

class ProjectConfigurationTest < Minitest::Test
  def project(identifier = 'agentic')
    OpenStruct.new(id: 7, identifier: identifier, name: identifier)
  end

  def settings
    {
      'slack' => {
        'bot_token' => 'global-token', 'default_channel_id' => 'C_GLOBAL',
        'attachment_color' => '#6D5DFB', 'auto_map_users_by_name' => false,
        'body_diff' => { 'issue' => { 'description' => true, 'comment' => true } },
        'metadata' => { 'issue' => { 'project' => true, 'tracker' => true } },
        'issue_changes_when_hidden' => true
      },
      'messages' => { 'events' => { 'issue' => { 'created' => 'Global issue created' } } },
      'users' => { 'alice' => 'U_GLOBAL', 'bob' => 'U_BOB' },
      'projects' => {
        'agentic' => {
          'slack' => {
            'bot_token' => 'project-token', 'default_channel_id' => 'C_PROJECT',
            'attachment_color' => '#123456', 'auto_map_users_by_name' => true,
            'body_diff' => { 'issue' => { 'comment' => false } },
            'metadata' => { 'issue' => { 'project' => false } },
            'issue_changes_when_hidden' => false
          },
          'messages' => {
            'events' => { 'issue' => { 'created' => 'Project issue created' } },
            'sections' => { 'comment' => 'Project comment' }
          },
          'users' => { 'alice' => 'U_PROJECT' }
        }
      }
    }
  end

  def test_project_overrides_all_config_sections_without_losing_global_siblings
    RedmineSlackNotification.stub(:config, settings) do
      ENV.stub(:[], ->(key) { key == 'SLACK_BOT_TOKEN' ? 'environment-token' : nil }) do
        assert_equal 'project-token', RedmineSlackNotification.bot_token(project)
        assert_equal 'environment-token', RedmineSlackNotification.bot_token(project('other'))
      end
      assert_equal 'C_PROJECT', RedmineSlackNotification.channel_id(project)
      assert_equal 'C_GLOBAL', RedmineSlackNotification.channel_id(project('other'))

      RedmineSlackNotification.with_project(project) do
        assert_equal 'Project issue created', RedmineSlackNotification::Formatter.message('events', 'issue', 'created')
        assert_equal 'Issue updated', RedmineSlackNotification::Formatter.message('events', 'issue', 'updated')
        assert_equal '#123456', RedmineSlackNotification::Formatter.attachment_color
        assert RedmineSlackNotification.body_diff_enabled?(:issue_description)
        refute RedmineSlackNotification.body_diff_enabled?(:issue_comment)
        assert_equal false, RedmineSlackNotification.effective_config.dig('slack', 'issue_changes_when_hidden')
        assert_equal({ 'alice' => 'U_PROJECT', 'bob' => 'U_BOB' }, RedmineSlackNotification.user_mapping)
        user = User.new
        user.login = 'alice'
        user.mail = 'alice@example.com'
        user.name = 'Alice'
        assert_equal '<@U_PROJECT>', RedmineSlackNotification::Formatter.user_mention(user)
        RedmineSlackNotification.stub(:slack_user_directory, { 'charlie' => ['U_CHARLIE'] }) do
          assert_equal 'U_CHARLIE', RedmineSlackNotification.slack_user_id_for_name('charlie')
        end
      end
      assert_equal 'Global issue created', RedmineSlackNotification::Formatter.message('events', 'issue', 'created')
      assert_equal '#6D5DFB', RedmineSlackNotification::Formatter.attachment_color
      assert RedmineSlackNotification.body_diff_enabled?(:issue_comment)
      RedmineSlackNotification.with_project(project('other')) do
        assert_nil RedmineSlackNotification.slack_user_id_for_name('charlie')
      end
    end
  end

  def test_payload_and_delivery_use_the_same_project_overrides
    issue = OpenStruct.new(id: 42, subject: 'Example', description: '', project: project,
                           tracker: OpenStruct.new(name: 'Task'))
    other_issue = OpenStruct.new(id: 43, subject: 'Other', description: '', project: project('other'),
                                 tracker: OpenStruct.new(name: 'Task'))
    deliveries = []

    RedmineSlackNotification.stub(:config, settings) do
      card = RedmineSlackNotification::Formatter.issue_payload(issue, actor: nil, action: 'created')
      other_card = RedmineSlackNotification::Formatter.issue_payload(other_issue, actor: nil, action: 'created')
      assert_equal '#123456', card.dig('attachments', 0, 'color')
      assert_includes card.dig('attachments', 0, 'blocks', 0, 'text', 'text'), 'Project issue created'
      fields = card.dig('attachments', 0, 'blocks').flat_map { |block| block.fetch('fields', []) }
      refute fields.any? { |field| field.fetch('text').start_with?('*Project*') }
      assert fields.any? { |field| field.fetch('text').start_with?('*Tracker*') }
      assert_equal '#6D5DFB', other_card.dig('attachments', 0, 'color')
      assert_includes other_card.dig('attachments', 0, 'blocks', 0, 'text', 'text'), 'Global issue created'

      ENV.stub(:[], ->(_key) { nil }) do
        RedmineSlackNotification.stub(:post_message, ->(payload, channel, token) { deliveries << [payload, channel, token] }) do
          RedmineSlackNotification.notify(card, project: project)
          RedmineSlackNotification.notify(other_card, project: project('other'))
        end
      end
    end
    assert_equal ['C_PROJECT', 'project-token'], deliveries[0].last(2)
    assert_equal ['C_GLOBAL', 'global-token'], deliveries[1].last(2)
  end

  def test_nested_project_context_restores_previous_project_even_after_error
    RedmineSlackNotification.stub(:config, settings) do
      RedmineSlackNotification.with_project(project) do
        assert_raises(RuntimeError) do
          RedmineSlackNotification.with_project(project('other')) { raise 'stop' }
        end
        assert_equal 'Project issue created', RedmineSlackNotification::Formatter.message('events', 'issue', 'created')
      end
      assert_equal 'Global issue created', RedmineSlackNotification::Formatter.message('events', 'issue', 'created')
    end
  end

  def test_news_comment_diff_heading_uses_project_message
    RedmineSlackNotification.stub(:config, settings) do
      card = RedmineSlackNotification::Formatter.generic_payload(
        noun: 'News comment', action: 'updated', subject: 'Title', url: 'https://example.com/news/1',
        project: project, actor: nil, body_diff: ['before', 'after'], body_diff_label: :comment
      )
      diff = card.dig('attachments', 0, 'blocks').find { |block| block['type'] == 'markdown' }
      assert_includes diff['text'], 'Project comment diff'

      other_card = RedmineSlackNotification::Formatter.generic_payload(
        noun: 'News comment', action: 'updated', subject: 'Title', url: 'https://example.com/news/1',
        project: project('other'), actor: nil, body_diff: ['before', 'after'], body_diff_label: :comment
      )
      other_diff = other_card.dig('attachments', 0, 'blocks').find { |block| block['type'] == 'markdown' }
      assert_includes other_diff['text'], 'Comment diff'
    end
  end
end

class EventConfigurationTest < Minitest::Test
  class TestJournal < Journal
    attr_accessor :journalized, :notes, :details, :user, :id, :updated_by, :previous_notes, :previous_private_notes

    def private_notes?
      false
    end

    def self.after_create_commit(*)
    end

    def self.after_update_commit(*)
    end

    def saved_change_to_notes?
      previous_notes != notes
    end

    def notes_before_last_save
      previous_notes
    end

    def attribute_before_last_save(name)
      previous_private_notes if name == 'private_notes'
    end

    include RedmineSlackNotification::JournalPatch
  end

  def project
    OpenStruct.new(id: 7, identifier: 'agentic')
  end

  def journal
    issue = Issue.new(7098)
    issue.project = project
    item = TestJournal.new
    item.journalized = issue
    item.notes = 'Comment ![](screenshot.png)'
    item.details = [:changed]
    item.user = OpenStruct.new(name: 'Kota')
    item.id = 12
    item
  end

  def test_events_default_to_enabled_and_project_overrides_global_setting
    settings = {
      'events' => { 'comment_added' => false, 'issue_updated' => true },
      'projects' => { 'agentic' => { 'events' => { 'comment_added' => true, 'issue_updated' => false } } }
    }
    RedmineSlackNotification.stub(:config, settings) do
      assert RedmineSlackNotification.event_enabled?(project, 'comment_added')
      refute RedmineSlackNotification.event_enabled?(project, 'issue_updated')
      assert RedmineSlackNotification.event_enabled?(project, 'wiki_created')
      refute RedmineSlackNotification.event_enabled?(OpenStruct.new(identifier: 'other'), 'comment_added')
    end
  end

  def test_issue_updated_disables_relation_events_even_when_explicitly_enabled
    RedmineSlackNotification.stub(:config, { 'events' => { 'issue_updated' => false } }) do
      refute RedmineSlackNotification.event_enabled?(project, 'relation_added')
      refute RedmineSlackNotification.event_enabled?(project, 'relation_removed')
    end
    RedmineSlackNotification.stub(:config, { 'events' => { 'issue_updated' => false, 'relation_added' => true } }) do
      refute RedmineSlackNotification.event_enabled?(project, 'relation_added')
    end
  end

  def test_example_yaml_lists_every_supported_event
    example = YAML.safe_load(File.read(File.expand_path('../config/redmine_slack_notification.yml.example', __dir__)))
    events = example.fetch('events')
    assert_equal true, events.dig('issue', 'updated', 'enabled')
    assert_equal RedmineSlackNotification::EVENT_KEYS.sort, RedmineSlackNotification::EVENT_PATHS.keys.sort
    assert_equal RedmineSlackNotification::EVENT_PATHS.length,
                 RedmineSlackNotification::EVENT_PATHS.values.uniq.length
    RedmineSlackNotification::EVENT_PATHS.each do |event, path|
      value = events.dig(*path)
      assert_includes [true, false], value, "Missing nested YAML setting for #{event}: #{path.join('.')}"
    end
    disabled = RedmineSlackNotification::EVENT_PATHS.select { |_key, path| events.dig(*path) == false }.keys
    assert_equal RedmineSlackNotification::DEFAULT_DISABLED_EVENTS.sort, disabled.sort
  end

  def test_nested_issue_parent_and_detail_switches
    settings = {
      'events' => {
        'issue' => {
          'updated' => { 'enabled' => false, 'status_changed' => true },
          'comment' => { 'added' => true, 'deleted' => true }
        }
      }
    }
    RedmineSlackNotification.stub(:config, settings) do
      refute RedmineSlackNotification.event_enabled?(project, 'status_changed')
      refute RedmineSlackNotification.event_enabled?(project, 'issue_updated')
      assert RedmineSlackNotification.event_enabled?(project, 'comment_added')
      assert RedmineSlackNotification.event_enabled?(project, 'comment_deleted')
    end

    settings['events']['issue']['updated'] = { 'enabled' => true, 'status_changed' => false, 'other_changed' => false }
    RedmineSlackNotification.stub(:config, settings) do
      refute RedmineSlackNotification.event_enabled?(project, 'status_changed')
      refute RedmineSlackNotification.event_enabled?(project, 'issue_updated')
      assert RedmineSlackNotification.event_enabled?(project, 'assignee_changed')
    end
  end

  def test_nested_project_override_and_legacy_flat_fallback_for_all_event_families
    settings = {
      'events' => {
        'issue_updated' => false,
        'news_updated' => false,
        'wiki_deleted' => true,
        'time_entry' => { 'created' => false },
        'version' => { 'deleted' => true },
        'project' => { 'updated' => false }
      },
      'projects' => {
        'agentic' => { 'events' => {
          'issue' => { 'updated' => { 'enabled' => true, 'attachment' => { 'added' => false } } },
          'news' => { 'updated' => true, 'comment' => { 'added' => false } },
          'wiki' => { 'deleted' => false }
        } }
      }
    }
    RedmineSlackNotification.stub(:config, settings) do
      assert RedmineSlackNotification.event_enabled?(project, 'status_changed')
      refute RedmineSlackNotification.event_enabled?(project, 'attachment_added')
      assert RedmineSlackNotification.event_enabled?(project, 'news_updated')
      refute RedmineSlackNotification.event_enabled?(project, 'news_comment_added')
      refute RedmineSlackNotification.event_enabled?(project, 'wiki_deleted')
      refute RedmineSlackNotification.event_enabled?(project, 'time_entry_created')
      assert RedmineSlackNotification.event_enabled?(project, 'version_deleted')
      refute RedmineSlackNotification.event_enabled?(project, 'project_updated')
    end
  end

  def test_news_comment_is_independent_of_news_update
    settings = { 'events' => { 'news' => { 'updated' => false, 'comment' => { 'added' => true, 'updated' => true } } } }
    RedmineSlackNotification.stub(:config, settings) do
      refute RedmineSlackNotification.event_enabled?(project, 'news_updated')
      assert RedmineSlackNotification.event_enabled?(project, 'news_comment_added')
      assert RedmineSlackNotification.event_enabled?(project, 'news_comment_updated')
    end
  end

  def test_comment_edit_and_removal_default_to_enabled
    RedmineSlackNotification.stub(:config, {}) do
      %w[comment_updated comment_deleted news_comment_updated news_comment_deleted].each do |event|
        assert RedmineSlackNotification.event_enabled?(project, event), event
      end
    end
  end

  def test_nested_setting_wins_over_flat_setting_in_the_same_scope
    settings = { 'events' => { 'status_changed' => false,
                                'issue' => { 'updated' => { 'enabled' => true, 'status_changed' => true } } } }
    RedmineSlackNotification.stub(:config, settings) do
      assert RedmineSlackNotification.event_enabled?(project, 'status_changed')
    end
  end

  def test_project_flat_setting_can_override_nested_global_leaf_and_parent
    settings = {
      'events' => { 'issue' => { 'updated' => { 'enabled' => false, 'status_changed' => false } } },
      'projects' => { 'agentic' => { 'events' => { 'issue_updated' => true, 'status_changed' => true } } }
    }
    RedmineSlackNotification.stub(:config, settings) do
      assert RedmineSlackNotification.event_enabled?(project, 'status_changed')
      refute RedmineSlackNotification.event_enabled?(OpenStruct.new(identifier: 'other'), 'status_changed')
    end
  end

  def test_every_nested_event_leaf_can_disable_its_notification
    RedmineSlackNotification::EVENT_PATHS.each do |event, path|
      events = { 'issue' => { 'updated' => { 'enabled' => true } } }
      target = events
      path[0...-1].each { |part| target = target[part] ||= {} }
      target[path.last] = false
      RedmineSlackNotification.stub(:config, { 'events' => events }) do
        refute RedmineSlackNotification.event_enabled?(project, event), path.join('.')
      end
    end
  end

  def test_every_nested_event_leaf_can_be_overridden_for_a_project
    RedmineSlackNotification::EVENT_PATHS.each do |event, path|
      [[false, true], [true, false]].each do |global_value, project_value|
        global_events = {}
        project_events = {}
        [[global_events, global_value], [project_events, project_value]].each do |events, value|
          target = events
          path[0...-1].each { |part| target = target[part] ||= {} }
          target[path.last] = value
        end
        settings = { 'events' => global_events,
                     'projects' => { 'agentic' => { 'events' => project_events } } }
        RedmineSlackNotification.stub(:config, settings) do
          assert_equal project_value, RedmineSlackNotification.event_enabled?(project, event),
                       "Project override failed for #{path.join('.')}"
          assert_equal global_value,
                       RedmineSlackNotification.event_enabled?(OpenStruct.new(identifier: 'other'), event),
                       "Global value changed for #{path.join('.')}"
        end
      end
    end
  end

  def test_project_can_override_issue_update_parent_and_detail_together
    settings = {
      'events' => { 'issue' => { 'updated' => { 'enabled' => false, 'status_changed' => false } } },
      'projects' => { 'agentic' => { 'events' => {
        'issue' => { 'updated' => { 'enabled' => true, 'status_changed' => true } }
      } } }
    }
    RedmineSlackNotification.stub(:config, settings) do
      assert RedmineSlackNotification.event_enabled?(project, 'status_changed')
      refute RedmineSlackNotification.event_enabled?(OpenStruct.new(identifier: 'other'), 'status_changed')
    end
  end

  def test_all_flat_event_keys_remain_supported
    RedmineSlackNotification::EVENT_KEYS.each do |event|
      RedmineSlackNotification.stub(:config, { 'events' => { event => false } }) do
        refute RedmineSlackNotification.event_enabled?(project, event), event
      end
    end
  end

  def test_new_deletion_events_default_to_disabled_and_can_be_overridden
    RedmineSlackNotification.stub(:config, {}) do
      RedmineSlackNotification::DEFAULT_DISABLED_EVENTS.each do |event|
        refute RedmineSlackNotification.event_enabled?(project, event)
      end
    end
    RedmineSlackNotification.stub(:config, { 'projects' => { 'agentic' => { 'events' => { 'wiki_deleted' => true } } } }) do
      assert RedmineSlackNotification.event_enabled?(project, 'wiki_deleted')
    end
  end

  def test_issue_updated_is_the_parent_switch_for_every_issue_detail
    details = RedmineSlackNotification::ISSUE_DETAIL_EVENTS.to_h { |event| [event, true] }
    RedmineSlackNotification.stub(:config, { 'events' => details.merge('issue_updated' => false) }) do
      RedmineSlackNotification::ISSUE_DETAIL_EVENTS.each do |event|
        refute RedmineSlackNotification.event_enabled?(project, event), event
      end
    end
  end

  def test_project_can_enable_issue_updates_while_honoring_a_global_detail_switch
    settings = {
      'events' => { 'issue_updated' => false, 'assignee_changed' => false },
      'projects' => { 'agentic' => { 'events' => { 'issue_updated' => true, 'status_changed' => true } } }
    }
    RedmineSlackNotification.stub(:config, settings) do
      assert RedmineSlackNotification.event_enabled?(project, 'status_changed')
      refute RedmineSlackNotification.event_enabled?(project, 'assignee_changed')
    end
  end

  def test_project_issue_update_parent_disables_global_detail
    settings = {
      'events' => { 'status_changed' => true },
      'projects' => { 'agentic' => { 'events' => { 'issue_updated' => false } } }
    }
    RedmineSlackNotification.stub(:config, settings) do
      refute RedmineSlackNotification.event_enabled?(project, 'status_changed')
    end
  end

  def test_each_journal_detail_maps_to_an_independent_event
    examples = {
      'attr' => {
        'status_id' => 'status_changed', 'assigned_to_id' => 'assignee_changed',
        'priority_id' => 'priority_changed', 'due_date' => 'due_date_changed',
        'start_date' => 'start_date_changed', 'fixed_version_id' => 'version_changed',
        'subject' => 'subject_changed', 'description' => 'description_changed',
        'parent_id' => 'parent_changed', 'category_id' => 'category_changed'
      },
      'cf' => { '42' => 'custom_field_changed' }
    }
    item = journal
    examples.each do |property, fields|
      fields.each do |key, event|
        assert_equal event, item.send(:slack_event_for_detail, OpenStruct.new(property: property, prop_key: key, value: 'new'))
      end
    end
    assert_equal 'attachment_added', item.send(:slack_event_for_detail, OpenStruct.new(property: 'attachment', value: 'new.png'))
    assert_equal 'attachment_removed', item.send(:slack_event_for_detail, OpenStruct.new(property: 'attachment', value: nil))
    assert_equal 'child_added', item.send(:slack_event_for_detail, OpenStruct.new(property: 'attr', prop_key: 'child_id', value: 7))
    assert_equal 'child_removed', item.send(:slack_event_for_detail, OpenStruct.new(property: 'attr', prop_key: 'child_id', value: nil))
  end

  def test_disabled_detail_does_not_hide_enabled_detail
    status = OpenStruct.new(property: 'attr', prop_key: 'status_id', value: 2)
    due_date = OpenStruct.new(property: 'attr', prop_key: 'due_date', value: '2026-10-01')
    assert_journal_notification(
      { 'status_changed' => false }, details: [status, due_date], notes: '',
      expected_payload: :update, expected_details: [due_date],
      expected_event: 'due_date_changed', expected_images: [], expected_journal_id: nil
    )
  end

  def test_nested_issue_settings_filter_one_journal_without_losing_enabled_content
    status = OpenStruct.new(property: 'attr', prop_key: 'status_id', value: 2)
    due_date = OpenStruct.new(property: 'attr', prop_key: 'due_date', value: '2026-10-01')
    assert_journal_notification(
      { 'issue' => { 'updated' => { 'enabled' => true, 'status_changed' => false, 'due_date_changed' => true },
                     'comment' => { 'added' => true } } },
      details: [status, due_date], expected_payload: :comment, expected_details: [due_date],
      expected_event: 'due_date_changed', expected_images: ['screenshot.png'], expected_journal_id: 12
    )
  end

  def test_category_change_has_its_own_switch
    category = OpenStruct.new(property: 'attr', prop_key: 'category_id', value: 3)
    status = OpenStruct.new(property: 'attr', prop_key: 'status_id', value: 2)
    assert_journal_notification(
      { 'issue' => { 'updated' => { 'enabled' => true, 'other_changed' => true, 'category_changed' => false } } },
      details: [category, status], notes: '', expected_payload: :update, expected_details: [status],
      expected_event: 'status_changed', expected_images: [], expected_journal_id: nil
    )
    RedmineSlackNotification.stub(:config, {
      'events' => { 'issue' => { 'updated' => { 'enabled' => true, 'other_changed' => false, 'category_changed' => true } } }
    }) do
      assert RedmineSlackNotification.event_enabled?(project, 'category_changed')
      refute RedmineSlackNotification.event_enabled?(project, 'issue_updated')
    end
  end

  def test_issue_comment_edit_and_removal_have_separate_events
    item = journal
    item.previous_notes = 'Previous public comment'
    item.updated_by = OpenStruct.new(name: 'Editor')
    calls = []
    formatter = ->(_issue, **kwargs) { calls << [:payload, kwargs]; :message }
    enqueue = ->(message, **kwargs) { calls << [:enqueue, message, kwargs] }

    RedmineSlackNotification.stub(:config, {}) do
      RedmineSlackNotification::Formatter.stub(:journal_payload, formatter) do
        RedmineSlackNotification.stub(:enqueue, enqueue) do
          item.notes = 'Edited comment ![](screenshot.png)'
          item.send(:notify_slack_journal_comment_changed)
          item.notes = ''
          item.send(:notify_slack_journal_comment_changed)
        end
      end
    end

    assert_equal %w[updated deleted], calls.select { |call| call[0] == :payload }.map { |call| call[1][:comment_action] }
    assert_equal %w[comment_updated comment_deleted], calls.select { |call| call[0] == :enqueue }.map { |call| call[2][:event] }
    assert_equal 'Editor', calls[0][1][:actor].name
    assert_equal 'Previous public comment', calls[0][1][:previous_notes]
    assert_equal 'Previous public comment', calls[2][1][:previous_notes]
    assert_equal ['screenshot.png'], calls[1][2][:image_names]
    assert_equal 12, calls[1][2][:journal_id]
    assert_empty calls[3][2][:image_names]
    assert_nil calls[3][2][:journal_id]
  end

  def test_issue_comment_removal_respects_setting_and_privacy
    item = journal
    item.previous_notes = 'Previous public comment'
    item.notes = ''
    settings = { 'events' => { 'issue' => { 'comment' => { 'deleted' => false } } } }
    RedmineSlackNotification.stub(:config, settings) do
      RedmineSlackNotification.stub(:enqueue, ->(*) { flunk 'disabled removal was enqueued' }) do
        item.send(:notify_slack_journal_comment_changed)
      end
    end

    item.previous_private_notes = true
    RedmineSlackNotification.stub(:enqueue, ->(*) { flunk 'private removal was enqueued' }) do
      item.send(:notify_slack_journal_comment_changed)
    end
  end

  def test_disabled_event_is_not_enqueued
    RedmineSlackNotification.stub(:config, { 'events' => { 'issue_created' => false } }) do
      RedmineSlackNotificationJob.stub(:perform_later, ->(*) { flunk 'disabled event was enqueued' }) do
        RedmineSlackNotification.enqueue({ 'text' => 'issue' }, project: project, event: 'issue_created')
      end
    end
  end

  def test_comment_only_event_omits_issue_changes
    assert_journal_notification(
      { 'issue_updated' => false },
      expected_payload: :comment, expected_details: [], expected_event: 'comment_added',
      expected_images: ['screenshot.png'], expected_journal_id: 12
    )
  end

  def test_issue_update_only_event_omits_comment_and_image
    assert_journal_notification(
      { 'comment_added' => false },
      expected_payload: :update, expected_details: [:changed], expected_event: 'issue_updated',
      expected_images: [], expected_journal_id: nil
    )
  end

  def test_both_enabled_keep_combined_notification
    assert_journal_notification(
      {}, expected_payload: :comment, expected_details: [:changed],
      expected_event: 'issue_updated', expected_images: ['screenshot.png'], expected_journal_id: 12
    )
  end

  def test_relation_addition_can_be_disabled_without_hiding_issue_changes
    relation = OpenStruct.new(property: 'relation', value: 7011)
    assert_journal_notification(
      { 'relation_added' => false }, details: [:changed, relation],
      expected_payload: :comment, expected_details: [:changed],
      expected_event: 'issue_updated', expected_images: ['screenshot.png'], expected_journal_id: 12
    )
  end

  def test_relation_addition_is_blocked_by_issue_updated_but_comment_remains
    relation = OpenStruct.new(property: 'relation', value: 7011)
    assert_journal_notification(
      { 'issue_updated' => false, 'relation_added' => true }, details: [:changed, relation],
      expected_payload: :comment, expected_details: [],
      expected_event: 'comment_added', expected_images: ['screenshot.png'], expected_journal_id: 12
    )
  end

  def test_relation_removal_can_be_disabled_independently
    relation = OpenStruct.new(property: 'relation', value: nil, old_value: 7011)
    assert_journal_notification(
      { 'relation_removed' => false }, details: [:changed, relation],
      expected_payload: :comment, expected_details: [:changed],
      expected_event: 'issue_updated', expected_images: ['screenshot.png'], expected_journal_id: 12
    )
  end

  def test_relation_only_journal_uses_relation_event
    relation = OpenStruct.new(property: 'relation', value: nil, old_value: 7011)
    assert_journal_notification(
      { 'issue_updated' => true, 'relation_removed' => true }, details: [relation], notes: '',
      expected_payload: :update, expected_details: [relation],
      expected_event: 'relation_removed', expected_images: [], expected_journal_id: nil
    )
  end

  def test_relation_only_journal_is_suppressed_by_issue_updated
    item = journal
    item.notes = ''
    item.details = [OpenStruct.new(property: 'relation', value: 7011)]
    RedmineSlackNotification.stub(:config, { 'events' => { 'issue_updated' => false, 'relation_added' => true } }) do
      RedmineSlackNotification.stub(:enqueue, ->(*) { flunk 'disabled Issue update was enqueued' }) do
        item.send(:notify_slack_journal_created)
      end
    end
  end

  def test_disabled_relation_only_journal_sends_nothing
    item = journal
    item.notes = ''
    item.details = [OpenStruct.new(property: 'relation', value: 7011)]
    RedmineSlackNotification.stub(:config, { 'events' => { 'relation_added' => false } }) do
      RedmineSlackNotification.stub(:enqueue, ->(*) { flunk 'disabled relation was enqueued' }) do
        item.send(:notify_slack_journal_created)
      end
    end
  end

  def test_both_disabled_send_nothing
    RedmineSlackNotification.stub(:config, { 'events' => { 'comment_added' => false, 'issue_updated' => false } }) do
      RedmineSlackNotification.stub(:enqueue, ->(*) { flunk 'disabled journal was enqueued' }) do
        journal.send(:notify_slack_journal_created)
      end
    end
  end

  private

  def assert_journal_notification(settings, expected_payload:, expected_details:, expected_event:, expected_images:, expected_journal_id:, details: [:changed], notes: 'Comment ![](screenshot.png)')
    calls = []
    comment_payload = ->(_issue, actor:, notes:, details:) { calls << [:comment, details, notes]; :comment }
    update_payload = ->(_issue, actor:, action:, details:) { calls << [:update, details, action]; :update }
    enqueue = ->(payload, **options) { calls << [:enqueue, payload, options] }
    RedmineSlackNotification.stub(:config, { 'events' => settings }) do
      RedmineSlackNotification::Formatter.stub(:journal_payload, comment_payload) do
        RedmineSlackNotification::Formatter.stub(:issue_payload, update_payload) do
          RedmineSlackNotification.stub(:enqueue, enqueue) do
            item = journal
            item.details = details
            item.notes = notes
            item.send(:notify_slack_journal_created)
          end
        end
      end
    end
    assert_equal expected_payload, calls[0][0]
    assert_equal expected_details, calls[0][1]
    assert_equal expected_payload, calls[1][1]
    assert_equal expected_event, calls[1][2][:event]
    assert_equal expected_images, calls[1][2][:image_names]
    if expected_journal_id.nil?
      assert_nil calls[1][2][:journal_id]
    else
      assert_equal expected_journal_id, calls[1][2][:journal_id]
    end
  end
end

class NewsCommentDeletionTest < Minitest::Test
  def test_news_comment_edit_sends_diff_using_its_own_event
    news = News.new(id: 17, title: 'Release', project: OpenStruct.new(id: 7, identifier: 'agentic'))
    comment = OpenStruct.new(commented: news, content: 'after')
    comment.define_singleton_method(:saved_change_to_content?) { true }
    comment.define_singleton_method(:content_before_last_save) { 'before' }
    comment.extend(RedmineSlackNotification::CommentPatch)
    captured = []
    formatter = ->(**kwargs) { captured << [:payload, kwargs]; :message }
    enqueue = ->(message, **kwargs) { captured << [:enqueue, message, kwargs] }

    RedmineSlackNotification::Formatter.stub(:generic_payload, formatter) do
      RedmineSlackNotification.stub(:enqueue, enqueue) do
        comment.send(:notify_slack_news_comment_updated)
      end
    end

    assert_equal 'News comment', captured[0][1][:noun]
    assert_equal 'updated', captured[0][1][:action]
    assert_equal ['before', 'after'], captured[0][1][:body_diff]
    assert_equal :comment, captured[0][1][:body_diff_label]
    assert_equal :updated_comment, captured[0][1][:body_full_label]
    assert_equal 'news_comment_updated', captured[1][2][:event]
  end

  def test_news_comment_update_without_content_change_is_ignored
    comment = OpenStruct.new
    comment.define_singleton_method(:saved_change_to_content?) { false }
    comment.extend(RedmineSlackNotification::CommentPatch)
    RedmineSlackNotification.stub(:enqueue, ->(*) { flunk 'unchanged comment was enqueued' }) do
      comment.send(:notify_slack_news_comment_updated)
    end
  end

  def test_news_comment_removal_sends_removed_text_as_a_diff
    news = News.new(id: 17, title: 'Release', project: OpenStruct.new(id: 7, identifier: 'agentic'))
    comment = OpenStruct.new(commented: news, content: 'Removed comment')
    comment.extend(RedmineSlackNotification::CommentPatch)
    captured = []
    formatter = ->(**kwargs) { captured << [:payload, kwargs]; :message }
    enqueue = ->(message, **kwargs) { captured << [:enqueue, message, kwargs] }

    RedmineSlackNotification::Formatter.stub(:generic_payload, formatter) do
      RedmineSlackNotification.stub(:enqueue, enqueue) do
        comment.send(:notify_slack_news_comment_deleted)
      end
    end

    assert_equal 'News comment', captured[0][1][:noun]
    assert_equal 'deleted', captured[0][1][:action]
    refute captured[0][1].key?(:notes)
    assert_equal ['Removed comment', ''], captured[0][1][:body_diff]
    assert_equal :comment, captured[0][1][:body_diff_label]
    assert_equal 'news_comment_deleted', captured[1][2][:event]
  end
end

class DeletionNotificationTest < Minitest::Test
  def project
    OpenStruct.new(id: 7, identifier: 'agentic', name: 'Agentic')
  end

  def test_deleted_records_have_independent_events_and_project_links
    cases = [
      [RedmineSlackNotification::NewsPatch, 'news_deleted', { title: 'News', id: 1, description: 'Body' }, 'News', '/news'],
      [RedmineSlackNotification::TimeEntryPatch, 'time_entry_deleted', { id: 2, hours: 1, spent_on: '2026-09-28', comments: '' }, 'Time entry', '/time_entries'],
      [RedmineSlackNotification::VersionPatch, 'version_deleted', { id: 3, name: 'v1', status: 'open', effective_date: nil, description: '' }, 'Version', '/versions']
    ]
    cases.each do |patch, event, attributes, noun, path|
      record = OpenStruct.new(attributes.merge(project: project))
      record.extend(patch)
      assert_deleted_event(record, :notify_slack_generic, [noun, 'deleted'], event, path)
    end
    page = OpenStruct.new(project: project, title: 'Home')
    page.extend(RedmineSlackNotification::WikiPagePatch)
    assert_deleted_event(page, :notify_slack_wiki_deleted, [], 'wiki_deleted', '/wiki')
  end

  private

  def assert_deleted_event(record, method, args, event, path)
    captured = []
    payload = ->(**kwargs) { captured << [:payload, kwargs]; :message }
    enqueue = ->(message, **kwargs) { captured << [:enqueue, message, kwargs] }
    RedmineSlackNotification::Formatter.stub(:generic_payload, payload) do
      RedmineSlackNotification.stub(:enqueue, enqueue) do
        record.send(method, *args)
      end
    end
    assert_equal 'deleted', captured[0][1][:action]
    assert_includes captured[0][1][:url], path
    assert_equal event, captured[1][2][:event]
    assert_equal :message, captured[1][1]
  end
end

module Setting
  def self.protocol
    'https'
  end

  def self.host_name
    'redmine.example.com'
  end
end

class ImageNotificationTest < Minitest::Test
  def payload
    { 'attachments' => [{ 'fallback' => 'Redmine notification', 'blocks' => [{ 'type' => 'section', 'text' => { 'type' => 'mrkdwn', 'text' => '*追加コメント*\n> ![](clipboard-202609281254-s6trp@2x.png)' } }] }] }
  end

  def journal(private_note: false, attachments: [])
    OpenStruct.new(journalized: Issue.new(7097), private_notes?: private_note, attachments: attachments)
  end

  def test_extracts_local_image_reference
    assert_equal ['clipboard-202609281254-s6trp@2x.png'],
                 RedmineSlackNotification::Formatter.image_references('![](clipboard-202609281254-s6trp@2x.png)')
    assert_empty RedmineSlackNotification::Formatter.image_references('![](https://example.com/image.png)')
    assert_equal '![English](english.png)', RedmineSlackNotification::Formatter.mrkdwn('![English](english.png)')
  end

  def test_four_argument_job_keeps_non_image_notifications_compatible_with_old_workers
    project = OpenStruct.new(id: 6)
    queued = nil
    RedmineSlackNotification.stub(:event_enabled?, true) do
      RedmineSlackNotificationJob.stub(:perform_later, ->(*args) { queued = args }) do
        RedmineSlackNotification.enqueue({ 'text' => 'Issue deleted' }, project: project, event: 'issue_deleted')
      end
    end

    assert_equal [{ 'text' => 'Issue deleted' }, 6, [], nil], queued
  end

  def test_job_accepts_four_argument_issue_images_and_existing_five_argument_jobs
    project = OpenStruct.new(id: 6)
    calls = []
    Project.stub(:find_by, project) do
      RedmineSlackNotification.stub(:notify, ->(payload, **options) { calls << [payload, options] }) do
        RedmineSlackNotificationJob.new.perform({ 'text' => 'created' }, 6, ['image.png'], -7105)
        RedmineSlackNotificationJob.new.perform({ 'text' => 'created' }, 6, ['image.png'], nil, 7105)
        RedmineSlackNotificationJob.new.perform({ 'text' => 'comment' }, 6, ['image.png'], 99)
      end
    end

    assert_equal 3, calls.length
    calls.first(2).each do |_payload, options|
      assert_equal 7105, options[:issue_id]
      assert_nil options[:journal_id]
    end
    assert_equal 99, calls.last[1][:journal_id]
    assert_nil calls.last[1][:issue_id]
  end

  def test_new_issue_embeds_its_attached_image_in_the_colored_notification
    name = 'F0C57KUNXCH-__________2026-09-29_12.01.19.png'
    issue = Issue.new(7105)
    issue.project = OpenStruct.new(id: 7)
    issue.define_singleton_method(:description) { "Report\n\n![Attached image](#{name})" }
    issue.define_singleton_method(:author) { OpenStruct.new(name: 'LUMEN') }
    issue.define_singleton_method(:attachments) { [OpenStruct.new(id: 88, filename: name)] }
    payload = RedmineSlackNotification::Formatter.payload('Issue created', blocks: [
      RedmineSlackNotification::Formatter.mrkdwn_sections('Content', issue.description).first
    ])
    queued = nil
    posted = nil

    RedmineSlackNotification::Formatter.stub(:issue_payload, payload) do
      RedmineSlackNotification.stub(:event_enabled?, true) do
        RedmineSlackNotificationJob.stub(:perform_later, ->(*args) { queued = args }) do
          issue.extend(RedmineSlackNotification::IssuePatch)
          issue.send(:notify_slack_issue_created)
        end
      end
    end

    assert_equal [name], queued[2]
    assert_equal 4, queued.length
    assert_equal(-7105, queued[3])

    Issue.stub(:find_by, issue) do
      RedmineSlackNotification.stub(:bot_token, 'token') do
        RedmineSlackNotification.stub(:channel_id, 'C123') do
          RedmineSlackNotification.stub(:upload_image, 'F123') do
            RedmineSlackNotification.stub(:post_message, ->(message, _channel, _token) { posted = message }) do
              RedmineSlackNotification.notify(queued[0], project: issue.project, image_names: queued[2],
                                              issue_id: -queued[3])
            end
          end
        end
      end
    end

    assert_equal '#6D5DFB', posted.dig('attachments', 0, 'color')
    blocks = posted.dig('attachments', 0, 'blocks')
    assert_equal ['section', 'image'], blocks.map { |block| block['type'] }
    assert_equal 'F123', blocks.last.dig('slack_file', 'id')
    refute_includes blocks.first.dig('text', 'text'), name
  end

  def test_ordered_lists_use_markdown_inside_the_colored_attachment
    notes = "1. first\n1. second\n1. third\n\n![](screenshot.png)\n\nDone"
    blocks = RedmineSlackNotification::Formatter.mrkdwn_sections('追加コメント', notes)
    message = RedmineSlackNotification::Formatter.payload('Redmine notification', blocks: blocks)

    assert_equal '#6D5DFB', message.dig('attachments', 0, 'color')
    assert_equal [{ 'type' => 'markdown', 'text' => "**追加コメント**\n\n#{notes}" }], message.dig('attachments', 0, 'blocks')
    assert_nil message['blocks']
  end

  def test_change_fields_are_split_to_fit_slack_section_limit
    changes = 12.times.map { |index| ["項目#{index}", '変更'] }
    blocks = RedmineSlackNotification::Formatter.change_field_blocks(changes)
    assert_equal [10, 2], blocks.map { |block| block.fetch('fields').length }
    assert_includes blocks.last.fetch('fields').last.fetch('text'), '項目11'
  end

  def test_deleted_labels_are_distinct_from_updates
    assert_equal 'News created', RedmineSlackNotification::Formatter.event_label('News', 'created')
    assert_equal 'Time entry created', RedmineSlackNotification::Formatter.event_label('Time entry', 'created')
    assert_equal 'Version created', RedmineSlackNotification::Formatter.event_label('Version', 'created')
    assert_equal 'News comment added', RedmineSlackNotification::Formatter.event_label('News comment', 'added')
    assert_equal 'News deleted', RedmineSlackNotification::Formatter.event_label('News', 'deleted')
    assert_equal '🗑️', RedmineSlackNotification::Formatter.event_icon('deleted', noun: 'Wiki page')
  end

  def test_attachment_parent_version_and_custom_field_changes_have_readable_details
    value = ->(text) { PresenceValue.new(text) }
    details = [
      OpenStruct.new(property: 'attachment', prop_key: '1', old_value: value.call(''), value: value.call('one.png')),
      OpenStruct.new(property: 'attachment', prop_key: '2', old_value: value.call(''), value: value.call('two.png')),
      OpenStruct.new(property: 'attr', prop_key: 'parent_id', old_value: value.call(''), value: value.call('7011')),
      OpenStruct.new(property: 'attr', prop_key: 'fixed_version_id', old_value: value.call('1'), value: value.call('2')),
      OpenStruct.new(property: 'cf', prop_key: '42', old_value: value.call('A'), value: value.call('B'))
    ]
    issue = OpenStruct.new(fixed_version: OpenStruct.new(name: '新版'))
    changes = RedmineSlackNotification::Formatter.change_fields(issue, details)
    assert_equal ['Attachment', 'Attachment', 'Parent issue', 'Target version', '顧客分類'], changes.map(&:first)
    assert_equal ['Added: one.png', 'Added: two.png'], changes.first(2).map(&:last)
    assert_equal 'None → #7011', changes[2][1]
    assert_equal '旧版 → 新版', changes[3][1]
    assert_equal 'A → B', changes[4][1]
  end

  def test_long_ordered_list_keeps_the_existing_section_format
    notes = "1. first\n" + ('x' * 12_000)
    assert_equal 'section', RedmineSlackNotification::Formatter.mrkdwn_sections('追加コメント', notes).first['type']
  end

  def test_uploaded_image_stays_between_markdown_text_blocks
    name = 'screenshot.png'
    attachment = OpenStruct.new(id: 42, filename: name)
    notes = "1. first\n1. second\n\n![](#{name})\n\nDone"
    message = RedmineSlackNotification::Formatter.payload('Redmine notification', blocks: RedmineSlackNotification::Formatter.mrkdwn_sections('追加コメント', notes))
    Journal.stub(:find_by, journal(attachments: [attachment])) do
      RedmineSlackNotification.stub(:upload_image, 'F123') do
        RedmineSlackNotification.add_images(message, [name], 1, 'token')
      end
    end

    assert_equal '#6D5DFB', message.dig('attachments', 0, 'color')
    assert_equal ['markdown', 'image', 'markdown'], message.dig('attachments', 0, 'blocks').map { |block| block['type'] }
    assert_equal "**追加コメント**\n\n1. first\n1. second", message.dig('attachments', 0, 'blocks', 0, 'text')
    assert_equal 'F123', message.dig('attachments', 0, 'blocks', 1, 'slack_file', 'id')
    assert_equal 'Done', message.dig('attachments', 0, 'blocks', 2, 'text')
  end

  def test_image_reference_inside_body_diff_remains_literal
    name = 'screenshot.png'
    attachment = OpenStruct.new(id: 42, filename: name)
    diff = RedmineSlackNotification::Formatter.body_diff_blocks('説明', '', "![](#{name})").first
    comment_diff = RedmineSlackNotification::Formatter.body_diff_blocks('コメント', '', "![](#{name})").first
    comment = RedmineSlackNotification::Formatter.mrkdwn_sections('追加コメント', "1. See image\n![](#{name})").first
    message = RedmineSlackNotification::Formatter.payload('Redmine notification', blocks: [diff, comment_diff, comment])

    Journal.stub(:find_by, journal(attachments: [attachment])) do
      RedmineSlackNotification.stub(:upload_image, 'F123') do
        RedmineSlackNotification.add_images(message, [name], 1, 'token')
      end
    end

    blocks = message.dig('attachments', 0, 'blocks')
    assert_includes blocks.first['text'], "![](#{name})"
    assert_includes blocks[1]['text'], "![](#{name})"
    assert_equal 1, blocks.count { |block| block['type'] == 'image' }
  end

  def test_edited_comment_embeds_image_with_full_text_or_diff
    name = 'screenshot.png'
    attachment = OpenStruct.new(id: 42, filename: name)
    issue = OpenStruct.new(id: 7098, subject: 'Title', project: OpenStruct.new(name: 'Agentic'),
                           tracker: OpenStruct.new(name: 'Task'))
    empty_changes = []
    empty_changes.define_singleton_method(:present?) { false }

    [false, true].each do |show_diff|
      message = nil
      RedmineSlackNotification.stub(:config, { 'slack' => { 'body_diff' => show_diff } }) do
        RedmineSlackNotification::Formatter.stub(:change_fields, empty_changes) do
          message = RedmineSlackNotification::Formatter.journal_payload(
            issue, actor: OpenStruct.new(name: 'Editor'),
            notes: "![](#{name})\ntest", previous_notes: "![](#{name})",
            comment_action: 'updated'
          )
        end
      end
      Journal.stub(:find_by, journal(attachments: [attachment])) do
        RedmineSlackNotification.stub(:upload_image, 'F123') do
          RedmineSlackNotification.add_images(message, [name], 1, 'token')
        end
      end

      blocks = message.dig('attachments', 0, 'blocks')
      assert_equal '#6D5DFB', message.dig('attachments', 0, 'color')
      assert_equal 1, blocks.count { |block| block['type'] == 'image' }
      assert_equal 'F123', blocks.find { |block| block['type'] == 'image' }.dig('slack_file', 'id')
      if show_diff
        assert_includes blocks.find { |block| block['type'] == 'markdown' }['text'], "![](#{name})"
      else
        refute blocks.any? { |block| block['type'] == 'markdown' }
      end
    end
  end

  def test_failed_markdown_image_upload_keeps_a_redmine_link
    attachment = OpenStruct.new(id: 42, filename: 'screenshot.png')
    notes = "1. first\n\n![](screenshot.png)"
    message = RedmineSlackNotification::Formatter.payload('Redmine notification', blocks: RedmineSlackNotification::Formatter.mrkdwn_sections('追加コメント', notes))
    Journal.stub(:find_by, journal(attachments: [attachment])) do
      RedmineSlackNotification.stub(:upload_image, nil) do
        RedmineSlackNotification.add_images(message, [attachment.filename], 1, 'token')
      end
    end

    assert_includes message.dig('attachments', 0, 'blocks', 0, 'text'), '[Image: screenshot.png](https://redmine.example.com/attachments/42)'
  end

  def test_embeds_uploaded_image_and_links_to_redmine
    attachment = OpenStruct.new(id: 42, filename: 'clipboard-202609281254-s6trp@2x.png')
    message = payload
    Journal.stub(:find_by, journal(attachments: [attachment])) do
      RedmineSlackNotification.stub(:upload_image, 'F123') do
        RedmineSlackNotification.add_images(message, [attachment.filename], 1, 'token')
      end
    end

    assert_equal 'Redmine notification', message.dig('attachments', 0, 'fallback')
    blocks = message.dig('attachments', 0, 'blocks')
    assert_equal 2, blocks.length
    refute_includes blocks.first.dig('text', 'text'), 'Image:'
    refute_includes blocks.first.dig('text', 'text'), 'clipboard-202609281254-s6trp@2x.png'
    assert_equal({ 'id' => 'F123' }, blocks.last['slack_file'])
  end

  def test_failed_upload_keeps_attachment_link
    attachment = OpenStruct.new(id: 42, filename: 'clipboard-202609281254-s6trp@2x.png')
    message = payload
    Journal.stub(:find_by, journal(attachments: [attachment])) do
      RedmineSlackNotification.stub(:upload_image, nil) do
        RedmineSlackNotification.add_images(message, [attachment.filename], 1, 'token')
      end
    end

    assert_equal 1, message.dig('attachments', 0, 'blocks').length
    assert_includes message.dig('attachments', 0, 'blocks', 0, 'text', 'text'), 'https://redmine.example.com/attachments/42'
  end

  def test_multiple_images_follow_their_markdown_positions
    names = %w[english.png japanese.png chinese.png]
    attachments = names.each_with_index.map { |name, index| OpenStruct.new(id: index + 1, filename: name) }
    message = {
      'attachments' => [{ 'fallback' => 'Redmine notification', 'blocks' => [
        { 'type' => 'section', 'text' => { 'type' => 'mrkdwn', 'text' => "*追加コメント*\nEN\n![English](english.png)\n\nJA\n![](japanese.png)\n\nZH\n![](chinese.png)" } },
        { 'type' => 'divider' }
      ] }]
    }
    file_ids = { 'english.png' => 'FEN', 'japanese.png' => 'FJA', 'chinese.png' => 'FZH' }
    Journal.stub(:find_by, journal(attachments: attachments)) do
      RedmineSlackNotification.stub(:upload_image, ->(attachment, _token) { file_ids.fetch(attachment.filename) }) do
        RedmineSlackNotification.add_images(message, names, 1, 'token')
      end
    end

    assert_equal [
      ['section', "*追加コメント*\nEN"],
      ['image', 'FEN'],
      ['section', 'JA'],
      ['image', 'FJA'],
      ['section', 'ZH'],
      ['image', 'FZH'],
      ['divider', nil]
    ], message.dig('attachments', 0, 'blocks').map { |block| [block['type'], block['type'] == 'image' ? block.dig('slack_file', 'id') : block.dig('text', 'text')] }
  end

  def test_missing_attachment_links_to_issue_without_upload
    message = payload
    Journal.stub(:find_by, journal) do
      RedmineSlackNotification.stub(:upload_image, ->(*) { flunk 'missing image was uploaded' }) do
        RedmineSlackNotification.add_images(message, ['clipboard-202609281254-s6trp@2x.png'], 1, 'token')
      end
    end

    assert_includes message.dig('attachments', 0, 'blocks', 0, 'text', 'text'), 'https://redmine.example.com/issues/7097'
  end

  def test_private_note_is_not_uploaded
    message = payload
    Journal.stub(:find_by, journal(private_note: true)) do
      RedmineSlackNotification.stub(:upload_image, ->(*) { flunk 'private image was uploaded' }) do
        RedmineSlackNotification.add_images(message, ['clipboard-202609281254-s6trp@2x.png'], 1, 'token')
      end
    end

    assert_equal payload, message
  end

  def test_upload_api_sends_filename_and_length_as_form_data
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, '{"ok":true}')
    captured_request = nil
    http = Object.new
    http.define_singleton_method(:request) do |request|
      captured_request = request
      response
    end

    Net::HTTP.stub(:start, ->(*, &block) { block.call(http) }) do
      RedmineSlackNotification.slack_api(
        'files.getUploadURLExternal',
        { 'filename' => 'clipboard.png', 'length' => 42 },
        'token',
        form: true
      )
    end

    assert_equal 'application/x-www-form-urlencoded', captured_request.content_type
    assert_equal({ 'filename' => 'clipboard.png', 'length' => '42' }, URI.decode_www_form(captured_request.body).to_h)
  end

  def test_retries_image_processing_without_changing_file_id
    message = { 'blocks' => [{ 'type' => 'image', 'slack_file' => { 'id' => 'F123' }, 'alt_text' => 'image' }] }
    attempts = []
    delays = []
    error = RedmineSlackNotification::SlackApiError.new(
      'chat.postMessage', '200',
      { 'error' => 'invalid_blocks', 'response_metadata' => { 'messages' => ['[ERROR] invalid file type'] } }
    )
    api = lambda do |_method, body, _token|
      attempts << body.dig('blocks', 0, 'slack_file', 'id')
      raise error if attempts.length < 3

      { 'ok' => true }
    end

    RedmineSlackNotification.stub(:slack_api, api) do
      RedmineSlackNotification.stub(:sleep, ->(seconds) { delays << seconds }) do
        assert_equal({ 'ok' => true }, RedmineSlackNotification.post_message(message, 'C123', 'token'))
      end
    end

    assert_equal ['F123', 'F123', 'F123'], attempts
    assert_equal [1, 2], delays
  end

  def test_image_message_keeps_the_colored_card_after_file_sharing
    message = RedmineSlackNotification::Formatter.payload('Redmine notification', blocks: [
      { 'type' => 'markdown', 'text' => "**追加コメント**\n\n1. first" },
      { 'type' => 'image', 'slack_file' => { 'id' => 'F123' }, 'alt_text' => 'screenshot' },
      { 'type' => 'markdown', 'text' => 'after image' }
    ])
    calls = []
    api = lambda do |method, body, _token|
      calls << [method, body]
      method == 'chat.postMessage' ? { 'ok' => true, 'ts' => '123.456' } : { 'ok' => true }
    end

    RedmineSlackNotification.stub(:slack_api, api) do
      assert_equal({ 'ok' => true, 'ts' => '123.456' }, RedmineSlackNotification.post_message(message, 'C123', 'token'))
    end

    assert_equal %w[chat.postMessage chat.update], calls.map(&:first)
    initial = calls[0][1]
    final = calls[1][1]
    assert_equal '#6D5DFB', initial.dig('attachments', 0, 'color')
    assert_equal 'F123', initial.dig('blocks', 0, 'accessory', 'slack_file', 'id')
    assert_equal %w[markdown image markdown], initial.dig('attachments', 0, 'blocks').map { |block| block['type'] }
    assert_equal '123.456', final['ts']
    assert_equal '', final['text']
    assert_equal [], final['blocks']
    assert_equal initial['attachments'], final['attachments']
    assert_nil message['blocks']
  end

  def test_retries_attachment_until_new_image_is_ready
    message = RedmineSlackNotification::Formatter.payload('Redmine notification', blocks: [
      { 'type' => 'image', 'slack_file' => { 'id' => 'F123' }, 'alt_text' => 'screenshot' }
    ])
    methods = []
    error = RedmineSlackNotification::SlackApiError.new(
      'chat.postMessage', '200',
      { 'error' => 'invalid_attachments', 'response_metadata' => { 'messages' => ['[ERROR] invalid slack file'] } }
    )
    api = lambda do |method, _body, _token|
      methods << method
      raise error if methods.length == 1

      method == 'chat.postMessage' ? { 'ok' => true, 'ts' => '123.456' } : { 'ok' => true }
    end

    RedmineSlackNotification.stub(:slack_api, api) do
      RedmineSlackNotification.stub(:sleep, ->(*) {}) do
        RedmineSlackNotification.post_message(message, 'C123', 'token')
      end
    end

    assert_equal %w[chat.postMessage chat.postMessage chat.update], methods
  end
end

class NotificationDisplaySettingsTest < Minitest::Test
  def test_optional_issue_metadata_includes_selected_version_relation_and_custom_field
    project = OpenStruct.new(name: 'Agentic')
    related = OpenStruct.new(id: 12, subject: 'Related & visible')
    private_issue = OpenStruct.new(id: 13, subject: 'Private')
    private_issue.define_singleton_method(:is_private?) { true }
    relation = OpenStruct.new
    relation.define_singleton_method(:other_issue) { |_issue| related }
    relation.define_singleton_method(:relation_type_for) { |_issue| 'relates' }
    values = [
      OpenStruct.new(custom_field: OpenStruct.new(id: 42, name: 'Customer'), value: 'Acme'),
      OpenStruct.new(custom_field: OpenStruct.new(id: 43, name: 'Internal'), value: 'Hidden')
    ]
    issue = OpenStruct.new(id: 7, subject: 'Subject', description: '', project: project,
                           tracker: OpenStruct.new(name: 'Task'),
                           fixed_version: OpenStruct.new(name: 'Release 2'),
                           relations: [relation], children: [private_issue])
    issue.define_singleton_method(:visible_custom_field_values) { values }
    no_changes = []
    no_changes.define_singleton_method(:present?) { false }
    settings = { 'slack' => { 'metadata' => { 'issue' => {
      'target_version' => true, 'relations' => true, 'children' => true,
      'custom_fields' => { 'default' => false, '42' => true }
    } } } }

    RedmineSlackNotification.stub(:config, settings) do
      RedmineSlackNotification::Formatter.stub(:change_fields, no_changes) do
        blocks = RedmineSlackNotification::Formatter.issue_payload(issue, actor: OpenStruct.new(name: 'Kota'), action: 'created')
                                            .dig('attachments', 0, 'blocks')
        fields = blocks.flat_map { |block| block.fetch('fields', []) }.map { |entry| entry.fetch('text') }
        assert fields.any? { |value| value == "*Target version*\nRelease 2" }
        assert fields.any? { |value| value.include?('Related &amp; visible') }
        assert fields.any? { |value| value == "*Customer*\nAcme" }
        refute fields.any? { |value| value.include?('Internal') || value.include?('Private') }
      end
    end
  end

  def test_additional_issue_metadata_is_opt_in_by_default
    issue = OpenStruct.new(id: 7, subject: 'Subject', description: '',
                           project: OpenStruct.new(name: 'Agentic'), tracker: OpenStruct.new(name: 'Task'),
                           fixed_version: OpenStruct.new(name: 'Release 2'))
    no_changes = []
    no_changes.define_singleton_method(:present?) { false }

    RedmineSlackNotification.stub(:config, {}) do
      RedmineSlackNotification::Formatter.stub(:change_fields, no_changes) do
        fields = RedmineSlackNotification::Formatter.issue_payload(
          issue, actor: OpenStruct.new(name: 'Kota'), action: 'created'
        ).dig('attachments', 0, 'blocks').flat_map { |block| block.fetch('fields', []) }
        assert_equal 5, fields.length
        refute fields.any? { |entry| entry.fetch('text').include?('Release 2') }
      end
    end
  end

  def test_updated_issue_metadata_shows_enabled_unset_and_custom_fields
    issue = OpenStruct.new(id: 7, subject: 'Subject', description: '', status: nil, fixed_version: nil,
                           project: OpenStruct.new(name: 'Agentic'), tracker: OpenStruct.new(name: 'Task'))
    issue.define_singleton_method(:visible_custom_field_values) do
      [OpenStruct.new(custom_field: OpenStruct.new(id: 42, name: 'Customer'), value: '')]
    end
    settings = { 'slack' => { 'metadata' => { 'issue' => {
      'project' => false, 'updater' => false, 'tracker' => false, 'category' => false, 'priority' => false,
      'status' => true, 'target_version' => true,
      'custom_fields' => { 'default' => false, '42' => true }
    } } } }

    RedmineSlackNotification.stub(:config, settings) do
      %w[created updated].each do |action|
        fields = RedmineSlackNotification::Formatter.issue_payload(
          issue, actor: nil, action: action
        ).dig('attachments', 0, 'blocks').flat_map { |block| block.fetch('fields', []) }
        assert_equal ["*Status*\nNot set", "*Target version*\nNot set", "*Customer*\nNot set"],
                     fields.map { |entry| entry['text'] }, action
      end
    end
  end

  def test_updated_issue_metadata_shows_current_values_independent_of_changed_fields
    value = ->(string) { PresenceValue.new(string) }
    details = [
      OpenStruct.new(property: 'attr', prop_key: 'fixed_version_id', old_value: value.call('1'), value: value.call('2')),
      OpenStruct.new(property: 'attr', prop_key: 'description', old_value: value.call('before'), value: value.call('after'))
    ]
    issue = OpenStruct.new(id: 7, subject: 'Subject', description: 'after',
                           project: OpenStruct.new(name: 'Agentic'), tracker: OpenStruct.new(name: 'Task'),
                           status: OpenStruct.new(name: 'In progress'),
                           fixed_version: OpenStruct.new(name: 'Release 2'))
    settings = { 'slack' => { 'metadata' => { 'issue' => {
      'project' => false, 'status' => true, 'target_version' => true
    } } } }

    RedmineSlackNotification.stub(:config, settings) do
      heading = ->(block) { block['text']['text'] if block['text'].is_a?(Hash) }
      payload = RedmineSlackNotification::Formatter.issue_payload(
        issue, actor: OpenStruct.new(name: 'Kota'), action: 'updated', details: details
      )
      blocks = payload.dig('attachments', 0, 'blocks')
      fields = blocks.flat_map { |block| block.fetch('fields', []) }.map { |entry| entry.fetch('text') }
      assert fields.any? { |field| field == "*Status*\nIn progress" }
      assert fields.any? { |field| field == "*Target version*\nRelease 2" }
      assert fields.any? { |field| field.include?('旧版 → Release 2') || field.include?('旧版 → 新版') }
      refute fields.any? { |field| field.start_with?('*Project*') }
      assert blocks.any? { |block| heading.call(block) == '*Metadata*' }
      assert blocks.any? { |block| heading.call(block) == '*Changes*' }

      combined = RedmineSlackNotification::Formatter.journal_payload(
        issue, actor: OpenStruct.new(name: 'Kota'), notes: 'Comment', details: details
      ).dig('attachments', 0, 'blocks')
      assert combined.any? { |block| heading.call(block) == '*Metadata*' }
      assert combined.any? { |block| heading.call(block) == '*Changes*' }
    end
  end

  def test_legacy_issue_metadata_action_maps_remain_readable
    settings = { 'slack' => { 'metadata' => { 'issue' => {
      'created' => { 'project' => true, 'status' => false },
      'updated' => { 'project' => false, 'status' => true }
    } } } }
    RedmineSlackNotification.stub(:config, settings) do
      assert RedmineSlackNotification::Formatter.metadata_enabled?('issue', 'project', action: 'created')
      refute RedmineSlackNotification::Formatter.metadata_enabled?('issue', 'project', action: 'updated')
      assert RedmineSlackNotification::Formatter.metadata_enabled?('issue', 'status', action: 'updated')
    end
  end

  def test_hidden_issue_changes_switch_keeps_visible_changes_and_description_diff
    value = ->(string) { PresenceValue.new(string) }
    details = [
      OpenStruct.new(property: 'attr', prop_key: 'description', old_value: value.call('before'), value: value.call('after')),
      OpenStruct.new(property: 'attr', prop_key: 'fixed_version_id', old_value: value.call('1'), value: value.call('2')),
      OpenStruct.new(property: 'attr', prop_key: 'status_id', old_value: value.call('1'), value: value.call('2'))
    ]
    issue = OpenStruct.new(id: 7, subject: 'Subject', description: 'after',
                           project: OpenStruct.new(name: 'Agentic'), tracker: OpenStruct.new(name: 'Task'),
                           fixed_version: OpenStruct.new(name: 'Release 2'), status: OpenStruct.new(name: 'Closed'))
    settings = { 'slack' => { 'issue_changes_when_hidden' => false,
                              'metadata' => { 'issue' => { 'target_version' => true, 'status' => false } } } }

    RedmineSlackNotification.stub(:config, settings) do
      heading = ->(block) { block['text']['text'] if block['text'].is_a?(Hash) }
      [RedmineSlackNotification::Formatter.issue_payload(issue, actor: nil, action: 'updated', details: details),
       RedmineSlackNotification::Formatter.journal_payload(issue, actor: nil, notes: 'Comment', details: details)].each do |payload|
        blocks = payload.dig('attachments', 0, 'blocks')
        assert blocks.flat_map { |block| block.fetch('fields', []) }
                     .any? { |field| field['text'] == "*Target version*\nRelease 2" }
        assert blocks.any? { |block| heading.call(block) == '*Changes*' }
        assert blocks.any? { |block| block['type'] == 'markdown' && block['text'].include?('diff') }
        change_fields = blocks.flat_map { |block| block.fetch('fields', []) }.map { |field| field['text'] }
        assert change_fields.any? { |field| field.start_with?('*Target version*') && field.include?('→') }
        refute change_fields.any? { |field| field.start_with?('*Status*') }
      end
      combined_blocks = RedmineSlackNotification::Formatter.journal_payload(
        issue, actor: nil, notes: 'Comment', details: details
      ).dig('attachments', 0, 'blocks')
      assert combined_blocks.any? { |block| heading.call(block).to_s.include?('Comment') }
    end
  end

  def test_metadata_fields_can_be_hidden_independently_for_every_notification_type
    settings = { 'slack' => { 'metadata' => {
      'issue' => { 'project' => false }, 'wiki' => { 'location' => false },
      'news' => { 'updater' => false }, 'news_comment' => { 'project' => false },
      'time_entry' => { 'hours' => false }, 'version' => { 'due_date' => false },
      'project' => { 'updater' => false }
    } } }
    project = OpenStruct.new(name: 'Agentic', identifier: 'agentic')
    actor = OpenStruct.new(name: 'Kota')
    issue = OpenStruct.new(id: 7, subject: 'Subject', description: '', project: project,
                           tracker: OpenStruct.new(name: 'Task'))
    no_changes = []
    no_changes.define_singleton_method(:present?) { false }
    metadata = lambda do |payload|
      payload.dig('attachments', 0, 'blocks').flat_map { |block| block.fetch('fields', []) }
             .map { |entry| entry.fetch('text') }
    end

    RedmineSlackNotification.stub(:config, settings) do
      RedmineSlackNotification::Formatter.stub(:change_fields, no_changes) do
        fields = metadata.call(RedmineSlackNotification::Formatter.issue_payload(issue, actor: actor, action: 'created'))
        refute fields.any? { |value| value.start_with?('*Project*') }
        assert fields.any? { |value| value.start_with?('*Tracker*') }
      end

      wiki = OpenStruct.new(page: OpenStruct.new(title: 'Home'), comments: '')
      fields = metadata.call(RedmineSlackNotification::Formatter.wiki_payload(wiki, project, actor: actor, action: 'updated'))
      refute fields.any? { |value| value.start_with?('*Changed location*') }
      assert fields.any? { |value| value.start_with?('*Project*') }

      cases = {
        'News' => { hidden: '*Updated by*', visible: '*Project*' },
        'News comment' => { hidden: '*Project*', visible: '*Updated by*' },
        'Time entry' => { hidden: '*Hours*', visible: '*Spent on*', fields: [['hours', '2h'], ['spent_on', '2026-09-29']] },
        'Version' => { hidden: '*Due date*', visible: '*Status*', fields: [['status', 'open'], ['due_date', '2026-10-01']] },
        'Project' => { hidden: '*Updated by*', visible: '*Project*' }
      }
      cases.each do |noun, checks|
        fields = metadata.call(RedmineSlackNotification::Formatter.generic_payload(
          noun: noun, action: 'updated', subject: noun, url: 'https://example.com',
          project: project, actor: actor, fields: checks.fetch(:fields, [])
        ))
        refute fields.any? { |value| value.start_with?(checks[:hidden]) }, noun
        assert fields.any? { |value| value.start_with?(checks[:visible]) }, noun
      end
    end
  end

  def test_metadata_section_disappears_when_its_group_or_all_fields_are_disabled
    project = OpenStruct.new(name: 'Agentic')
    actor = OpenStruct.new(name: 'Kota')
    settings = { 'slack' => { 'metadata' => {
      'news' => false, 'project' => { 'project' => false, 'updater' => false }
    } } }

    RedmineSlackNotification.stub(:config, settings) do
      %w[News Project].each do |noun|
        blocks = RedmineSlackNotification::Formatter.generic_payload(
          noun: noun, action: 'updated', subject: noun, url: 'https://example.com',
          project: project, actor: actor
        ).dig('attachments', 0, 'blocks')
        refute blocks.any? { |block| block.dig('text', 'text') == '*Metadata*' }, noun
        refute blocks.any? { |block| block['type'] == 'divider' }, noun
      end
    end
  end

  def test_issue_update_heading_shows_actor_in_both_notification_paths
    project = OpenStruct.new(name: 'Agentic')
    issue = OpenStruct.new(id: 7, subject: 'Subject', description: '', project: project,
                           tracker: OpenStruct.new(name: 'Task'))
    actor = OpenStruct.new(name: 'Kota')
    empty_changes = []
    empty_changes.define_singleton_method(:present?) { false }

    RedmineSlackNotification::Formatter.stub(:change_fields, empty_changes) do
      updated = RedmineSlackNotification::Formatter.issue_payload(issue, actor: actor, action: 'updated')
      created = RedmineSlackNotification::Formatter.issue_payload(issue, actor: actor, action: 'created')
      combined = RedmineSlackNotification::Formatter.journal_payload(
        issue, actor: actor, notes: '', details: [OpenStruct.new(property: 'attr', prop_key: 'status_id')]
      )
      assert_equal '🔄 Kota *Issue updated*', updated.dig('attachments', 0, 'blocks', 0, 'text', 'text')
      assert_equal '🔄 Kota *Issue updated*', combined.dig('attachments', 0, 'blocks', 0, 'text', 'text')
      assert_equal '🆕 *Issue created*', created.dig('attachments', 0, 'blocks', 0, 'text', 'text')
    end

    RedmineSlackNotification.stub(:config, { 'messages' => { 'templates' => {
      'issue_updated_header' => '*%{event}* by %{actor}'
    } } }) do
      RedmineSlackNotification::Formatter.stub(:change_fields, empty_changes) do
        customized = RedmineSlackNotification::Formatter.issue_payload(issue, actor: actor, action: 'updated')
        assert_equal '🔄 *Issue updated* by Kota', customized.dig('attachments', 0, 'blocks', 0, 'text', 'text')
      end
    end
  end

  def test_issue_metadata_is_shown_on_creation_and_updates_but_not_comments
    project = OpenStruct.new(name: 'Agentic')
    issue = OpenStruct.new(id: 7, subject: 'Subject', description: '', project: project,
                           tracker: OpenStruct.new(name: 'Task'))
    actor = OpenStruct.new(name: 'Kota')
    changes = [[RedmineSlackNotification::Formatter.field_label('status'), 'Open → Closed']]
    changes.define_singleton_method(:present?) { true }
    no_changes = []
    no_changes.define_singleton_method(:present?) { false }

    RedmineSlackNotification::Formatter.stub(:change_fields, no_changes) do
      created = RedmineSlackNotification::Formatter.issue_payload(issue, actor: actor, action: 'created')
      removed = RedmineSlackNotification::Formatter.issue_payload(issue, actor: actor, action: 'deleted')
      comment_only = RedmineSlackNotification::Formatter.journal_payload(issue, actor: actor, notes: 'Comment')
      assert created.dig('attachments', 0, 'blocks').any? { |block| block.dig('text', 'text') == '*Metadata*' }
      [removed, comment_only].each do |message|
        refute message.dig('attachments', 0, 'blocks').any? { |block| block.dig('text', 'text') == '*Metadata*' }
      end
    end

    RedmineSlackNotification::Formatter.stub(:change_fields, changes) do
      updated = RedmineSlackNotification::Formatter.issue_payload(issue, actor: actor, action: 'updated')
      commented = RedmineSlackNotification::Formatter.journal_payload(
        issue, actor: actor, notes: 'Comment', details: [OpenStruct.new(property: 'attr', prop_key: 'status_id')]
      )
      [updated, commented].each do |message|
        blocks = message.dig('attachments', 0, 'blocks')
        assert blocks.any? { |block| block.dig('text', 'text') == '*Metadata*' }
        assert blocks.any? { |block| block.dig('text', 'text') == '*Changes*' }
      end
    end
  end

  def test_color_and_message_overrides_apply_to_the_colored_card
    settings = {
      'slack' => { 'attachment_color' => '#12Ab34' },
      'messages' => {
        'events' => { 'news' => { 'updated' => 'News changed' } },
        'icons' => { 'news' => { 'updated' => '🔔' } },
        'sections' => { 'summary' => 'Summary', 'metadata' => 'Details' },
        'fields' => { 'project' => 'Workspace', 'updater' => 'Changed by' },
        'templates' => { 'generic_fallback' => '%{event}: %{subject}' }
      }
    }
    project = OpenStruct.new(name: 'Agentic')
    RedmineSlackNotification.stub(:config, settings) do
      payload = RedmineSlackNotification::Formatter.generic_payload(
        noun: 'News', action: 'updated', subject: 'Headline', url: 'https://example.com/news/1',
        project: project, actor: OpenStruct.new(name: 'Kota'), summary: 'Changed text'
      )
      card = payload.fetch('attachments').first
      assert_equal '#12Ab34', card['color']
      assert_equal 'News changed: Headline', card['fallback']
      assert_includes card.dig('blocks', 0, 'text', 'text'), '🔔 *News changed*'
      assert card['blocks'].any? { |block| block.dig('text', 'text').to_s.include?('*Summary*') }
      assert card['blocks'].any? { |block| block.dig('text', 'text').to_s == '*Details*' }
      fields = card['blocks'].flat_map { |block| block.fetch('fields', []) }.map { |field| field['text'] }
      assert fields.any? { |field| field.include?('*Workspace*') }
      assert fields.any? { |field| field.include?('*Changed by*') }
    end
  end

  def test_invalid_color_and_incomplete_templates_use_safe_defaults
    RedmineSlackNotification.stub(:config, { 'slack' => { 'attachment_color' => 'blue' },
                                          'messages' => { 'templates' => { 'generic_fallback' => '%{missing}' } } }) do
      payload = RedmineSlackNotification::Formatter.generic_payload(
        noun: 'Project', action: 'updated', subject: 'Agentic', url: 'https://example.com/projects/agentic',
        project: OpenStruct.new(name: 'Agentic'), actor: OpenStruct.new(name: 'Kota')
      )
      assert_equal '#6D5DFB', payload.dig('attachments', 0, 'color')
      assert_equal 'Project updated - Agentic', payload.dig('attachments', 0, 'fallback')
    end
  end

  def test_custom_diff_heading_still_keeps_source_image_reference_literal
    settings = { 'messages' => { 'diff' => { 'heading' => 'Changes in %{label}' },
                                 'sections' => { 'comment' => 'Note' },
                                 'images' => { 'link_label' => 'Picture: %{name}' } } }
    attachment = OpenStruct.new(id: 42, filename: 'screenshot.png')
    RedmineSlackNotification.stub(:config, settings) do
      block = RedmineSlackNotification::Formatter.body_diff_blocks('Note', '', '![](screenshot.png)').first
      payload = RedmineSlackNotification::Formatter.payload('fallback', blocks: [block])
      Journal.stub(:find_by, OpenStruct.new(journalized: Issue.new(1), private_notes?: false, attachments: [attachment])) do
        RedmineSlackNotification.stub(:upload_image, ->(*) { flunk 'diff image was uploaded' }) do
          RedmineSlackNotification.add_images(payload, ['screenshot.png'], 1, 'token')
        end
      end
      assert_includes payload.dig('attachments', 0, 'blocks', 0, 'text'), '**Changes in Note**'

      image_payload = RedmineSlackNotification::Formatter.payload('fallback', blocks: [RedmineSlackNotification::Formatter.section_text('![](screenshot.png)')])
      Journal.stub(:find_by, OpenStruct.new(journalized: Issue.new(1), private_notes?: false, attachments: [attachment])) do
        RedmineSlackNotification.stub(:upload_image, nil) do
          RedmineSlackNotification.add_images(image_payload, ['screenshot.png'], 1, 'token')
        end
      end
      assert_includes image_payload.dig('attachments', 0, 'blocks', 0, 'text', 'text'), 'Picture: screenshot.png'
    end
  end

  def test_issue_comment_wiki_and_image_preview_use_custom_wording
    settings = { 'messages' => {
      'events' => { 'issue' => { 'created' => 'Ticket opened' }, 'comment' => { 'deleted' => 'Note removed' },
                    'wiki' => { 'updated' => 'Page revised' } },
      'sections' => { 'comment' => 'Note', 'metadata' => 'Properties' },
      'diff' => { 'heading' => '%{label} changes' },
      'images' => { 'preparing' => 'Loading picture', 'alt' => 'Picture' }
    } }
    project = OpenStruct.new(name: 'Agentic', identifier: 'agentic')
    issue = OpenStruct.new(id: 7, subject: 'Subject', project: project, tracker: OpenStruct.new(name: 'Task'))
    empty_changes = []
    empty_changes.define_singleton_method(:present?) { false }
    RedmineSlackNotification.stub(:config, settings) do
      assert_equal 'Ticket opened', RedmineSlackNotification::Formatter.event_label('Issue', 'created')
      RedmineSlackNotification::Formatter.stub(:change_fields, empty_changes) do
        card = RedmineSlackNotification::Formatter.journal_payload(
          issue, actor: OpenStruct.new(name: 'Editor'), notes: '', comment_action: 'deleted', previous_notes: 'old note'
        ).dig('attachments', 0)
        assert_includes card.dig('blocks', 0, 'text', 'text'), 'Note removed'
        assert card['blocks'].any? { |block| block['type'] == 'markdown' && block['text'].include?('Note changes') }
        refute card['blocks'].any? { |block| block['type'] == 'section' && block.dig('text', 'text') == '*Properties*' }
      end
      wiki = OpenStruct.new(page: OpenStruct.new(title: 'Home'), comments: '')
      wiki_card = RedmineSlackNotification::Formatter.wiki_payload(wiki, project, actor: OpenStruct.new(name: 'Editor'), action: 'updated').dig('attachments', 0)
      assert_includes wiki_card.dig('blocks', 0, 'text', 'text'), 'Page revised'

      image_payload = RedmineSlackNotification::Formatter.payload('fallback', blocks: [
        { 'type' => 'image', 'slack_file' => { 'id' => 'F1' }, 'alt_text' => 'Screenshot' }
      ])
      calls = []
      RedmineSlackNotification.stub(:slack_api, ->(method, body, _token) { calls << [method, body]; { 'ok' => true, 'ts' => '1.2' } }) do
        RedmineSlackNotification.post_message(image_payload, 'C1', 'token')
      end
      assert_equal 'Loading picture', calls.first[1].dig('blocks', 0, 'text', 'text')
      assert_equal 'Picture', calls.first[1].dig('blocks', 0, 'accessory', 'alt_text')
    end
  end
end

class BodyDiffNotificationTest < Minitest::Test
  def project
    OpenStruct.new(id: 7, identifier: 'agentic', name: 'Agentic')
  end

  def test_yaml_body_diff_setting_defaults_to_true_and_false_disables_it
    RedmineSlackNotification.stub(:config, {}) do
      assert RedmineSlackNotification.body_diff_enabled?
    end
    RedmineSlackNotification.stub(:config, { 'slack' => { 'body_diff' => false } }) do
      refute RedmineSlackNotification.body_diff_enabled?
      refute RedmineSlackNotification.body_diff_enabled?(:issue_comment)
      refute RedmineSlackNotification.body_diff_enabled?(:news_description)
    end
  end

  def test_body_diff_settings_can_be_selected_per_content_type
    settings = { 'slack' => { 'body_diff' => {
      'issue' => { 'description' => true, 'comment' => false },
      'wiki' => { 'body' => false },
      'news' => { 'description' => false, 'comment' => true }
    } } }
    RedmineSlackNotification.stub(:config, settings) do
      assert RedmineSlackNotification.body_diff_enabled?(:issue_description)
      refute RedmineSlackNotification.body_diff_enabled?(:issue_comment)
      refute RedmineSlackNotification.body_diff_enabled?(:wiki_body)
      refute RedmineSlackNotification.body_diff_enabled?(:news_description)
      assert RedmineSlackNotification.body_diff_enabled?(:news_comment)
    end
    RedmineSlackNotification.stub(:config, { 'slack' => { 'body_diff' => { 'news' => false } } }) do
      refute RedmineSlackNotification.body_diff_enabled?(:news_description)
      refute RedmineSlackNotification.body_diff_enabled?(:news_comment)
      assert RedmineSlackNotification.body_diff_enabled?(:issue_comment)
    end
  end

  def test_mixed_issue_update_uses_separate_comment_and_description_settings
    issue = OpenStruct.new(id: 7098, subject: 'Title', project: project, tracker: OpenStruct.new(name: 'Task'))
    detail = OpenStruct.new(property: 'attr', prop_key: 'description', old_value: 'old body', value: 'new body')
    empty_changes = []
    empty_changes.define_singleton_method(:present?) { false }
    settings = { 'slack' => { 'body_diff' => { 'issue' => { 'description' => true, 'comment' => false } } } }
    RedmineSlackNotification.stub(:config, settings) do
      RedmineSlackNotification::Formatter.stub(:change_fields, empty_changes) do
        blocks = RedmineSlackNotification::Formatter.journal_payload(
          issue, actor: OpenStruct.new(name: 'Editor'), notes: 'new note ![](screenshot.png)',
          details: [detail], comment_action: 'updated', previous_notes: 'old note'
        ).dig('attachments', 0, 'blocks')
        assert blocks.any? { |block| block['type'] == 'markdown' && block['text'].include?('+ new body') }
        assert blocks.any? { |block| block['type'] == 'section' && block.dig('text', 'text').to_s.include?('new note ![](screenshot.png)') }
        assert_equal 1, blocks.count { |block| block['type'] == 'section' && block.dig('text', 'text').to_s.include?('![](screenshot.png)') }
      end
    end
  end

  def test_wiki_news_body_and_news_comment_use_their_own_settings
    settings = { 'slack' => { 'body_diff' => { 'wiki' => { 'body' => false },
                                             'news' => { 'description' => false, 'comment' => true } } } }
    RedmineSlackNotification.stub(:config, settings) do
      wiki = OpenStruct.new(page: OpenStruct.new(title: 'Home'), comments: '')
      wiki_blocks = RedmineSlackNotification::Formatter.wiki_payload(
        wiki, project, actor: OpenStruct.new(name: 'Editor'), action: 'updated', body_diff: ['old', 'new']
      ).dig('attachments', 0, 'blocks')
      assert wiki_blocks.any? { |block| block['type'] == 'section' && block.dig('text', 'text').to_s.include?("*Body*\nnew") }
      refute wiki_blocks.any? { |block| block['type'] == 'markdown' }

      common = { action: 'updated', subject: 'Headline', url: 'https://example.com/news/1',
                 project: project, actor: OpenStruct.new(name: 'Editor'), body_diff: ['old', 'new'] }
      news_blocks = RedmineSlackNotification::Formatter.generic_payload(noun: 'News', **common).dig('attachments', 0, 'blocks')
      comment_blocks = RedmineSlackNotification::Formatter.generic_payload(noun: 'News comment', **common).dig('attachments', 0, 'blocks')
      assert news_blocks.any? { |block| block['type'] == 'section' && block.dig('text', 'text').to_s.include?("*Summary*\nnew") }
      assert comment_blocks.any? { |block| block['type'] == 'markdown' && block['text'].include?('+ new') }
    end
  end

  def test_full_body_setting_shows_updated_text_for_description_wiki_and_comment
    RedmineSlackNotification.stub(:config, { 'slack' => { 'body_diff' => false } }) do
      formatter = RedmineSlackNotification::Formatter
      {
        '説明' => '概要',
        '本文' => '本文',
        'コメント' => '変更後のコメント'
      }.each do |label, heading|
        blocks = formatter.updated_body_blocks(label, 'before', 'after', full_heading: heading)
        assert_equal 'section', blocks.first['type']
        assert_includes blocks.first.dig('text', 'text'), "*#{heading}*\nafter"
        refute_includes blocks.first.dig('text', 'text'), '```diff'
      end
      assert_equal "*本文*\n(empty)", formatter.updated_body_blocks('本文', 'before', '').first.dig('text', 'text')
    end
  end

  def test_body_diff_uses_markdown_diff_fence_and_only_nearby_context
    before = (1..20).map { |number| "unchanged #{number}" }
    after = before.dup
    after[9] = '**new value**'
    block = RedmineSlackNotification::Formatter.body_diff_blocks('説明', before.join("\n"), after.join("\n")).first

    assert_equal 'markdown', block['type']
    assert_includes block['text'], '```diff'
    assert_includes block['text'], '- unchanged 10'
    assert_includes block['text'], '+ **new value**'
    refute_includes block['text'], "unchanged 1\n"
    assert_includes block['text'], '  …'
    assert_equal '#6D5DFB', RedmineSlackNotification::Formatter.payload('fallback', blocks: [block]).dig('attachments', 0, 'color')
  end

  def test_edited_issue_comment_renders_only_its_diff
    issue = OpenStruct.new(id: 7098, subject: 'Title', project: project,
                           tracker: OpenStruct.new(name: 'Task'))
    empty_changes = []
    empty_changes.define_singleton_method(:present?) { false }
    message = nil
    RedmineSlackNotification.stub(:config, {}) do
      RedmineSlackNotification::Formatter.stub(:change_fields, empty_changes) do
        message = RedmineSlackNotification::Formatter.journal_payload(
          issue, actor: OpenStruct.new(name: 'Editor'), notes: 'new text',
          comment_action: 'updated', previous_notes: 'old text'
        )
      end
    end

    blocks = message.dig('attachments', 0, 'blocks')
    diff = blocks.find { |block| block['type'] == 'markdown' }
    assert_equal '#6D5DFB', message.dig('attachments', 0, 'color')
    assert_includes diff.fetch('text'), '- old text'
    assert_includes diff.fetch('text'), '+ new text'
    refute blocks.any? { |block| block['type'] == 'section' && block.dig('text', 'text').to_s.include?('変更後のコメント') }
  end

  def test_edited_issue_comment_can_show_updated_text_instead_of_diff
    issue = OpenStruct.new(id: 7098, subject: 'Title', project: project,
                           tracker: OpenStruct.new(name: 'Task'))
    empty_changes = []
    empty_changes.define_singleton_method(:present?) { false }
    message = nil
    RedmineSlackNotification.stub(:config, { 'slack' => { 'body_diff' => false } }) do
      RedmineSlackNotification::Formatter.stub(:change_fields, empty_changes) do
        message = RedmineSlackNotification::Formatter.journal_payload(
          issue, actor: OpenStruct.new(name: 'Editor'), notes: '1. new text',
          comment_action: 'updated', previous_notes: '1. old text'
        )
      end
    end

    blocks = message.dig('attachments', 0, 'blocks')
    comment = blocks.find { |block| block['type'] == 'markdown' }
    assert_includes comment.fetch('text'), '**Updated comment**'
    assert_includes comment.fetch('text'), '1. new text'
    refute_includes comment.fetch('text'), '- 1. old text'
  end

  def test_deleted_issue_comment_always_shows_removed_lines_even_when_body_diff_is_disabled
    issue = OpenStruct.new(id: 7098, subject: 'Title', project: project,
                           tracker: OpenStruct.new(name: 'Task'))
    empty_changes = []
    empty_changes.define_singleton_method(:present?) { false }
    message = nil
    RedmineSlackNotification.stub(:config, { 'slack' => { 'body_diff' => false } }) do
      RedmineSlackNotification::Formatter.stub(:change_fields, empty_changes) do
        message = RedmineSlackNotification::Formatter.journal_payload(
          issue, actor: OpenStruct.new(name: 'Editor'), notes: '',
          comment_action: 'deleted', previous_notes: "removed text\n![](old.png)"
        )
      end
    end

    blocks = message.dig('attachments', 0, 'blocks')
    diff = blocks.find { |block| block['type'] == 'markdown' }
    assert_includes diff.fetch('text'), '- removed text'
    assert_includes diff.fetch('text'), '- ![](old.png)'
    refute blocks.any? { |block| block['type'] == 'image' }
  end

  def test_body_diff_handles_code_fences_and_slack_markdown_budget
    block = RedmineSlackNotification::Formatter.body_diff_blocks('本文', '```old', '```new').first
    assert_includes block['text'], '````diff'

    existing = [{ 'type' => 'markdown', 'text' => 'x' * 11_800 }]
    fallback = RedmineSlackNotification::Formatter.body_diff_blocks('本文', 'old', 'new', blocks: existing).first
    assert_equal 'section', fallback['type']
    assert_operator fallback.dig('text', 'text').length, :<, 3_000
  end

  def test_body_diff_handles_empty_and_normalized_line_endings
    formatter = RedmineSlackNotification::Formatter
    assert_empty formatter.body_diff_blocks('本文', "same\r\nline", "same\nline")
    removed = formatter.body_diff_blocks('本文', "old\ntext", '').first['text']
    assert_includes removed, '- old'
    assert_includes removed, '- text'
    refute_includes removed, '+ old'
  end

  def test_body_diff_truncates_large_changes_without_exceeding_limit
    before = (1..600).map { |number| "old #{number}" }.join("\n")
    after = (1..600).map { |number| "new #{number}" }.join("\n")
    block = RedmineSlackNotification::Formatter.body_diff_blocks('本文', before, after).first
    assert_operator block['text'].length, :<, 6_000
    assert_includes block['text'], 'Diff truncated.'
  end

  def test_news_description_change_passes_old_and_new_body
    news = News.new(id: 17, title: 'Release', description: 'new body', project: project)
    news.define_singleton_method(:saved_change_to_description?) { true }
    news.define_singleton_method(:description_before_last_save) { 'old body' }
    news.extend(RedmineSlackNotification::NewsPatch)
    captured = nil
    formatter = ->(**kwargs) { captured = kwargs; :message }
    RedmineSlackNotification::Formatter.stub(:generic_payload, formatter) do
      RedmineSlackNotification.stub(:enqueue, ->(*) {}) do
        news.send(:notify_slack_generic, 'News', 'updated')
      end
    end
    assert_equal ['old body', 'new body'], captured[:body_diff]
  end

  def test_wiki_text_change_passes_old_and_new_body
    content = OpenStruct.new(page: OpenStruct.new(title: 'Home', wiki: OpenStruct.new(project: project)),
                             text: 'new body', comments: '')
    content.define_singleton_method(:saved_change_to_text?) { true }
    content.define_singleton_method(:text_before_last_save) { 'old body' }
    content.extend(RedmineSlackNotification::WikiContentPatch)
    captured = nil
    formatter = ->(*_args, **kwargs) { captured = kwargs; :message }
    RedmineSlackNotification::Formatter.stub(:wiki_payload, formatter) do
      RedmineSlackNotification.stub(:enqueue, ->(*) {}) do
        content.send(:notify_slack_wiki_updated)
      end
    end
    assert_equal ['old body', 'new body'], captured[:body_diff]
  end
end

require_relative '../app/jobs/redmine_slack_due_digest_job'
require_relative '../app/jobs/redmine_slack_due_reminder_job'

class DueReminderTest < Minitest::Test
  def setup
    @date_current = Date.method(:current) if Date.respond_to?(:current)
    Date.singleton_class.define_method(:current) { Date.new(2026, 9, 30) }
  end

  def teardown
    if @date_current
      Date.singleton_class.define_method(:current, @date_current)
    else
      Date.singleton_class.remove_method(:current)
    end
  end

  def test_settings_and_project_override
    project = OpenStruct.new(identifier: 'example')
    config = { 'due_reminders' => { 'days' => 3 },
               'projects' => { 'example' => { 'due_reminders' => { 'days' => 7, 'enabled' => false } } } }
    RedmineSlackNotification.stub(:config, config) do
      assert_equal({ enabled: false, days: 7 }, RedmineSlackNotification.due_reminder_settings(project))
      assert_equal 7, RedmineSlackNotification.due_reminder_max_days
    end
  end

  def test_digest_groups_overdue_today_and_upcoming_with_overdue_color
    project = OpenStruct.new(name: 'Example')
    issues = [
      OpenStruct.new(id: 42, subject: 'Fix <problem>', due_date: Date.new(2026, 9, 28), project: project),
      OpenStruct.new(id: 43, subject: 'Due today', due_date: Date.current, project: project),
      OpenStruct.new(id: 44, subject: 'Due soon', due_date: Date.current + 2, project: project)
    ]
    RedmineSlackNotification::Formatter.stub(:url, ->(path) { "https://redmine.example#{path}" }) do
      digest = RedmineSlackNotification::Formatter.due_digest_payload(issues, today: Date.current)
      assert_includes digest.dig('blocks', 0, 'text', 'text'), '期日リマインダー 3件'
      assert_equal 3, digest['attachments'].size
      assert_equal ['#D92D20', '#F79009', RedmineSlackNotification::Formatter.attachment_color],
                   digest['attachments'].map { |attachment| attachment['color'] }
      overdue, current, upcoming = digest['attachments'].map do |attachment|
        attachment['blocks'].map { |block| block.dig('text', 'text') }.join("\n")
      end
      assert_includes overdue, '期限超過（1件）'
      assert_includes overdue, 'Fix &lt;problem&gt;'
      assert_includes overdue, '2日超過'
      refute_includes overdue, '2026-09-28'
      refute_includes overdue, 'Due today'
      assert_includes current, '本日期日（1件）'
      assert_includes current, 'Due today'
      refute_includes current, '2026-09-30'
      refute_includes current, 'Fix &lt;problem&gt;'
      assert_includes upcoming, '期日が近い課題（1件）'
      assert_includes upcoming, 'Due soon'
      assert_includes upcoming, '残り2日'
      refute_includes upcoming, '2026-10-02'
    end
  end

  def test_digest_colors_use_yaml_and_project_override
    project = OpenStruct.new(identifier: 'example', name: 'Example')
    issues = [-1, 0, 1].each_with_index.map do |offset, index|
      OpenStruct.new(id: index + 1, subject: "Issue #{index + 1}", due_date: Date.current + offset,
                     project: project)
    end
    config = {
      'slack' => { 'attachment_color' => '#112233' },
      'due_reminders' => { 'colors' => { 'overdue' => '#AABBCC', 'today' => 'orange' } },
      'projects' => { 'example' => { 'due_reminders' => {
        'colors' => { 'today' => '#445566', 'upcoming' => '#778899' }
      } } }
    }
    RedmineSlackNotification.stub(:config, config) do
      RedmineSlackNotification::Formatter.stub(:url, ->(path) { "https://redmine.example#{path}" }) do
        global = RedmineSlackNotification::Formatter.due_digest_payload(issues, today: Date.current)
        assert_equal ['#AABBCC', '#F79009', '#112233'], global['attachments'].map { |a| a['color'] }

        RedmineSlackNotification.with_project(project) do
          digest = RedmineSlackNotification::Formatter.due_digest_payload(issues, today: Date.current)
          assert_equal ['#AABBCC', '#445566', '#778899'], digest['attachments'].map { |a| a['color'] }
        end
      end
    end
  end

  def test_digest_wording_uses_yaml_messages_and_project_override
    project = OpenStruct.new(identifier: 'example', name: 'Example')
    issues = [
      OpenStruct.new(id: 42, subject: 'Late', due_date: Date.current - 2, project: project),
      OpenStruct.new(id: 43, subject: 'Soon', due_date: Date.current + 2, project: project)
    ]
    config = {
      'messages' => { 'due_reminders' => {
        'title' => '*Global %{count} %{suffix}*',
        'part_suffix' => '[%{part}/%{total_parts}]',
        'upcoming_label' => 'Upcoming',
        'upcoming_timing' => '%{days} days left',
        'issue_line' => '<%{url}|#%{id} %{subject}> in %{project}%{timing}',
        'timing_suffix' => ' (%{timing})'
      } },
      'projects' => { 'example' => { 'messages' => { 'due_reminders' => {
        'title' => '*Project %{count} %{suffix}*',
        'fallback' => 'Summary %{count}: %{overdue_count} late, %{today_count} today %{suffix}',
        'overdue_label' => 'Late',
        'group_heading' => '%{label}: %{count}',
        'overdue_timing' => '%{days} days late'
      } } } }
    }
    RedmineSlackNotification.stub(:config, config) do
      RedmineSlackNotification::Formatter.stub(:url, ->(path) { "https://redmine.example#{path}" }) do
        RedmineSlackNotification.with_project(project) do
          digest = RedmineSlackNotification::Formatter.due_digest_payload(issues, today: Date.current,
                                                                           part: 2, total_parts: 3)
          assert_equal 'Summary 2: 1 late, 0 today [2/3]', digest['text']
          assert_equal '*Project 2 [2/3]*', digest.dig('blocks', 0, 'text', 'text')
          assert_equal ['Late: 1', 'Upcoming: 1'], digest['attachments'].map { |a| a.dig('blocks', 0, 'text', 'text').lines.first.strip }
          assert_includes digest.dig('attachments', 0, 'blocks', 0, 'text', 'text'),
                          '<https://redmine.example/issues/42|#42 Late> in Example (2 days late)'
          assert_includes digest.dig('attachments', 1, 'blocks', 0, 'text', 'text'),
                          '<https://redmine.example/issues/43|#43 Soon> in Example (2 days left)'
        end
      end
    end
  end

  def test_digest_invalid_message_placeholder_uses_default
    project = OpenStruct.new(name: 'Example')
    issue = OpenStruct.new(id: 42, subject: 'Late', due_date: Date.current - 1, project: project)
    config = { 'messages' => { 'due_reminders' => { 'title' => '%{unknown}' } } }
    RedmineSlackNotification.stub(:config, config) do
      RedmineSlackNotification::Formatter.stub(:url, ->(path) { "https://redmine.example#{path}" }) do
        digest = RedmineSlackNotification::Formatter.due_digest_payload([issue], today: Date.current)
        assert_equal '📋 *期日リマインダー 1件*', digest.dig('blocks', 0, 'text', 'text')
      end
    end
  end

  def test_job_sends_eleven_issues_in_one_dm_on_every_run
    assignee = User.new
    assignee.define_singleton_method(:id) { 7 }
    assignee.define_singleton_method(:active?) { true }
    project = OpenStruct.new(id: 2, identifier: 'example', name: 'Example')
    issues = (1..11).map do |id|
      OpenStruct.new(id: id, subject: "Issue #{id}", due_date: Date.current, project: project)
    end
    posts = []
    api = ->(method, body, _token) do
      assert_equal 'conversations.open', method
      assert_equal({ 'users' => 'U123' }, body)
      { 'channel' => { 'id' => 'D123' } }
    end
    config = { 'slack' => { 'bot_token' => 'token' } }
    RedmineSlackNotification.stub(:config, config) do
      User.stub(:find_by, assignee) do
        RedmineSlackNotification.stub(:slack_api, api) do
          RedmineSlackNotification.stub(:post_message, ->(payload, channel, token) { posts << [payload, channel, token] }) do
            RedmineSlackNotification::Formatter.stub(:url, ->(path) { "https://redmine.example#{path}" }) do
              job = RedmineSlackDueDigestJob.new
              job.stub(:due_issues_for, { ['token', 'U123'] => issues }) do
                job.perform(7, '2026-09-29')
                assert_empty posts
                job.perform(7, '2026-09-30')
                job.perform(7, '2026-09-30')
              end
              assert_equal 2, posts.size
              assert_equal 'D123', posts.first[1]
              assert_equal 'token', posts.first[2]
              assert_equal '#F79009', posts.first[0].dig('attachments', 0, 'color')
              assert_includes posts.first[0].dig('blocks', 0, 'text', 'text'), '期日リマインダー 11件'
              body = posts.first[0].dig('attachments', 0, 'blocks').map { |block| block.dig('text', 'text') }.join("\n")
              assert_includes body, '#11 Issue 11'
            end
          end
        end
      end
    end
  end
end

Rake.application = Rake::Application.new
Rake::Task.define_task(:environment)
load File.expand_path('../lib/tasks/redmine_slack_due_reminders.rake', __dir__)

class DueReminderTaskTest < Minitest::Test
  class Scope
    attr_reader :filters

    def initialize
      @filters = {}
    end

    def where(condition = nil, *, **keywords)
      condition ||= keywords
      @filters.merge!(condition) if condition.is_a?(Hash)
      self
    end

    def not(*)
      self
    end

    def includes(*)
      self
    end

    def find_each
      [
        [3, 10, 2, 100, 0], [5, 10, 2, 100, 5], [7, 11, 3, 101, 0],
        [3, 10, 3, 100, 0]
      ].each_with_index do |(user_id, project_id, tracker_id, version_id, due_in), index|
        values = { assigned_to_id: user_id, project_id: project_id, tracker_id: tracker_id,
                   fixed_version_id: version_id }
        next unless @filters.all? do |key, expected|
          !values.key?(key) || Array(expected).include?(values[key])
        end

        project = OpenStruct.new(id: project_id, name: "Project #{project_id}")
        project.define_singleton_method(:active?) { true }
        issue = OpenStruct.new(id: index + 1, **values, due_date: Date.current + due_in, project: project)
        issue.define_singleton_method(:visible?) { |_user| true }
        yield issue
      end
    end
  end

  def setup
    @original_filters = ['users', 'users'.upcase, 'USER_ID', 'days', 'tracker', 'project', 'version']
                        .to_h { |name| [name, ENV[name]] }
    @original_filters.each_key { |name| ENV.delete(name) }
    @date_current = Date.method(:current) if Date.respond_to?(:current)
    Date.singleton_class.define_method(:current) { Date.new(2026, 9, 30) }
  end

  def teardown
    @original_filters.each do |name, value|
      value ? ENV[name] = value : ENV.delete(name)
    end
    if @date_current
      Date.singleton_class.define_method(:current, @date_current)
    else
      Date.singleton_class.remove_method(:current)
    end
  end

  def with_task
    scope = Scope.new
    queued = []
    logger = Object.new.tap { |item| item.define_singleton_method(:info) { |_message| } }
    RedmineSlackNotification.stub(:due_reminder_max_days, 3) do
      RedmineSlackNotification.stub(:due_reminder_settings, { enabled: true, days: 3 }) do
        Issue.stub(:joins, scope) do
          User.stub(:exists?, ->(options) { [3, 5, 7].include?(options[:id]) }) do
            Tracker.stub(:exists?, ->(options) { options[:id] == 2 }) do
              Project.stub(:find, ->(value) { OpenStruct.new(id: 10) if %w[10 example].include?(value) }) do
                Version.stub(:named, ->(name) {
                  Object.new.tap { |item| item.define_singleton_method(:pluck) { |_column| name == '1.0' ? [100] : [] } }
                }) do
                  Rails.stub(:logger, logger) do
                    RedmineSlackDueDigestJob.stub(:perform_later, ->(*args) { queued << args }) do
                      Rake::Task['redmine:slack:due_reminders'].reenable
                      yield scope, queued
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

  def test_users_filters_multiple_assignees_before_queuing
    ENV['users'] = '3, 5,3'
    with_task do |scope, queued|
      capture_io { Rake::Task['redmine:slack:due_reminders'].invoke }
      assert_equal [3, 5], scope.filters[:assigned_to_id]
      assert_equal [[3, '2026-09-30', {}]], queued
    end
  end

  def test_all_redmine_filters_are_passed_to_the_worker
    ENV.update('days' => '7', 'tracker' => '2', 'project' => 'example',
               'users' => '3,5', 'version' => '1.0')
    with_task do |scope, queued|
      capture_io { Rake::Task['redmine:slack:due_reminders'].invoke }
      filters = { 'days' => 7, 'tracker_id' => 2, 'project_id' => 10, 'version_ids' => [100] }
      assert_equal({ assigned_to_id: [3, 5], project_id: 10, tracker_id: 2,
                     fixed_version_id: [100] }, scope.filters.reject { |key, _value| key == :issue_statuses })
      assert_equal [[3, '2026-09-30', filters], [5, '2026-09-30', filters]], queued
    end
  end

  def test_invalid_or_missing_user_stops_before_queuing
    ['3,,5', '3,99', ''].each do |value|
      ENV['users'] = value
      with_task do |_scope, queued|
        assert_raises(SystemExit) { capture_io { Rake::Task['redmine:slack:due_reminders'].invoke } }
        assert_empty queued
      end
    end
  end

  def test_removed_user_id_is_rejected_before_queuing
    ENV['USER_ID'] = '3'
    with_task do |_scope, queued|
      assert_raises(SystemExit) { capture_io { Rake::Task['redmine:slack:due_reminders'].invoke } }
      assert_empty queued
    end
  end

  def test_noncanonical_users_name_is_rejected_before_queuing
    ENV['users'.upcase] = '3'
    with_task do |_scope, queued|
      assert_raises(SystemExit) { capture_io { Rake::Task['redmine:slack:due_reminders'].invoke } }
      assert_empty queued
    end
  end

  def test_invalid_redmine_filters_stop_before_queuing
    [{ 'days' => '-1' }, { 'days' => 'soon' }, { 'tracker' => '99' },
     { 'version' => 'missing' }].each do |values|
      ENV.update(values)
      with_task do |_scope, queued|
        assert_raises(SystemExit) { capture_io { Rake::Task['redmine:slack:due_reminders'].invoke } }
        assert_empty queued
      end
      values.each_key { |name| ENV.delete(name) }
    end
  end

  def test_worker_reapplies_task_filters_and_command_line_days
    filters = { 'days' => 7, 'project_id' => 10, 'tracker_id' => 2, 'version_ids' => [100] }
    user = OpenStruct.new(id: 5)
    scope = Scope.new
    job = RedmineSlackDueDigestJob.new
    RedmineSlackNotification.stub(:due_reminder_settings, { enabled: true, days: 3 }) do
      RedmineSlackNotification.stub(:bot_token, 'token') do
        RedmineSlackNotification.stub(:slack_user_id_for, 'U123') do
          Issue.stub(:joins, scope) do
            groups = job.send(:due_issues_for, user, Date.current, filters)
            assert_equal({ assigned_to_id: 5, project_id: 10, tracker_id: 2,
                           fixed_version_id: [100] }, scope.filters.reject { |key, _value| key == :issue_statuses })
            assert_equal [2], groups[['token', 'U123']].map(&:id)
          end
        end
      end
    end
  end
end
