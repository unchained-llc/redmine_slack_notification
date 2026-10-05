# frozen_string_literal: true
require 'cgi'
require 'uri'
require 'json'
require 'strscan'

module RedmineSlackNotification
  # Small, escaped renderer for Slack mrkdwn. Never interprets supplied HTML.
  module SlackMarkup
    module_function

    def escape(text)
      CGI.escapeHTML(text.to_s)
    end

    def decode(text)
      text.to_s.gsub(/&(?:amp|lt|gt);/) { |v| { '&amp;' => '&', '&lt;' => '<', '&gt;' => '>' }[v] }
    end

    def plain(text, emoji: true)
      value = decode(text)
      if emoji
        @emojis ||= JSON.parse(File.read(File.expand_path('../../vendor/slack_emoji.json', __dir__)))
        value = value.gsub(/:([a-z0-9_+\-]+):/) { |v| @emojis[Regexp.last_match(1)] || v }
      end
      escape(value)
    end

    def safe_url(text)
      value = decode(text)
      uri = URI.parse(value)
      return unless %w[http https mailto].include?(uri.scheme) && !uri.userinfo
      return if %w[http https].include?(uri.scheme) && uri.host.to_s.empty?
      value
    rescue URI::InvalidURIError
      nil
    end

    def link(url, label)
      %(<a href="#{escape(url)}" target="_blank" rel="noopener noreferrer">#{label}</a>)
    end

    def inline(text, names = {}, depth = 0)
      return plain(text) if depth > 8
      scanner = StringScanner.new(text)
      output = +''
      buffer = +''
      flush = -> { output << plain(buffer); buffer.clear }
      until scanner.eos?
        if scanner.scan(/`([^`\n]+)`/)
          value = scanner[1]; flush.call
          output << "<code>#{plain(value, emoji: false)}</code>"
        elsif scanner.scan(/<([^<>\n]+)>/)
          raw = scanner.matched; token = scanner[1]; flush.call
          target, label = token.split('|', 2)
          if (url = safe_url(target))
            output << link(url, plain(label || target))
          elsif target.start_with?('@', '#')
            id = target[1..-1]
            output << plain(target[0] + (names[id] || label || id))
          elsif target.start_with?('!')
            output << plain(label || target.sub(/^!/, '@'))
          else
            output << plain(raw)
          end
        elsif scanner.scan(/\[([^\]\n]+)\]\(([^\s)]+)\)/)
          raw = scanner.matched; label = scanner[1]; target = scanner[2]; flush.call
          url = safe_url(target)
          output << (url ? link(url, plain(label)) : plain(raw))
        elsif scanner.check(%r{https?://[^\s<>]+})
          raw = scanner.matched.sub(/[.,;!?)\]]+$/, '')
          if raw.empty?
            buffer << scanner.getch
          else
            scanner.pos += raw.bytesize; flush.call
            url = safe_url(raw)
            output << (url ? link(url, plain(raw, emoji: false)) : plain(raw))
          end
        else
          formatted = false
          [['**', 'strong'], ['~~', 'del'], ['*', 'strong'], ['_', 'em'], ['~', 'del']].each do |marker, tag|
            next unless scanner.rest.start_with?(marker)
            next if marker == '_' && scanner.pos > 0 && text.byteslice(0, scanner.pos).chars.last.to_s.match?(/[\p{L}\p{N}]/)
            ending = scanner.rest.index(marker, marker.length)
            next unless ending && ending > marker.length
            content = scanner.rest[marker.length...ending]
            next if content.match?(/^\s|\s$/) || content.include?("\n")
            flush.call
            output << "<#{tag}>#{inline(content, names, depth + 1)}</#{tag}>"
            scanner.pos += scanner.rest[0, ending + marker.length].bytesize
            formatted = true
            break
          end
          buffer << scanner.getch unless formatted
        end
      end
      flush.call
      output
    end

    def lines(text, names)
      text.split("\n", -1).map do |line|
        case line
        when /^(?:>|&gt;)\s?(.*)$/
          %(<span class="slack-markdown-quote">#{inline(Regexp.last_match(1), names)}</span>)
        when /^\s*(?:[-*•]|(\d+)\.)\s+(.+)$/
          number, body = Regexp.last_match(1), Regexp.last_match(2)
          %(<span class="slack-markdown-list-item">#{number ? number + '.' : '•'} #{inline(body, names)}</span>)
        when /^\#{1,6}\s+(.+)$/
          %(<strong class="slack-markdown-heading">#{inline(Regexp.last_match(1), names)}</strong>)
        else
          inline(line, names)
        end
      end.join("\n")
    end

    def render(text, names = {})
      text = text.to_s.gsub(/\r\n?/, "\n")
      output = +''; offset = 0
      text.to_enum(:scan, /```(?:[a-zA-Z0-9_+.-]+\n)?(.*?)```/m).each do
        match = Regexp.last_match
        output << lines(text[offset...match.begin(0)], names)
        output << %(<code class="slack-markdown-code-block">#{plain(match[1], emoji: false)}</code>)
        offset = match.end(0)
      end
      output << lines(text[offset..-1], names)
    end
  end
end
