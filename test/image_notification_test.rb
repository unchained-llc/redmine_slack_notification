# frozen_string_literal: true

require 'minitest/autorun'
require 'ostruct'

# The production plugin runs inside Rails. Keep the standalone tests small.
class Object
  def blank?
    respond_to?(:empty?) ? empty? : !self
  end

  def present?
    !blank?
  end

  def presence
    present? ? self : nil
  end
end

class String
  def truncate(length)
    size > length ? self[0, length - 3] + '...' : self
  end
end

module Enumerable
  def filter_map
    each_with_object([]) do |item, results|
      value = yield(item)
      results << value if value
    end
  end
end unless Enumerable.method_defined?(:filter_map)

module Rails
  def self.application
    @application ||= OpenStruct.new(config: OpenStruct.new(to_prepare: nil, after_initialize: nil))
  end
end

class Issue
  attr_reader :id

  def initialize(id, private_issue: false)
    @id = id
    @private_issue = private_issue
  end

  def is_private?
    @private_issue
  end
end

class Journal
  def self.find_by(id:)
    nil
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

require_relative '../lib/redmine_slack_notification'

class ImageNotificationTest < Minitest::Test
  def payload(content = '**追加コメント**\n\n![](screenshot.png)')
    { 'text' => 'Redmine notification', 'blocks' => [{ 'type' => 'markdown', 'text' => content }] }
  end

  def journal(private_note: false, attachments: [])
    OpenStruct.new(journalized: Issue.new(7097), private_notes?: private_note, attachments: attachments)
  end

  def issue
    OpenStruct.new(
      id: 7011, project: OpenStruct.new(name: 'NTTHQ'), tracker: OpenStruct.new(name: '通常'),
      subject: 'Security Update', description: '1. first\n1. second', category: nil, priority: nil
    )
  end

  def actor
    OpenStruct.new(name: 'Kota')
  end

  def test_extracts_only_local_image_references
    assert_equal ['screenshot.png'], RedmineSlackNotification::Formatter.image_references('![](screenshot.png)')
    assert_empty RedmineSlackNotification::Formatter.image_references('![](https://example.com/image.png)')
  end

  def test_all_event_paths_use_top_level_markdown
    formatter = RedmineSlackNotification::Formatter
    project = OpenStruct.new(name: 'NTTHQ', identifier: 'ntthq')
    wiki = OpenStruct.new(page: OpenStruct.new(title: '運用 手順'), comments: 'Updated')
    messages = [
      formatter.issue_payload(issue, actor: actor, action: 'created'),
      formatter.journal_payload(issue, actor: actor, notes: "1. first\n1. second"),
      formatter.wiki_payload(wiki, project, actor: actor, action: 'updated'),
      formatter.generic_payload(noun: 'News', action: 'created', subject: 'News', url: 'https://redmine.example.com/news/1', project: project, actor: actor),
      formatter.generic_payload(noun: 'Time entry', action: 'created', subject: '#1', url: 'https://redmine.example.com/time_entries/1', project: project, actor: actor),
      formatter.generic_payload(noun: 'Version', action: 'updated', subject: 'v1', url: 'https://redmine.example.com/versions/1', project: project, actor: actor),
      formatter.generic_payload(noun: 'Project', action: 'updated', subject: 'NTTHQ', url: 'https://redmine.example.com/projects/ntthq', project: project, actor: actor)
    ]

    messages.each do |message|
      assert_equal ['markdown'], message.fetch('blocks').map { |block| block['type'] }
      refute message.key?('attachments')
    end
    assert_includes messages[1].dig('blocks', 0, 'text'), "1. first\n1. second"
    assert_includes messages[2].dig('blocks', 0, 'text'), '/wiki/%E9%81%8B%E7%94%A8%20%E6%89%8B%E9%A0%86'
  end

  def test_long_markdown_is_bounded_and_links_to_redmine
    message = RedmineSlackNotification::Formatter.payload('Redmine notification', markdown: 'x' * 13_000, source_url: 'https://redmine.example.com/issues/7011')
    content = message.dig('blocks', 0, 'text')
    assert_operator content.length, :<=, 12_000
    assert_includes content, '[全文を Redmine で確認](https://redmine.example.com/issues/7011)'
  end

  def test_truncation_closes_code_fence_before_redmine_link
    body = "# Note\n```ruby\n" + ("puts :ok\n" * 2_000)
    message = RedmineSlackNotification::Formatter.payload('Redmine notification', markdown: body, source_url: 'https://redmine.example.com/issues/7011')
    content = message.dig('blocks', 0, 'text')
    assert_match(/\n```\n\n… \[全文を Redmine で確認\]/, content)
    assert_operator content.length, :<=, 12_000
  end

  def test_embeds_image_between_markdown_text_blocks
    attachment = OpenStruct.new(id: 42, filename: 'screenshot.png')
    message = payload("**追加コメント**\n\n1. first\n1. second\n\n![](screenshot.png)\n\nDone")
    Journal.stub(:find_by, journal(attachments: [attachment])) do
      RedmineSlackNotification.stub(:upload_image, 'F123') do
        RedmineSlackNotification.add_images(message, [attachment.filename], 1, 'token')
      end
    end

    assert_equal ['markdown', 'image', 'markdown'], message.fetch('blocks').map { |block| block['type'] }
    assert_equal "**追加コメント**\n\n1. first\n1. second", message.dig('blocks', 0, 'text')
    assert_equal 'F123', message.dig('blocks', 1, 'slack_file', 'id')
    assert_equal 'Done', message.dig('blocks', 2, 'text')
  end

  def test_failed_upload_keeps_redmine_attachment_link
    attachment = OpenStruct.new(id: 42, filename: 'screenshot.png')
    message = payload
    Journal.stub(:find_by, journal(attachments: [attachment])) do
      RedmineSlackNotification.stub(:upload_image, nil) do
        RedmineSlackNotification.add_images(message, [attachment.filename], 1, 'token')
      end
    end

    assert_includes message.dig('blocks', 0, 'text'), '[画像: screenshot\\.png](https://redmine.example.com/attachments/42)'
  end

  def test_multiple_images_follow_their_markdown_positions
    names = %w[english.png japanese.png chinese.png]
    attachments = names.each_with_index.map { |name, index| OpenStruct.new(id: index + 1, filename: name) }
    message = payload("**追加コメント**\nEN\n![English](english.png)\n\nJA\n![](japanese.png)\n\nZH\n![](chinese.png)")
    file_ids = { 'english.png' => 'FEN', 'japanese.png' => 'FJA', 'chinese.png' => 'FZH' }
    Journal.stub(:find_by, journal(attachments: attachments)) do
      RedmineSlackNotification.stub(:upload_image, ->(attachment, _token) { file_ids.fetch(attachment.filename) }) do
        RedmineSlackNotification.add_images(message, names, 1, 'token')
      end
    end

    assert_equal [
      ['markdown', "**追加コメント**\nEN"],
      ['image', 'FEN'],
      ['markdown', 'JA'],
      ['image', 'FJA'],
      ['markdown', 'ZH'],
      ['image', 'FZH']
    ], message.fetch('blocks').map { |block| [block['type'], block['type'] == 'image' ? block.dig('slack_file', 'id') : block['text']] }
  end

  def test_missing_attachment_links_to_issue_without_upload
    message = payload
    Journal.stub(:find_by, journal) do
      RedmineSlackNotification.stub(:upload_image, ->(*) { flunk 'missing image was uploaded' }) do
        RedmineSlackNotification.add_images(message, ['screenshot.png'], 1, 'token')
      end
    end

    assert_includes message.dig('blocks', 0, 'text'), 'https://redmine.example.com/issues/7097'
  end

  def test_private_note_is_not_uploaded
    message = payload
    Journal.stub(:find_by, journal(private_note: true)) do
      RedmineSlackNotification.stub(:upload_image, ->(*) { flunk 'private image was uploaded' }) do
        RedmineSlackNotification.add_images(message, ['screenshot.png'], 1, 'token')
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
      RedmineSlackNotification.slack_api('files.getUploadURLExternal', { 'filename' => 'screenshot.png', 'length' => 42 }, 'token', form: true)
    end

    assert_equal 'application/x-www-form-urlencoded', captured_request.content_type
    assert_equal({ 'filename' => 'screenshot.png', 'length' => '42' }, URI.decode_www_form(captured_request.body).to_h)
  end

  def test_retries_newly_uploaded_image_without_changing_file_id
    message = { 'blocks' => [{ 'type' => 'image', 'slack_file' => { 'id' => 'F123' }, 'alt_text' => 'image' }] }
    attempts = []
    delays = []
    error = RedmineSlackNotification::SlackApiError.new('chat.postMessage', '200', { 'error' => 'invalid_blocks', 'response_metadata' => { 'messages' => ['[ERROR] invalid slack file'] } })
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
end
