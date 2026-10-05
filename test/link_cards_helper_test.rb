# frozen_string_literal: true
require_relative 'link_cards_test'

class String
  def html_safe; self; end unless method_defined?(:html_safe)
end

class LinkCardsHelperTest < Minitest::Test
  class BaseView
    attr_accessor :controller_name, :action_name, :request, :html, :render_source, :source_formatter
    def textilizable(*args)
      return source_formatter.call(args.first) if source_formatter && args.first.is_a?(String)
      return "<p>#{CGI.escapeHTML(args.first)}</p>" if render_source && args.first.is_a?(String)
      html
    end
  end
  class View < BaseView
    prepend Slackmine::LinkCardsHelper
  end

  def setup
    @view = View.new
    @view.controller_name = 'issues'
    @view.action_name = 'show'
    @view.request = OpenStruct.new(format: OpenStruct.new(html?: true))
    @view.html = '<p>formatted source</p>'.dup
    @view.html.define_singleton_method(:html_safe) { self }
    @issue = Issue.new(123)
    @issue.project = OpenStruct.new(identifier: 'example')
    @issue.define_singleton_method(:attachments) { [] }
  end

  def test_hook_renders_after_normal_formatting_and_keeps_source_permission_check
    rendered = false
    User.stub(:current, Object.new) do
      Slackmine::LinkCards.stub(:source, 'source') do
        Slackmine::LinkCards.stub(:render_links, lambda { |html, issue, _viewer, journal, state, **options|
          assert_equal @view.html, html
          assert_equal @issue, issue
          assert_nil journal
          assert_equal 0, state[:count]
          rendered = true
          html
        }) { @view.textilizable(@issue, :description) }
      end
      assert rendered
      Slackmine::LinkCards.stub(:source, nil) do
        Slackmine::LinkCards.stub(:render_links, ->(*) { flunk 'denied source' }) do
          assert_equal @view.html, @view.textilizable(@issue, :description)
        end
      end
    end
  end

  def test_other_contexts_do_not_fetch_slack
    Slackmine::LinkCards.stub(:source, ->(*) { flunk 'unexpected network context' }) do
      @view.controller_name = 'mailer'
      assert_equal @view.html, @view.textilizable(@issue, :description)
      @view.controller_name = 'issues'
      @view.request.format.define_singleton_method(:html?) { false }
      assert_equal @view.html, @view.textilizable(@issue, :description)
      @view.request.format.define_singleton_method(:html?) { true }
      assert_equal @view.html, @view.textilizable(@issue, :description, formatting: false)
      assert_equal @view.html, @view.textilizable('preview text')
    end
  end
  def test_mailer_view_without_controller_name_renders_normal_and_saved_notes
    mailer_view = Class.new(BaseView) do
      undef_method :controller_name
      prepend Slackmine::LinkCardsHelper
      def format_time(value); value.iso8601; end
    end.new
    mailer_view.html = '<p>Normal description</p>'
    @issue.define_singleton_method(:description) { @description }
    @issue.instance_variable_set(:@description, 'Normal description')
    Slackmine::LinkCards.stub(:source, ->(*) { flunk 'mail must not fetch Slack' }) do
      assert_equal mailer_view.html, mailer_view.textilizable(@issue, :description)
      card = { 'author' => 'Example', 'channel' => 'example', 'timestamp' => '2026-10-05T00:00:00Z', 'text' => 'Saved message' }
      @issue.instance_variable_set(:@description, Slackmine::LinkQuotes.encode(card, LinkCardsTest::URL))
      mailer_view.render_source = true
      rendered = mailer_view.textilizable(@issue, :description)
      assert_includes rendered, 'Saved message'
      refute_includes rendered, '[slack-quote:'
    end
  end

  def test_saved_quote_renders_without_network_and_preserves_private_note_gate
    card = { 'author' => 'Example', 'channel' => 'test', 'timestamp' => '2026-10-05T00:00:00Z',
             'text' => 'Searchable <script>alert(1)</script> {{include(private)}}', 'names' => {} }
    source = "#{LinkCardsTest::URL}\n\n#{Slackmine::LinkQuotes.encode(card, LinkCardsTest::URL)}"
    @view.render_source = true
    @view.define_singleton_method(:format_time) { |value| value.iso8601 }
    User.stub(:current, Object.new) do
      Slackmine::LinkCards.stub(:source, source) do
        Slackmine::LinkCards.stub(:fetch, ->(*) { flunk 'stored quotes must not fetch' }) do
          html = @view.textilizable(@issue, :description)
          doc = Nokogiri::HTML.fragment(html)
          assert_equal 1, doc.css('.slackmine-link-card').size
          assert_empty doc.css('script')
          assert_includes doc.text, '{{include(private)}}'
          refute_includes html, '[slack-quote:'
        end
      end
      Slackmine::LinkCards.stub(:source, nil) do
        assert_equal @view.html, @view.textilizable(@issue, :description)
      end
    end
  end

  def test_ajax_update_matches_page_reload_with_cards_at_url_positions
    url = LinkCardsTest::URL
    card = { 'author' => 'Example', 'channel' => 'example', 'timestamp' => '2026-10-05T00:00:00Z', 'text' => 'Saved message' }
    source = "#{url}\nって返した\n\n#{Slackmine::LinkQuotes.encode(card, url)}"
    journal = Journal.new
    journal.define_singleton_method(:journalized) { @issue }
    journal.instance_variable_set(:@issue, @issue)
    journal.define_singleton_method(:id) { 456 }
    @view.source_formatter = ->(text) { '<p>' + CGI.escapeHTML(text).sub(url, %(<a href="#{url}">#{url}</a>)) + '</p>' }
    @view.define_singleton_method(:format_time) { |value| value.iso8601 }
    @view.request.format.define_singleton_method(:js?) { true }
    User.stub(:current, Object.new) do
      Slackmine::LinkCards.stub(:source, ->(_issue, _viewer, id) { assert_equal 456, id; source }) do
        Slackmine::LinkCards.stub(:fetch, ->(*) { flunk 'saved quotes must not fetch' }) do
          page = @view.textilizable(journal, :notes)
          @view.controller_name = 'journals'; @view.action_name = 'update'
          @view.request.format.define_singleton_method(:html?) { false }
          ajax = @view.textilizable(journal, :notes)
          assert_equal page, ajax
          doc = Nokogiri::HTML.fragment(ajax)
          assert_equal 1, doc.css('.slackmine-link-card').size
          assert_equal ['Open in Slack'], doc.css('a').map(&:text)
          assert_operator doc.text.index('Saved message'), :<, doc.text.index('って返した')
          refute_includes ajax, '[slack-quote:'
        end
      end
      Slackmine::LinkCards.stub(:source, nil) do
        assert_equal @view.html, @view.textilizable(journal, :notes)
      end
    end
  end

  def test_saved_cards_replace_their_urls_in_source_order
    urls = [LinkCardsTest::URL, LinkCardsTest::URL.sub('C123', 'C456')]
    cards = urls.each_with_index.map do |url, index|
      card = { 'author' => "Author #{index}", 'channel' => 'example', 'timestamp' => '2026-10-05T00:00:00Z', 'text' => "Message #{index}" }
      [url, card]
    end
    fragment = Nokogiri::HTML.fragment("<p>Before</p><p><a href=\"#{urls[1]}\">#{urls[1]}</a></p><p>Between</p><p><a href=\"#{urls[0]}\">#{urls[0]}</a></p><p>After</p><p>TOKEN0</p><p>TOKEN1</p>")
    replacements = {}; mapping = {}
    cards.each_with_index do |(url, card), index|
      replacements["TOKEN#{index}"] = Slackmine::LinkCards.render_card(card, url, @issue.project)
      mapping["TOKEN#{index}"] = url
    end
    Slackmine::LinkCards.place_saved_cards(fragment, replacements, mapping)
    assert_equal ['Message 1', 'Message 0'], fragment.css('.slackmine-link-card-text').map(&:text)
    assert_equal ['Before', 'Message 1', 'Between', 'Message 0', 'After'], fragment.css('p').first(5).map { |p| p.at_css('.slackmine-link-card-text')&.text || p.text }
    assert_equal ['', ''], replacements.values
    assert_equal ['Open in Slack', 'Open in Slack'], fragment.css('a').map(&:text)
    assert_equal [urls[1], urls[0]], fragment.css('.slackmine-link-card a').map { |a| a['href'] }
  end

  def test_card_replacement_removes_only_adjacent_breaks
    url = LinkCardsTest::URL
    fragment = Nokogiri::HTML.fragment("<p>Before<br>\n<a href=\"#{url}\">#{url}</a>\n<br>After<br>Normal line</p>")
    replacements = { 'TOKEN' => '<span class="slackmine-link-card">saved quote</span>' }
    Slackmine::LinkCards.place_saved_cards(fragment, replacements, { 'TOKEN' => url })
    assert_equal 1, fragment.css('br').size
    assert_equal 'After', fragment.at_css('br').previous_sibling.text.strip
    assert_includes fragment.text, 'Normal line'
    assert_equal 1, fragment.css('.slackmine-link-card').size
  end

  def test_orphaned_quote_stays_in_place_and_code_links_are_untouched
    url = LinkCardsTest::URL
    fragment = Nokogiri::HTML.fragment("<pre><a href=\"#{url}\">#{url}</a></pre><p>TOKEN</p>")
    replacements = { 'TOKEN' => '<span class="slackmine-link-card">saved quote</span>' }
    Slackmine::LinkCards.place_saved_cards(fragment, replacements, { 'TOKEN' => url })
    assert_equal '<span class="slackmine-link-card">saved quote</span>', replacements['TOKEN']
    assert_equal url, fragment.at_css('pre a').text
  end

  def test_explicit_imported_images_move_inside_card_and_preserve_sizing
    url = LinkCardsTest::URL
    card = { 'author' => 'Example', 'channel' => 'example', 'text' => 'Reply', 'url' => url,
             'thread_image_ids' => [41, 42] }
    attachments = [41, 42].map { |id| OpenStruct.new(id: id) }
    image_urls = [41, 42].map { |id| "/attachments/download/#{id}/screen@2x.png" }
    html = '<p>' + Slackmine::LinkCards.render_card(card, url, @issue.project) + '</p>' +
           image_urls.map { |src| %(<p><a href="#{src}" class="image"><img src="#{src}" width="344" height="805" loading="lazy"></a></p>) }.join
    rendered = Slackmine::LinkCards.place_reply_images(html, [card], attachments: attachments)
    doc = Nokogiri::HTML.fragment(rendered)
    assert_equal image_urls, doc.css('.slackmine-link-card-images img').map { |img| img['src'] }
    assert_equal image_urls, doc.css('.slackmine-link-card-images a').map { |a| a['href'] }
    assert_equal ['344', '344'], doc.css('img').map { |img| img['width'] }
    assert_equal ['805', '805'], doc.css('img').map { |img| img['height'] }
    assert_equal 'Open in Slack', doc.at_css('.slackmine-link-card').element_children.last.text
    assert_equal 1, doc.css('p').size
    assert_equal rendered, Slackmine::LinkCards.place_reply_images(rendered, [card], attachments: attachments)
  end

  def test_explicit_file_downloads_appear_inside_only_their_card
    url = LinkCardsTest::URL
    card = { 'author' => 'Example', 'channel' => 'example', 'text' => 'Reply', 'url' => url,
             'thread_file_ids' => [41] }
    file = OpenStruct.new(id: 41, filename: 'F123-report.pdf')
    download = Slackmine::Formatter.url('/attachments/download/41')
    html = Slackmine::LinkCards.render_card(card, url, @issue.project) + %(<p><a href="#{download}">report.pdf</a></p><p>Other content</p>)
    rendered = Slackmine::LinkCards.place_reply_files(html, [card], attachments: [file])
    doc = Nokogiri::HTML.fragment(rendered)
    assert_equal 'F123-report.pdf', doc.at_css('.slackmine-link-card-files a').text
    assert_equal download, doc.at_css('.slackmine-link-card-files a')['href']
    assert_equal 1, doc.css("a[href='#{download}']").size
    assert_equal 'Other content', doc.at_css('p').text
    assert_equal 'Open in Slack', doc.at_css('.slackmine-link-card').element_children.last.text
    assert_equal rendered, Slackmine::LinkCards.place_reply_files(rendered, [card], attachments: [file])
    assert_equal html, Slackmine::LinkCards.place_reply_files(html, [], attachments: [file])
    doc = Nokogiri::HTML.fragment(Slackmine::LinkCards.place_reply_files(html, [card], attachments: []))
    assert_empty doc.css('.slackmine-link-card-files')
  end

  def test_unmarked_missing_and_external_images_stay_outside_card
    url = LinkCardsTest::URL
    card = { 'author' => 'Example', 'channel' => 'example', 'text' => 'Reply', 'url' => url }
    image_url = '/attachments/download/41/screen.png'
    html = Slackmine::LinkCards.render_card(card, url, @issue.project) + %(<p><img src="#{image_url}"></p>)
    attachments = [OpenStruct.new(id: 41)]
    assert_equal html, Slackmine::LinkCards.place_reply_images(html, [card], attachments: attachments)
    assert_equal html, Slackmine::LinkCards.place_reply_images(html, [], attachments: attachments)
    marked = card.merge('thread_image_ids' => [41])
    [[], [OpenStruct.new(id: 42)]].each do |unrelated|
      doc = Nokogiri::HTML.fragment(Slackmine::LinkCards.place_reply_images(html, [marked], attachments: unrelated))
      assert_empty doc.css('.slackmine-link-card-images')
    end
    external = html.sub(image_url, 'https://external.example' + image_url)
    doc = Nokogiri::HTML.fragment(Slackmine::LinkCards.place_reply_images(external, [marked], attachments: attachments))
    assert_empty doc.css('.slackmine-link-card-images')
  end

  def test_journal_rendering_groups_saved_image_without_fetching_slack
    url = LinkCardsTest::URL
    image_url = Slackmine::Formatter.url('/attachments/download/41')
    card = { 'author' => 'Example', 'channel' => 'example', 'timestamp' => '2026-10-05T00:00:00Z', 'text' => 'Reply', 'thread_image_ids' => [41] }
    @issue.define_singleton_method(:attachments) { [OpenStruct.new(id: 41)] }
    quote = Slackmine::LinkQuotes.encode(card, url)
    source = "#{url}\n\n![](#{image_url})\n\n#{quote}"
    journal = Journal.new
    journal.define_singleton_method(:journalized) { @issue }
    journal.instance_variable_set(:@issue, @issue)
    journal.define_singleton_method(:id) { 456 }
    @view.define_singleton_method(:format_time) { |value| value.iso8601 }
    @view.source_formatter = lambda do |text|
      text.split("\n\n").map do |part|
        content = part == url ? %(<a href="#{url}">#{url}</a>) :
                  (part == "![](#{image_url})" ? %(<img src="#{image_url}">) : CGI.escapeHTML(part))
        "<p>#{content}</p>"
      end.join
    end
    User.stub(:current, Object.new) do
      Slackmine::LinkCards.stub(:source, source) do
        Slackmine::LinkCards.stub(:fetch, ->(*) { flunk 'saved quotes must not fetch' }) do
          doc = Nokogiri::HTML.fragment(@view.textilizable(journal, :notes))
          assert_equal 1, doc.css('.slackmine-link-card-images img').size
          assert_equal 1, doc.css('img').size
          assert_equal 1, doc.css('.slackmine-link-card').size
        end
      end
    end
  end

end
