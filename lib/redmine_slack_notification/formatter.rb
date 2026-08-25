# frozen_string_literal: true

module RedmineSlackNotification
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
      source.gsub!(/```[ \t]*\w*[ \t]*\n.*?```/m) { protect_mrkdwn(Regexp.last_match(0), protected) }
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
      "@@MRK#{index}@@"
    end

    def restore_mrkdwn(value, protected)
      value.gsub(/@@MRK(\d+)@@/) { protected[Regexp.last_match(1).to_i] }
    end

    def url(path)
      base = "#{Setting.protocol}://#{Setting.host_name}".sub(%r{/$}, '')
      base.empty? ? path : "#{base}#{path}"
    end

    def user_mention(user)
      return '不明なユーザー' if user.blank?

      mapping = RedmineSlackNotification.user_mapping
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

    def issue_payload(issue, actor:, action:, details: [], notes: nil, occurred_at: nil)
      event_label = event_label('Issue', action)
      title = "[#{issue.project.name}] #{actor&.name || '不明なユーザー'} #{action} #{issue.tracker.name} ##{issue.id}: #{issue.subject}"
      blocks = [
        section_text("#{event_icon(action, noun: 'Issue')} *#{event_label}*"),
        section_text("*<#{url('/issues/' + issue.id.to_s)}|##{issue.id} #{text(issue.subject)}>*")
      ]

      description_changed = details.any? { |detail| detail.property == 'attr' && detail.prop_key == 'description' }
      description = issue.description.to_s.strip
      description = description.sub(/\A[ \t]*\#{1,6}[ \t]+[^\n]+\n?/, '').strip
      if action == 'created'
        blocks.insert(2, section_text('新しいチケットが作成されました。'))
        blocks.insert(3, *mrkdwn_sections('内容', description)) if description.present?
      elsif description.present? && description_changed
        blocks.insert(2, *mrkdwn_sections('概要', description))
      end

      if notes.to_s.strip.present?
        blocks.insert(2, { 'type' => 'section', 'expand' => true, 'text' => { 'type' => 'mrkdwn', 'text' => "*コメント*\n> #{mrkdwn(notes.to_s).gsub("\n", "\n> ")}" } })
      end

      changes = change_fields(issue, details)
      if changes.any?
        blocks << { 'type' => 'divider' }
        blocks << { 'type' => 'section', 'expand' => true, 'text' => { 'type' => 'mrkdwn', 'text' => '*変更内容*' } }
        blocks << { 'type' => 'section', 'expand' => true, 'fields' => changes.map { |label, value| field(label, value) } }
      end

      blocks << { 'type' => 'divider' }
      blocks << { 'type' => 'section', 'expand' => true, 'text' => { 'type' => 'mrkdwn', 'text' => '*メタ情報*' } }
      blocks << {
        'type' => 'section',
        'expand' => true,
        'fields' => metadata_fields(issue, actor, occurred_at).map { |label, value| field(label, value) }
      }

      payload(title, blocks: blocks)
    end

    def journal_payload(issue, actor:, notes:, occurred_at:, details: [])
      combined_update = details.any?
      label = combined_update ? 'Issue updated' : 'Comment added'
      icon = combined_update ? '🔄' : '💬'
      fallback = "[#{issue.project.name}] #{actor&.name || '不明なユーザー'} updated #{issue.tracker.name} ##{issue.id}: #{issue.subject}"
      blocks = [
        section_text("#{icon} *#{label}*"),
        section_text("*<#{url('/issues/' + issue.id.to_s)}|##{issue.id} #{text(issue.subject)}>*"),
        section_text(combined_update ? 'Issueが更新されました。' : 'コメントが追加されました。'),
        { 'type' => 'divider' }
      ]
      blocks.concat(mrkdwn_sections('追加コメント', notes.to_s))
      if details.any?
        blocks << { 'type' => 'divider' }
        blocks << section_text('*変更内容*')
        blocks << { 'type' => 'section', 'expand' => true, 'fields' => change_fields(issue, details).map { |label, value| field(label, value) } }
      end
      blocks.concat([
        { 'type' => 'divider' },
        section_text('*メタ情報*'),
        { 'type' => 'section', 'expand' => true, 'fields' => [
          field('プロジェクト', text(issue.project.name)),
          field('投稿者', text(actor&.name || '不明')),
          field('投稿日時', occurred_at&.strftime('%Y/%m/%d %H:%M') || '不明')
        ] },
      ])
      payload(fallback, blocks: blocks)
    end

    def wiki_payload(content, project, actor:, action:)
      title = content.page.title
      label = event_label('Wiki page', action)
      fallback = "WAC: #{label} - #{title}"
      changed_at = content.updated_on || Time.current
      change_summary = content.comments.to_s.strip.presence || (action == 'created' ? 'Wikiページが作成されました。' : 'Wikiページの内容が更新されました。')
      blocks = [
        section_text("#{event_icon(action, noun: 'Wiki page')} *#{label}*"),
        section_text("*<#{url('/projects/' + project.identifier.to_s + '/wiki/' + title.to_s)}|#{text(title)}>*"),
        section_text("Wikiページが#{action == 'created' ? '作成' : '更新'}されました。"),
        { 'type' => 'divider' },
        section_text("*変更内容*\n#{mrkdwn(change_summary)}"),
        { 'type' => 'divider' },
        section_text('*メタ情報*'),
        { 'type' => 'section', 'expand' => true, 'fields' => [
          field('プロジェクト', text(project.name)),
          field('更新者', text(actor&.name || '不明')),
          field('更新日時', changed_at.strftime('%Y/%m/%d %H:%M')),
          field('変更箇所', text(title))
        ] },
      ]
      payload(fallback, blocks: blocks)
    end

    def generic_payload(noun:, action:, subject:, url:, project:, actor:, fields: [], summary: nil, notes: nil)
      label = event_label(noun, action)
      fallback = "WAC: #{label} - #{subject}"
      blocks = [
        section_text("#{event_icon(action, noun: noun)} *#{label}*"),
        section_text("*<#{url}|#{text(subject)}>*")
      ]
      blocks << section_text("*概要*\n#{mrkdwn(summary.to_s.truncate(1200))}") if summary.to_s.strip.present?
      blocks << { 'type' => 'divider' }
      blocks << { 'type' => 'section', 'expand' => true, 'text' => { 'type' => 'mrkdwn', 'text' => '*メタ情報*' } }
      metadata = [['プロジェクト', text(project.name)], ['更新者', text(actor&.name || '不明')]] + fields
      blocks << { 'type' => 'section', 'expand' => true, 'fields' => metadata.map { |key, value| field(key, value) } }
      if notes.to_s.strip.present?
        blocks.insert(2, section_text("*コメント*\n> #{mrkdwn(notes.to_s).gsub("\n", "\n> ")}"))
      end
      payload(fallback, blocks: blocks)
    end

    def event_label(noun, action)
      return 'News updated' if noun == 'News'
      return 'Time entry updated' if noun == 'Time entry'
      return 'Version updated' if noun == 'Version'
      return 'Project updated' if noun == 'Project'

      "#{noun} #{action == 'created' ? 'created' : action == 'deleted' ? 'deleted' : 'updated'}"
    end

    def event_icon(action, noun: 'Issue')
      icons = {
        'Issue' => { 'created' => '🆕', 'updated' => '🔄', 'deleted' => '🗑️' },
        'Wiki page' => { 'created' => '📚', 'updated' => '✏️' },
        'News' => { 'created' => '📰', 'updated' => '📰' },
        'Time entry' => { 'created' => '⏱️', 'updated' => '⏱️' },
        'Version' => { 'created' => '🏷️', 'updated' => '🏷️' },
        'Project' => { 'updated' => '🗂️' }
      }
      icons.fetch(noun, {}).fetch(action, '🔧')
    end

    def header_block(value)
      { 'type' => 'header', 'text' => { 'type' => 'plain_text', 'text' => value.to_s.truncate(150), 'emoji' => true } }
    end

    def mrkdwn_sections(heading, value, limit: 2800)
      chunks = value.to_s.each_char.each_slice(limit).map(&:join)
      chunks.each_with_index.map do |chunk, index|
        content = index.zero? ? "*#{heading}*\n#{mrkdwn(chunk)}" : mrkdwn(chunk)
        section_text(content)
      end
    end

    def section_text(value)
      { 'type' => 'section', 'expand' => true, 'text' => { 'type' => 'mrkdwn', 'text' => value } }
    end

    def metadata_fields(issue, actor, occurred_at)
      timestamp = occurred_at || issue.updated_on
      [
        ['プロジェクト', text(issue.project.name)],
        ['更新者', text(actor&.name || '不明')],
        ['トラッカー', text(issue.tracker&.name || '未設定')],
        ['更新日時', timestamp&.strftime('%Y/%m/%d %H:%M') || '不明'],
        ['優先度', text(issue.priority&.name || '未設定')]
      ]
    end

    def change_fields(issue, details)
      details.filter_map do |detail|
        label = detail_label(detail)
        next unless label

        if detail.property == 'attr' && detail.prop_key == 'description'
          [label, '変更あり']
        else
          [label, "#{detail_old_value(detail)} → #{detail_new_value(issue, detail)}"]
        end
      end.uniq { |label, _value| label }
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

    def detail_old_value(detail)
      value = detail.old_value.presence || 'なし'
      return text(value) unless detail.property == 'attr'

      record = case detail.prop_key
               when 'status_id' then IssueStatus.find_by(id: value)
               when 'priority_id' then IssuePriority.find_by(id: value)
               when 'assigned_to_id' then User.find_by(id: value)
               when 'tracker_id' then Tracker.find_by(id: value)
               end
      record ? text(record.name) : text(value)
    end

    def detail_new_value(issue, detail)
      detail_value(issue, detail)
    end
  end
end
