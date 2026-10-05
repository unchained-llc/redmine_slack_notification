# frozen_string_literal: true
require 'minitest/autorun'
require 'nokogiri'
require_relative '../lib/slackmine/slack_markup'

class SlackMarkupTest < Minitest::Test
  M = Slackmine::SlackMarkup

  def test_emphasis_emoji_and_japanese_are_rendered
    html = M.render('💬 *追加コメント* _斜体_ ~削除~ :speech_balloon: **bold**')
    doc = Nokogiri::HTML.fragment(html)
    assert_equal ['追加コメント', 'bold'], doc.css('strong').map(&:text)
    assert_equal '斜体', doc.at_css('em').text
    assert_equal '削除', doc.at_css('del').text
    assert_includes doc.text, '💬'
    assert_includes M.render('prefix_some_value'), 'prefix_some_value'
  end

  def test_raw_html_and_unsafe_links_are_inert
    html = M.render('<script>alert(1)</script> <javascript:alert|bad> [bad](javascript:alert) <https://example.com/?a=1&amp;b=2|good>')
    doc = Nokogiri::HTML.fragment(html)
    assert_empty doc.css('script')
    assert_equal ['https://example.com/?a=1&b=2'], doc.css('a').map { |a| a['href'] }
    assert_includes doc.text, '<script>alert(1)</script>'
    assert doc.at_css('a')['rel'].include?('noopener')
  end

  def test_code_quotes_lists_and_headings
    html = M.render("# Heading\n&gt; *quote*\n- Item\n1. First\n```ruby\n<script> *literal* :smile:\n```\n`*code*`")
    doc = Nokogiri::HTML.fragment(html)
    assert_equal 'Heading', doc.at_css('.slack-markdown-heading').text
    assert_equal 'quote', doc.at_css('.slack-markdown-quote strong').text
    assert_equal 2, doc.css('.slack-markdown-list-item').size
    assert_includes doc.at_css('.slack-markdown-code-block').text, '<script> *literal* :smile:'
    assert_equal '*code*', doc.css('code').last.text
  end

  def test_resolved_names_are_plain_text
    html = M.render('<@U123> <#C123> <@U456|Fallback>', { 'U123' => '<img src=x onerror=alert(1)>', 'C123' => 'channel' })
    doc = Nokogiri::HTML.fragment(html)
    assert_empty doc.css('img')
    assert_includes doc.text, '@<img src=x onerror=alert(1)>'
    assert_includes doc.text, '#channel'
    assert_includes doc.text, '@Fallback'
  end
end
