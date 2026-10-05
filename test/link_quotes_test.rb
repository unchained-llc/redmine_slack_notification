# frozen_string_literal: true
require_relative 'link_cards_test'

module Redmine
  module WikiFormatting
    def self.to_html(_format, text, *)
      # Test import selection from formatter output, not a reimplementation of Markdown.
      text
    end
  end
end

module Setting
  def self.text_formatting; 'markdown'; end
end

class LinkQuotesTest < Minitest::Test
  Q = RedmineSlackNotification::LinkQuotes
  URL = LinkCardsTest::URL

  def setup
    @card = { 'author' => 'Example User', 'channel' => 'example', 'timestamp' => '2026-10-05T00:00:00Z',
              'avatar' => 'https://cdn.example.com/avatar.png', 'text' => 'Unique searchable wording <@U123>', 'names' => { 'U123' => 'Display Name' } }
    @issue = OpenStruct.new(project: OpenStruct.new(identifier: 'example'), new_record?: false, visible?: true)
    @issue.define_singleton_method(:visible?) { |*| self[:visible?] }
    @viewer = OpenStruct.new(logged?: true)
    @viewer.define_singleton_method(:allowed_to?) { |*| true }
    @calls = []
  end

  def import(text)
    Setting.stub(:text_formatting, 'markdown') do
      RedmineSlackNotification::LinkCards.stub(:fetch_for_project, ->(_project, url, **_) { @calls << url; @card }) do
        Q.import(text, @issue, @viewer)
      end
    end
  end

  def test_normal_text_skips_formatter_and_slack_lookup
    source = '普通のコメント'
    Redmine::WikiFormatting.stub(:to_html, ->(*) { flunk 'no Slack URL to format' }) do
      assert_equal source, import(source)
    end
    assert_empty @calls
  end

  def test_quote_body_is_searchable_plain_text_and_round_trips
    source = "<p><a href=\"#{URL}\">message</a></p>"
    saved = import(source)
    assert_includes saved, 'Unique searchable wording'
    assert_includes saved, 'Display Name'
    assert_includes saved, source
    blocks = Q.blocks(saved)
    assert_equal 1, blocks.size
    assert_equal URL, blocks.first.last['url']
    assert_equal 'Unique searchable wording <@U123|Display Name>', blocks.first.last['text']
    @calls.clear
    assert_equal saved, import(saved)
    assert_empty @calls
    plain = Q.plain_source(saved)
    refute_includes plain, '[slack-quote:'
    assert_includes plain, 'Unique searchable wording'
  end

  def test_parent_quote_is_also_plain_text_and_can_contain_closing_markers
    @card['thread_reply'] = true
    @card['parent_url'] = URL
    @card['parent'] = @card.reject { |key, _| %w[parent parent_url thread_reply].include?(key) }.merge('text' => 'Parent searchable wording')
    @card['text'] = "Literal [/slack-quote:0000000000000000]\n``` code ```\n<script>alert(1)</script>"
    saved = Q.encode(@card, URL)
    assert_includes saved, 'Parent searchable wording'
    decoded = Q.blocks(saved).first.last
    assert_equal @card['text'], decoded['text']
    assert_equal 'Parent searchable wording', decoded['parent']['text']
    html = RedmineSlackNotification::LinkCards.render_card(decoded, URL, @issue.project)
    assert_includes html, 'Thread reply'
    assert_empty Nokogiri::HTML.fragment(html).css('script')
  end

  def test_imported_notification_reply_omits_parent_but_manual_url_keeps_it
    @card['thread_reply'] = true
    @card['parent_url'] = URL
    @card['parent'] = @card.reject { |key, _| %w[parent parent_url thread_reply].include?(key) }
                           .merge('text' => 'Parent notification')
    source = "<a href=\"#{URL}\">reply</a>"
    previous = Thread.current[:redmine_slack_thread_comment]
    Thread.current[:redmine_slack_thread_comment] = true
    saved = import(source)
    decoded = Q.blocks(saved).first.last
    assert_equal URL, decoded['url']
    assert_equal 'Unique searchable wording <@U123|Display Name>', decoded['text']
    refute decoded.key?('parent')
    refute decoded.key?('thread_reply')
    refute_includes saved, 'Parent notification'
    html = RedmineSlackNotification::LinkCards.render_card(decoded, URL, @issue.project)
    refute_includes html, 'Thread reply'
    refute_includes html, 'Open parent message'
    assert_includes html, 'Example User'
    assert_equal URL, Nokogiri::HTML.fragment(html).at_css('a')['href']

    Thread.current[:redmine_slack_thread_comment] = nil
    manual = Q.blocks(import(source)).first.last
    assert_equal 'Parent notification', manual['parent']['text']
    assert_equal true, manual['thread_reply']
    assert @card.key?('parent')
  ensure
    Thread.current[:redmine_slack_thread_comment] = previous
  end

  def test_permissions_failures_code_and_duplicate_targets
    source = "<a href=\"#{URL}\">one</a><a href=\"#{URL}?cid=C123\">two</a><pre><a href=\"#{URL.sub('C123', 'C456')}\">code</a></pre>"
    saved = import(source)
    assert_equal [URL], @calls
    assert_equal 1, Q.blocks(saved).size
    @viewer[:logged?] = false
    @calls.clear
    assert_equal source, import(source)
    assert_empty @calls
    @viewer[:logged?] = true
    @issue[:visible?] = false
    assert_equal source, import(source)
    assert_empty @calls
    @issue[:new_record?] = true
    assert_equal 1, Q.blocks(import(source)).size
    Setting.stub(:text_formatting, 'markdown') do
      RedmineSlackNotification::LinkCards.stub(:fetch_for_project, nil) do
        assert_equal source, Q.import(source, @issue, @viewer)
      end
    end
  end

  def test_invalid_metadata_is_not_interpreted_and_unsafe_avatar_is_removed
    encoded = Base64.strict_encode64(JSON.generate(@card.merge('url' => 'javascript:alert(1)')))
    assert_nil Q.decode(encoded, 'body')
    assert_empty Q.blocks('[slack-quote:invalid:0000000000000000]')
    @card['avatar'] = 'javascript:alert(1)'
    assert_nil Q.blocks(Q.encode(@card, URL)).first.last['avatar']
  end

  def test_callbacks_import_only_changed_fields_and_attach_before_validation
    callback_class = Class.new do
      class << self
        attr_reader :callback
        def before_validation(name); @callback = name; end
        def after_create_commit(*); end
        def after_update_commit(*); end
        def after_destroy(*); end
      end
      attr_accessor :description, :notes, :journalized, :changed
      def will_save_change_to_description?; changed; end
      def will_save_change_to_notes?; changed; end
    end
    issue_class = Class.new(callback_class) { include RedmineSlackNotification::IssuePatch }
    journal_class = Class.new(callback_class) { include RedmineSlackNotification::JournalPatch }
    assert_equal :import_slack_description_quotes, issue_class.callback
    assert_equal :import_slack_notes_quotes, journal_class.callback
    record = issue_class.new
    record.description = 'source'
    record.changed = true
    User.stub(:current, @viewer) do
      Q.stub(:import, ->(text, issue, viewer) { assert_equal record, issue; assert_equal @viewer, viewer; text + ' quote' }) do
        record.send(:import_slack_description_quotes)
      end
    end
    assert_equal 'source quote', record.description
    record.changed = false
    Q.stub(:import, ->(*) { flunk 'unchanged field' }) { record.send(:import_slack_description_quotes) }
    journal = journal_class.new
    journal.journalized = Issue.new(123)
    journal.notes = 'comment'; journal.changed = true
    User.stub(:current, @viewer) do
      Q.stub(:import, ->(text, issue, *) { assert_equal journal.journalized, issue; text + ' quote' }) do
        journal.send(:import_slack_notes_quotes)
      end
    end
    assert_equal 'comment quote', journal.notes
  end
  def test_plain_mail_and_slack_notifications_hide_storage_markers
    @card['author'] = '投稿者'
    @card['text'] = 'Unique searchable wording 日本語'
    quote = Q.encode(@card, URL).dup.force_encoding(Encoding::ASCII_8BIT)
    html_part = OpenStruct.new(mime_type: 'text/html', body: OpenStruct.new(decoded: '<p>HTML</p>'))
    text_part = OpenStruct.new(mime_type: 'text/plain', body: OpenStruct.new(decoded: quote))
    message = OpenStruct.new(mime_type: 'multipart/alternative', all_parts: [text_part, html_part])
    base = Class.new do
      attr_accessor :message
      def mail(*, **); message; end
    end
    mailer = Class.new(base) { prepend RedmineSlackNotification::MailerPatch }.new
    mailer.message = message
    assert_same message, mailer.mail
    assert_includes text_part.body, 'Unique searchable wording'
    refute_includes text_part.body, '[slack-quote:'
    assert_equal '<p>HTML</p>', html_part.body.decoded
    slack = RedmineSlackNotification::Formatter.mrkdwn(quote)
    assert_includes slack, 'Unique searchable wording'
    refute_includes slack, '[slack-quote:'
  end

end
