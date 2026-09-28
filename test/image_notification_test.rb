# frozen_string_literal: true

require 'minitest/autorun'
require 'ostruct'

module Rails
  def self.application
    @application ||= OpenStruct.new(config: OpenStruct.new(to_prepare: nil, after_initialize: nil))
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
end

class RedmineSlackNotificationJob
  def self.perform_later(*)
  end
end

class Journal
  def self.find_by(id:)
    nil
  end
end

require_relative '../lib/redmine_slack_notification'

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

  def test_example_yaml_lists_every_supported_event
    example = YAML.safe_load(File.read(File.expand_path('../config/redmine_slack_notification.yml.example', __dir__)))
    assert_equal RedmineSlackNotification::EVENT_KEYS.sort, example.fetch('events').keys.sort
    assert example.fetch('events').values.all? { |value| value == true }
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

  def test_both_disabled_send_nothing
    RedmineSlackNotification.stub(:config, { 'events' => { 'comment_added' => false, 'issue_updated' => false } }) do
      RedmineSlackNotification.stub(:enqueue, ->(*) { flunk 'disabled journal was enqueued' }) do
        journal.send(:notify_slack_journal_created)
      end
    end
  end

  private

  def assert_journal_notification(settings, expected_payload:, expected_details:, expected_event:, expected_images:, expected_journal_id:)
    calls = []
    comment_payload = ->(_issue, actor:, notes:, details:) { calls << [:comment, details, notes]; :comment }
    update_payload = ->(_issue, actor:, action:, details:) { calls << [:update, details, action]; :update }
    enqueue = ->(payload, **options) { calls << [:enqueue, payload, options] }
    RedmineSlackNotification.stub(:config, { 'events' => settings }) do
      RedmineSlackNotification::Formatter.stub(:journal_payload, comment_payload) do
        RedmineSlackNotification::Formatter.stub(:issue_payload, update_payload) do
          RedmineSlackNotification.stub(:enqueue, enqueue) do
            journal.send(:notify_slack_journal_created)
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

  def test_ordered_lists_use_markdown_inside_the_colored_attachment
    notes = "1. first\n1. second\n1. third\n\n![](screenshot.png)\n\nDone"
    blocks = RedmineSlackNotification::Formatter.mrkdwn_sections('追加コメント', notes)
    message = RedmineSlackNotification::Formatter.payload('Redmine notification', blocks: blocks)

    assert_equal '#6D5DFB', message.dig('attachments', 0, 'color')
    assert_equal [{ 'type' => 'markdown', 'text' => "**追加コメント**\n\n#{notes}" }], message.dig('attachments', 0, 'blocks')
    assert_nil message['blocks']
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

  def test_failed_markdown_image_upload_keeps_a_redmine_link
    attachment = OpenStruct.new(id: 42, filename: 'screenshot.png')
    notes = "1. first\n\n![](screenshot.png)"
    message = RedmineSlackNotification::Formatter.payload('Redmine notification', blocks: RedmineSlackNotification::Formatter.mrkdwn_sections('追加コメント', notes))
    Journal.stub(:find_by, journal(attachments: [attachment])) do
      RedmineSlackNotification.stub(:upload_image, nil) do
        RedmineSlackNotification.add_images(message, [attachment.filename], 1, 'token')
      end
    end

    assert_includes message.dig('attachments', 0, 'blocks', 0, 'text'), '[画像: screenshot.png](https://redmine.example.com/attachments/42)'
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
