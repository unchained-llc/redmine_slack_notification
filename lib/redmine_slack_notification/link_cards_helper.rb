# frozen_string_literal: true
require 'nokogiri'
require_relative 'slack_markup'

module RedmineSlackNotification
  module LinkCardsHelper
    def textilizable(*args)
      options = args.last.is_a?(Hash) ? args.last : {}
      object, attribute = args.size >= 2 && !args[1].is_a?(Hash) ? args.first(2) : [options[:object], nil]
      if object.is_a?(Issue) && attribute == :description
        issue = object; journal_id = nil
      elsif object.is_a?(Journal) && attribute == :notes && object.journalized.is_a?(Issue)
        issue = object.journalized; journal_id = object.id
      else
        return super
      end
      card_view = respond_to?(:controller_name) && options[:formatting] != false &&
                  ((controller_name == 'issues' && action_name == 'show' && request.format.html?) ||
                   (controller_name == 'journals' && action_name == 'update' && request.format.js?))
      raw = if card_view
              LinkCards.source(issue, User.current, journal_id)
            elsif object.respond_to?(attribute)
              object.public_send(attribute).to_s
            end
      return super unless raw
      time_formatter = ->(value) { format_time(Time.iso8601(value)) }
      quotes = LinkQuotes.blocks(raw)
      replacements = {}
      quote_urls = {}
      prepared = raw.to_s.dup
      quotes.each do |block, card|
        token = "SLACKQUOTE#{SecureRandom.hex(16)}"
        quote_urls[token] = card['url']
        replacements[token] = if options[:formatting] == false
                                %(<span style="white-space: pre-wrap">#{SlackMarkup.escape(LinkQuotes.plain_source(block))}</span>)
                              else
                                LinkCards.render_card(card, card['url'], issue.project,
                                                      time_formatter: time_formatter)
                              end
        prepared = prepared.sub(block, token)
      end
      html = quotes.empty? ? super : super(prepared, options.merge(object: object))
      unless replacements.empty?
        fragment = Nokogiri::HTML.fragment(html.to_s)
        quote_paragraphs = fragment.css('p').select { |node| replacements.keys.any? { |token| node.text.include?(token) } }
        LinkCards.place_saved_cards(fragment, replacements, quote_urls) if card_view
        fragment.xpath('.//text()').each do |node|
          next unless replacements.keys.any? { |token| node.text.include?(token) }
          pieces = node.text.split(/(#{Regexp.union(replacements.keys)})/)
          node.replace(Nokogiri::HTML.fragment(pieces.map { |piece| replacements[piece] || SlackMarkup.escape(piece) }.join))
        end
        # The appended quote placeholders may have had their own paragraphs.
        quote_paragraphs.each { |node| node.remove if node.text.strip.empty? && node.element_children.all? { |child| child.name == 'br' } }
        html = fragment.to_html
      end
      return html.html_safe unless card_view
      @slack_link_card_state ||= { api: {}, cards: {}, count: 0,
                                   deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5 }
      LinkCards.render_links(html, issue, User.current, journal_id, @slack_link_card_state,
                             time_formatter: time_formatter,
                             quoted_urls: quotes.map { |_, card| card['url'] }).html_safe
    end
  end

  module LinkCards
    module_function

    def place_saved_cards(fragment, replacements, quote_urls)
      quote_urls.each do |token, url|
        anchors = fragment.css('a[href]').select do |anchor|
          next false if anchor.ancestors.any? { |node| %w[pre code].include?(node.name) || node['class'].to_s.split.include?('redmine-slack-link-card') }
          LinkQuotes.identity(anchor['href']) == LinkQuotes.identity(url)
        end
        next if anchors.empty?
        replace_link_with_card(anchors.first, replacements[token])
        replacements[token] = ''
        # Keep additional references compact without repeating the saved body.
        anchors.drop(1).each { |anchor| anchor.content = 'Slack ↗' if anchor.text == anchor['href'] }
      end
    end

    def replace_link_with_card(anchor, html)
      # Cards are block elements; the URL's adjacent line breaks add extra blank lines.
      %i[previous_sibling next_sibling].each do |direction|
        sibling = anchor.public_send(direction)
        sibling = sibling.public_send(direction) while sibling && sibling.text? && sibling.text.strip.empty?
        sibling.remove if sibling && sibling.name == 'br'
      end
      anchor.replace(Nokogiri::HTML.fragment(html))
    end

    def header(card, time_formatter = nil)
      timestamp = time_formatter && card['timestamp'] ? time_formatter.call(card['timestamp']) : card['timestamp']
      avatar = card['avatar'] ? %(<img src="#{SlackMarkup.escape(card['avatar'])}" alt="" loading="lazy">) : ''
      %(<span class="redmine-slack-link-card-header">#{avatar}<strong>#{SlackMarkup.escape(card['author'])}</strong><span> · ##{SlackMarkup.escape(card['channel'])} · #{SlackMarkup.escape(timestamp)}</span></span>)
    end

    def render_card(card, url, project, time_formatter: nil)
      text = SlackMarkup.render(card['text'], card['names'] || {})
      context = +''
      if card['thread_reply']
        context << %(<span class="redmine-slack-thread-label">↳ Thread reply</span>)
        if (parent = card['parent'])
          parent = parent.merge('channel' => card['channel'])
          context << %(<span class="redmine-slack-thread-parent">#{header(parent, time_formatter)}<span class="redmine-slack-link-card-text">#{SlackMarkup.render(parent['text'].to_s[0, 500], parent['names'] || {})}</span>#{SlackMarkup.link(card['parent_url'], 'Open parent message in Slack')}</span>)
        else
          context << SlackMarkup.link(card['parent_url'], 'Open parent message in Slack')
        end
      elsif card['reply_count'].to_i > 0
        context << %(<span class="redmine-slack-thread-label">#{card['reply_count'].to_i} thread replies</span>)
      end
      %(<span class="redmine-slack-link-card" style="--slack-card-color: #{color(project)}">#{context}#{header(card, time_formatter)}<span class="redmine-slack-link-card-text">#{text}</span>#{SlackMarkup.link(url, 'Slack')}</span>)
    end

    def render_links(html, issue, viewer, journal_id, state, time_formatter: nil, quoted_urls: [])
      fragment = Nokogiri::HTML.fragment(html.to_s)
      changed = false
      fragment.css('a[href]').each do |anchor|
        next if anchor.ancestors.any? { |node| %w[pre code a].include?(node.name) || node['class'].to_s.split.include?('redmine-slack-link-card') }
        url = anchor['href']
        next unless parse(url)
        next if quoted_urls.any? { |quoted| LinkQuotes.identity(quoted) == LinkQuotes.identity(url) }
        key = [issue.id, journal_id, url]
        unless state[:cards].key?(key)
          break if state[:count] >= 20 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > state[:deadline]
          state[:count] += 1
          state[:cards][key] = fetch(issue, viewer, url, journal_id: journal_id, api_cache: state[:api], deadline: state[:deadline])
        end
        card = state[:cards][key]
        next unless card
        replace_link_with_card(anchor, render_card(card, url, issue.project, time_formatter: time_formatter))
        changed = true
      end
      changed ? fragment.to_html : html
    end
  end
end
