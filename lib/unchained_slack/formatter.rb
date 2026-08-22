# frozen_string_literal: true

module UnchainedSlack
  module Formatter
    module_function

    def text(value)
      value.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end

    # Converts the Markdown commonly used in Redmine descriptions/comments
    # into Slack mrkdwn without introducing interactive elements.
    def mrkdwn(value)
      protected = []
      source = value.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
      source.gsub!(/```\w*\n.*?```/m) { protect_mrkdwn(Regexp.last_match(0), protected) }
      source.gsub!(/`[^`]+`/) { protect_mrkdwn(Regexp.last_match(0), protected) }
      source = text(source)
      source.gsub!(/\[([^\]]+)\]\(([^)]+)\)/) { "<#{Regexp.last_match(2)}|#{Regexp.last_match(1)}>" }
      source.gsub!(/^[ \t]*\#{1,6}[ \t]+([^\r\n]+)$/) { "*#{Regexp.last_match(1).strip}*" }
      source.gsub!(/\*\*(.+?)\*\*/, '*\1*')
      source.gsub!(/__([^_]+)__/, '*\1*')
      source.gsub!(/~~(.+?)~~/, '~\1~')
      source.gsub!(/^\s*[-*+]\s+/, '• ')
      source.gsub!(/^\s*\d+\.\s+/, '• ')
      source.gsub!(/\n{3,}/, "\n\n")
      restore_mrkdwn(source, protected)
    end

    def protect_mrkdwn(value, protected)
      index = protected.length
      protected << value
      "\u0000MRK#{index}\u0000"
    end

    def restore_mrkdwn(value, protected)
      value.gsub(/\u0000MRK(\d+)\u0000/) { protected[Regexp.last_match(1).to_i] }
    end

    def url(path)
      base = "#{Setting.protocol}://#{Setting.host_name}".sub(%r{/$}, '')
      base.empty? ? path : "#{base}#{path}"
    end

    def user_mention(user)
      return '不明なユーザー' if user.blank?

      mapping = UnchainedSlack.user_mapping
      slack_id = mapping[user.login.to_s] || mapping[user.mail.to_s]
      slack_id.present? ? "<@#{text(slack_id)}>" : text(user.name)
    end

    def issue_title(issue)
      "#{text(issue.tracker.name)} ##{issue.id}: #{text(issue.subject)}"
    end

    def issue_link(issue)
      "<#{url("/issues/#{issue.id}")}|#{issue_title(issue)}>"
    end

    def payload(message, blocks: nil)
      return { 'text' => message } if blocks.blank?

      {
        'attachments' => [{
          'fallback' => message,
          'color' => '#6D5DFB',
          'blocks' => blocks
        }]
      }
    end

    def issue_payload(issue, actor:, action:, details: [], notes: nil)
      title = "[Agent] #{user_mention(actor)} #{action} #{issue_link(issue)}"
      blocks = [
        {
          'type' => 'section',
          'text' => { 'type' => 'mrkdwn', 'text' => "*#{user_mention(actor)}* #{action} #{issue_link(issue)}" }
        },
        {
          'type' => 'context',
          'elements' => [{ 'type' => 'mrkdwn', 'text' => "#{text(issue.project.name)}  •  Issue通知" }]
        },
        { 'type' => 'divider' }
      ]

      description = issue.description.to_s.strip
      description = description.sub(/\A[ \t]*\#{1,6}[ \t]+[^\n]+\n?/, '').strip
      if description.present?
        blocks << {
          'type' => 'section',
          'text' => { 'type' => 'mrkdwn', 'text' => "*概要*\n#{mrkdwn(description.truncate(1200))}" }
        }
      end

      fields = issue_fields(issue, details)
      blocks << {
        'type' => 'section',
        'text' => { 'type' => 'mrkdwn', 'text' => '*現在の状態*' },
        'fields' => fields.map { |label, value| field(label, value) }
      } if fields.any?

      changes = change_lines(details)
      if changes.any?
        blocks << {
          'type' => 'section',
          'text' => { 'type' => 'mrkdwn', 'text' => "*変更内容*\n#{changes.join("\n")}" }
        }
      end

      if notes.to_s.strip.present?
        blocks << {
          'type' => 'section',
          'text' => { 'type' => 'mrkdwn', 'text' => "*コメント*\n> #{mrkdwn(notes.to_s).gsub("\n", "\n> ")}" }
        }
      end
      payload(title, blocks: blocks)
    end

    def issue_fields(issue, details)
      current = [
        ['ステータス', issue.status&.name],
        ['優先度', issue.priority&.name],
        ['担当者', user_mention(issue.assigned_to)]
      ].compact
      changed = details.filter_map do |detail|
        label = detail_label(detail)
        value = detail_value(issue, detail)
        [label, value] if label && value.present?
      end
      (current + changed).uniq { |label, _value| label }
    end

    def field(label, value)
      { 'type' => 'mrkdwn', 'text' => "*#{text(label)}*\n#{value}" }
    end

    def change_lines(details)
      details.filter_map do |detail|
        label = detail_label(detail)
        next unless label

        old_value = text(detail.old_value.presence || 'なし')
        new_value = text(detail.value.presence || 'なし')
        "• *#{text(label)}*: #{old_value} → #{new_value}"
      end
    end

    def detail_label(detail)
      return detail.prop_key if detail.property == 'cf'

      {
        'status_id' => 'ステータス',
        'priority_id' => '優先度',
        'assigned_to_id' => '担当者',
        'tracker_id' => 'トラッカー',
        'subject' => '題名',
        'description' => '説明',
        'start_date' => '開始日',
        'due_date' => '期日'
      }[detail.prop_key]
    end

    def detail_value(issue, detail)
      return text(detail.value.presence || 'なし') unless detail.property == 'attr'

      case detail.prop_key
      when 'status_id' then text(issue.status&.name || 'なし')
      when 'priority_id' then text(issue.priority&.name || 'なし')
      when 'assigned_to_id' then user_mention(issue.assigned_to)
      when 'tracker_id' then text(issue.tracker&.name || 'なし')
      else text(detail.value.presence || 'なし')
      end
    end
  end
end
