# frozen_string_literal: true

require 'minitest/autorun'
require 'ostruct'

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
end

class PresenceValue < String
  def present?
    !empty?
  end

  def presence
    present? ? self : nil
  end
end

class RedmineSlackNotificationJob
  def self.perform_later(*)
  end
end

class User
  attr_accessor :login, :mail, :name

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

class EventConfigurationTest < Minitest::Test
  class TestJournal < Journal
    attr_accessor :journalized, :notes, :details, :user, :id

    def private_notes?
      false
    end

    def self.after_create_commit(*)
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

  def test_relation_keys_inherit_issue_updated_when_omitted
    RedmineSlackNotification.stub(:config, { 'events' => { 'issue_updated' => false } }) do
      refute RedmineSlackNotification.event_enabled?(project, 'relation_added')
      refute RedmineSlackNotification.event_enabled?(project, 'relation_removed')
    end
    RedmineSlackNotification.stub(:config, { 'events' => { 'issue_updated' => false, 'relation_added' => true } }) do
      assert RedmineSlackNotification.event_enabled?(project, 'relation_added')
    end
  end

  def test_example_yaml_lists_every_supported_event
    example = YAML.safe_load(File.read(File.expand_path('../config/redmine_slack_notification.yml.example', __dir__)))
    assert_equal RedmineSlackNotification::EVENT_KEYS.sort, example.fetch('events').keys.sort
    assert_equal RedmineSlackNotification::DEFAULT_DISABLED_EVENTS.sort,
                 example.fetch('events').select { |_key, value| value == false }.keys.sort
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

  def test_issue_detail_keys_inherit_issue_updated_when_omitted
    RedmineSlackNotification.stub(:config, { 'events' => { 'issue_updated' => false } }) do
      RedmineSlackNotification::ISSUE_DETAIL_EVENTS.each do |event|
        refute RedmineSlackNotification.event_enabled?(project, event), event
      end
    end
  end

  def test_project_can_enable_one_detail_when_global_issue_updates_are_disabled
    settings = {
      'events' => { 'issue_updated' => false },
      'projects' => { 'agentic' => { 'events' => { 'status_changed' => true } } }
    }
    RedmineSlackNotification.stub(:config, settings) do
      assert RedmineSlackNotification.event_enabled?(project, 'status_changed')
      refute RedmineSlackNotification.event_enabled?(project, 'assignee_changed')
    end
  end

  def test_project_issue_update_fallback_takes_precedence_over_global_detail
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
        'parent_id' => 'parent_changed', 'category_id' => 'issue_updated'
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

  def test_relation_addition_can_be_enabled_without_issue_changes
    relation = OpenStruct.new(property: 'relation', value: 7011)
    assert_journal_notification(
      { 'issue_updated' => false, 'relation_added' => true }, details: [:changed, relation],
      expected_payload: :comment, expected_details: [relation],
      expected_event: 'relation_added', expected_images: ['screenshot.png'], expected_journal_id: 12
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
      { 'issue_updated' => false, 'relation_removed' => true }, details: [relation], notes: '',
      expected_payload: :update, expected_details: [relation],
      expected_event: 'relation_removed', expected_images: [], expected_journal_id: nil
    )
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
    'wac.example.com'
  end
end

class ImageNotificationTest < Minitest::Test
  def payload
    { 'attachments' => [{ 'fallback' => 'WAC notification', 'blocks' => [{ 'type' => 'section', 'text' => { 'type' => 'mrkdwn', 'text' => '*追加コメント*\n> ![](clipboard-202609281254-s6trp@2x.png)' } }] }] }
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

  def test_ordered_lists_use_markdown_inside_the_colored_attachment
    notes = "1. first\n1. second\n1. third\n\n![](screenshot.png)\n\nDone"
    blocks = RedmineSlackNotification::Formatter.mrkdwn_sections('追加コメント', notes)
    message = RedmineSlackNotification::Formatter.payload('WAC notification', blocks: blocks)

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
    assert_equal ['添付ファイル', '添付ファイル', '親チケット', '対象バージョン', '顧客分類'], changes.map(&:first)
    assert_equal ['追加: one.png', '追加: two.png'], changes.first(2).map(&:last)
    assert_equal 'なし → #7011', changes[2][1]
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
    message = RedmineSlackNotification::Formatter.payload('WAC notification', blocks: RedmineSlackNotification::Formatter.mrkdwn_sections('追加コメント', notes))
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

  def test_failed_markdown_image_upload_keeps_a_wac_link
    attachment = OpenStruct.new(id: 42, filename: 'screenshot.png')
    notes = "1. first\n\n![](screenshot.png)"
    message = RedmineSlackNotification::Formatter.payload('WAC notification', blocks: RedmineSlackNotification::Formatter.mrkdwn_sections('追加コメント', notes))
    Journal.stub(:find_by, journal(attachments: [attachment])) do
      RedmineSlackNotification.stub(:upload_image, nil) do
        RedmineSlackNotification.add_images(message, [attachment.filename], 1, 'token')
      end
    end

    assert_includes message.dig('attachments', 0, 'blocks', 0, 'text'), '[画像: screenshot.png](https://wac.example.com/attachments/42)'
  end

  def test_embeds_uploaded_image_and_links_to_wac
    attachment = OpenStruct.new(id: 42, filename: 'clipboard-202609281254-s6trp@2x.png')
    message = payload
    Journal.stub(:find_by, journal(attachments: [attachment])) do
      RedmineSlackNotification.stub(:upload_image, 'F123') do
        RedmineSlackNotification.add_images(message, [attachment.filename], 1, 'token')
      end
    end

    assert_equal 'WAC notification', message.dig('attachments', 0, 'fallback')
    blocks = message.dig('attachments', 0, 'blocks')
    assert_equal 2, blocks.length
    refute_includes blocks.first.dig('text', 'text'), '画像:'
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
    assert_includes message.dig('attachments', 0, 'blocks', 0, 'text', 'text'), 'https://wac.example.com/attachments/42'
  end

  def test_multiple_images_follow_their_markdown_positions
    names = %w[english.png japanese.png chinese.png]
    attachments = names.each_with_index.map { |name, index| OpenStruct.new(id: index + 1, filename: name) }
    message = {
      'attachments' => [{ 'fallback' => 'WAC notification', 'blocks' => [
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

    assert_includes message.dig('attachments', 0, 'blocks', 0, 'text', 'text'), 'https://wac.example.com/issues/7097'
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
    message = RedmineSlackNotification::Formatter.payload('WAC notification', blocks: [
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
    message = RedmineSlackNotification::Formatter.payload('WAC notification', blocks: [
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
