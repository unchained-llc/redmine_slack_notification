# frozen_string_literal: true
require 'base64'
require 'json'
require 'securerandom'

module Slackmine
  # Quotes are plain text in existing description/notes columns, not a new table.
  module LinkQuotes
    PATTERN = /\[slack-quote:([A-Za-z0-9+\/=]+):([a-f0-9]{16})\]\r?\n(.*?)\r?\n\[\/slack-quote:\2\]/m
    module_function

    def resolved_text(card)
      names = card['names'] || {}
      card['text'].to_s.gsub(/<([@#])([A-Z0-9]+)(?:\|[^>]+)?>/) do |token|
        kind, id = Regexp.last_match(1), Regexp.last_match(2)
        name = names[id]
        name.to_s.empty? ? token : "<#{kind}#{id}|#{name.to_s.gsub(/[<>|\r\n]/, ' ')}>"
      end
    end

    def encode(card, url)
      data = card.merge('url' => url).reject { |key, _| key == 'text' }
      body = resolved_text(card)
      if card['parent']
        parent_text = resolved_text(card['parent'])[0, 500]
        data['parent'] = card['parent'].reject { |key, _| key == 'text' }
        data['parent_length'] = parent_text.length
        body = parent_text + "\n\n" + body
      end
      id = SecureRandom.hex(8)
      "[slack-quote:#{Base64.strict_encode64(JSON.generate(data))}:#{id}]\n#{body}\n[/slack-quote:#{id}]"
    end

    def decode(metadata, body)
      return if metadata.length > 32_768 || body.length > 12_000
      data = JSON.parse(Base64.strict_decode64(metadata))
      return unless data.is_a?(Hash) && LinkCards.parse(data['url'])
      return unless %w[author channel timestamp].all? { |key| data[key].is_a?(String) }
      Time.iso8601(data['timestamp'])
      return unless data['names'].nil? || valid_names?(data['names'])
      if data.key?('thread_image_ids')
        ids = data['thread_image_ids']
        return unless ids.is_a?(Array) && ids.size.between?(1, 10) && ids.uniq == ids &&
                      ids.all? { |id| id.is_a?(Integer) && id > 0 }
      end
      data['avatar'] = safe_avatar(data['avatar'])
      if data['parent_url']
        return unless LinkCards.parse(data['parent_url'])
      end
      if data['parent']
        parent = data['parent']
        length = data['parent_length']
        return unless parent.is_a?(Hash) && length.is_a?(Integer) && length.between?(0, 500) && body[length, 2] == "\n\n"
        return unless %w[author timestamp].all? { |key| parent[key].is_a?(String) }
        Time.iso8601(parent['timestamp'])
        return unless parent['names'].nil? || valid_names?(parent['names'])
        parent['avatar'] = safe_avatar(parent['avatar'])
        parent['text'] = body[0, length]
        data['text'] = body[(length + 2)..-1]
      else
        data['text'] = body
      end
      return if data['thread_reply'] && !data['parent_url']
      data
    rescue JSON::ParserError, ArgumentError, TypeError
      nil
    end

    def valid_names?(names)
      names.is_a?(Hash) && names.all? { |key, value| key.is_a?(String) && (value.nil? || value.is_a?(String)) }
    end

    def safe_avatar(value)
      url = SlackMarkup.safe_url(value.to_s)
      url if url && url.start_with?('https://')
    end

    def blocks(text)
      text.to_s.to_enum(:scan, PATTERN).each_with_object([]) do |_, result|
        match = Regexp.last_match
        card = decode(match[1], match[3])
        result << [match[0], card] if card
      end
    end

    def plain_source(text)
      source = text.to_s.dup
      if source.encoding == Encoding::ASCII_8BIT && source.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        source.force_encoding(Encoding::UTF_8)
      end
      source.gsub(PATTERN) do |raw|
        match = Regexp.last_match
        card = decode(match[1], match[3])
        next raw unless card
        parent = card['parent']
        prefix = parent ? "Thread parent: #{parent['author']}\n#{parent['text']}\n\nThread reply\n" : ''
        "Slack — #{card['author']} · ##{card['channel']} · #{card['timestamp']}\n#{card['url']}\n#{prefix}#{card['text']}"
      end
    end

    def editable_source?(issue, viewer)
      return false unless viewer && viewer.logged?
      issue.new_record? ? viewer.allowed_to?(:add_issues, issue.project) : issue.visible?(viewer)
    end

    def import(text, issue, viewer)
      return text unless text.to_s.match?(/\.slack\.com\/archives\//i) && editable_source?(issue, viewer)
      existing = blocks(text)
      scan_text = text.to_s.dup
      existing.each { |raw, _| scan_text = scan_text.gsub(raw, '') }
      # Use Redmine's own formatter to exclude inline/fenced code in Markdown or Textile.
      html = Redmine::WikiFormatting.to_html(Setting.text_formatting, scan_text)
      links = Nokogiri::HTML.fragment(html).css('a[href]').reject do |anchor|
        anchor.ancestors.any? { |node| %w[pre code].include?(node.name) }
      end.map { |anchor| anchor['href'] }.select { |url| LinkCards.parse(url) }
      imported = existing.map { |_, card| identity(card['url']) }
      cache = {}
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      quotes = []
      links.uniq.first(20).each do |url|
        key = identity(url)
        next if imported.include?(key)
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        card = LinkCards.fetch_for_project(issue.project, url, api_cache: cache, deadline: deadline)
        next unless card
        # Notification replies already have their parent comment in Redmine.
        if Thread.current[:slackmine_thread_comment]
          card = card.reject { |key, _| %w[thread_reply parent parent_url].include?(key) }
          images = Thread.current[:slackmine_thread_images]
          if images && !images[:ids].empty? && identity(images[:url]) == identity(url)
            card = card.merge('thread_image_ids' => images[:ids])
          end
        end
        quote = encode(card, url)
        next if blocks(quote).empty?
        quotes << quote
        imported << key
      end
      quotes.empty? ? text : text.to_s.rstrip + "\n\n" + quotes.join("\n\n")
    end

    def identity(url)
      target = LinkCards.parse(url)
      target && target.values_at('host', 'channel', 'ts')
    end
  end
end
