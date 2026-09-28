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
      source.gsub!(/!\[[^\]\n]*\]\([^)\n]+\)/) do |image|
        image_references(image).any? ? protect_mrkdwn(image, protected) : image
      end
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

    # Only local Redmine attachment names are eligible for upload. Remote URLs
    # and paths must never be fetched on behalf of a notification.
    def image_references(value)
      value.to_s.scan(/!\[[^\]\n]*\]\(([^)\n]+\.(?:png|jpe?g|gif))\)/i).flatten.uniq.reject do |name|
        name.include?('/') || name.include?('\\') || name.include?(':')
      end
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
      return { 'text' => message } if blocks.nil? || blocks.empty?

      {
        'attachments' => [{
          'fallback' => message,
          'color' => '#6D5DFB',
          'blocks' => blocks
        }]
      }
    end

    def issue_payload(issue, actor:, action:, details: [], notes: nil)
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
        blocks.insert(2, *mrkdwn_sections('内容', description)) if description.present?
      elsif description.present? && description_changed
        blocks.insert(2, *mrkdwn_sections('概要', description))
      end

      if notes.to_s.strip.present?
        if ordered_list?(notes)
          blocks.insert(2, *mrkdwn_sections('コメント', notes.to_s))
        else
          blocks.insert(2, { 'type' => 'section', 'expand' => true, 'text' => { 'type' => 'mrkdwn', 'text' => "*コメント*\n> #{mrkdwn(notes.to_s).gsub("\n", "\n> ")}" } })
        end
      end

      changes = change_fields(issue, details)
      if changes.present?
        blocks << { 'type' => 'divider' }
        blocks << { 'type' => 'section', 'expand' => true, 'text' => { 'type' => 'mrkdwn', 'text' => '*変更内容*' } }
        blocks.concat(change_field_blocks(changes))
      end

      blocks << { 'type' => 'divider' }
      blocks << { 'type' => 'section', 'expand' => true, 'text' => { 'type' => 'mrkdwn', 'text' => '*メタ情報*' } }
      blocks << {
        'type' => 'section',
        'expand' => true,
        'fields' => metadata_fields(issue, actor).map { |label, value| field(label, value) }
      }

      payload(title, blocks: blocks)
    end

    def journal_payload(issue, actor:, notes:, details: [])
      combined_update = details.any?
      label = combined_update ? 'Issue updated' : 'Comment added'
      icon = combined_update ? '🔄' : '💬'
      fallback = "[#{issue.project.name}] #{actor&.name || '不明なユーザー'} updated #{issue.tracker.name} ##{issue.id}: #{issue.subject}"
      blocks = [
        section_text("#{icon} *#{label}*"),
        section_text("*<#{url('/issues/' + issue.id.to_s)}|##{issue.id} #{text(issue.subject)}>*"),
        { 'type' => 'divider' }
      ]
      blocks.concat(mrkdwn_sections('追加コメント', notes.to_s))
      changes = change_fields(issue, details)
      if changes.present?
        blocks << { 'type' => 'divider' }
        blocks << section_text('*変更内容*')
        blocks.concat(change_field_blocks(changes))
      end
      blocks.concat([
        { 'type' => 'divider' },
        section_text('*メタ情報*'),
        { 'type' => 'section', 'expand' => true, 'fields' => [
          field('プロジェクト', text(issue.project.name)),
          field('投稿者', text(actor&.name || '不明'))
        ] },
      ])
      payload(fallback, blocks: blocks)
    end

    def wiki_payload(content, project, actor:, action:)
      title = content.page.title
      label = event_label('Wiki page', action)
      fallback = "WAC: #{label} - #{title}"
      change_summary = content.comments.to_s.strip
      blocks = [
        section_text("#{event_icon(action, noun: 'Wiki page')} *#{label}*"),
        section_text("*<#{url('/projects/' + project.identifier.to_s + '/wiki/' + title.to_s)}|#{text(title)}>*")
      ]
      blocks.concat(mrkdwn_sections('変更内容', change_summary)) if change_summary.present?
      blocks.concat([
        { 'type' => 'divider' },
        section_text('*メタ情報*'),
        { 'type' => 'section', 'expand' => true, 'fields' => [
          field('プロジェクト', text(project.name)),
          field('更新者', text(actor&.name || '不明')),
          field('変更箇所', text(title))
        ] }
      ])
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
        blocks.insert(2, *(ordered_list?(notes) ? mrkdwn_sections('コメント', notes.to_s) : [section_text("*コメント*\n> #{mrkdwn(notes.to_s).gsub("\n", "\n> ")}")]))
      end
      payload(fallback, blocks: blocks)
    end

    def event_label(noun, action)
      return "#{noun} deleted" if action == 'deleted'
      return 'News updated' if noun == 'News'
      return 'Time entry updated' if noun == 'Time entry'
      return 'Version updated' if noun == 'Version'
      return 'Project updated' if noun == 'Project'

      "#{noun} #{action == 'created' ? 'created' : action == 'deleted' ? 'deleted' : 'updated'}"
    end

    def event_icon(action, noun: 'Issue')
      icons = {
        'Issue' => { 'created' => '🆕', 'updated' => '🔄', 'deleted' => '🗑️' },
        'Wiki page' => { 'created' => '📚', 'updated' => '✏️', 'deleted' => '🗑️' },
        'News' => { 'created' => '📰', 'updated' => '📰', 'deleted' => '🗑️' },
        'Time entry' => { 'created' => '⏱️', 'updated' => '⏱️', 'deleted' => '🗑️' },
        'Version' => { 'created' => '🏷️', 'updated' => '🏷️', 'deleted' => '🗑️' },
        'Project' => { 'updated' => '🗂️' }
      }
      icons.fetch(noun, {}).fetch(action, '🔧')
    end

    def header_block(value)
      { 'type' => 'header', 'text' => { 'type' => 'plain_text', 'text' => value.to_s.truncate(150), 'emoji' => true } }
    end

    def mrkdwn_sections(heading, value, limit: 2800)
      markdown = value.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
      markdown_text = "**#{heading}**\n\n#{markdown}"
      # Slack caps all Markdown blocks in one message at 12,000 characters.
      # Keep the existing section path for longer notes rather than dropping text.
      return [{ 'type' => 'markdown', 'text' => markdown_text }] if ordered_list?(markdown) && markdown_text.length <= 12_000

      chunks = value.to_s.each_char.each_slice(limit).map(&:join)
      chunks.each_with_index.map do |chunk, index|
        content = index.zero? ? "*#{heading}*\n#{mrkdwn(chunk)}" : mrkdwn(chunk)
        section_text(content)
      end
    end

    def ordered_list?(value)
      value.to_s.match?(/^[ \t]*\d+\.[ \t]+/)
    end

    def section_text(value)
      { 'type' => 'section', 'expand' => true, 'text' => { 'type' => 'mrkdwn', 'text' => value } }
    end

    def metadata_fields(issue, actor)
      [
        ['プロジェクト', text(issue.project.name)],
        ['更新者', text(actor&.name || '不明')],
        ['トラッカー', text(issue.tracker&.name || '未設定')],
        ['カテゴリー', text(issue.category&.name || '未設定')],
        ['優先度', text(issue.priority&.name || '未設定')]
      ]
    end

    def change_fields(issue, details)
      details.each_with_object([]) do |detail, changes|
        label = detail_label(detail)
        next unless label

        value = if detail.property == 'relation'
                  relation_id = detail.value.presence || detail.old_value
                  action = detail.value.present? ? '追加' : '削除'
                  "#{action}: #{relation_issue_link(relation_id)}"
                elsif detail.property == 'attachment'
                  action = detail.value.present? ? '追加' : '削除'
                  filename = detail.value.presence || detail.old_value
                  "#{action}: #{text(filename)}"
                elsif detail.property == 'attr' && detail.prop_key == 'description'
                  '変更あり'
                elsif detail.property == 'attr' && %w[parent_id child_id].include?(detail.prop_key)
                  "#{issue_reference(detail.old_value)} → #{issue_reference(detail.value)}"
                else
                  "#{detail_old_value(detail)} → #{detail_new_value(issue, detail)}"
                end
        changes << [label, value]
      end
    end

    def change_field_blocks(changes)
      changes.each_slice(10).map do |slice|
        { 'type' => 'section', 'expand' => true, 'fields' => slice.map { |label, value| field(label, value) } }
      end
    end

    def issue_reference(issue_id)
      issue_id.present? ? relation_issue_link(issue_id) : 'なし'
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
      return CustomField.find_by(id: detail.prop_key)&.name || detail.prop_key.to_s if detail.property == 'cf'
      return "関連チケット（#{relation_type_label(detail.prop_key)}）" if detail.property == 'relation'
      return '添付ファイル' if detail.property == 'attachment'

      {
        'status_id' => 'ステータス',
        'priority_id' => '優先度',
        'assigned_to_id' => '担当者',
        'category_id' => 'カテゴリー',
        'tracker_id' => 'トラッカー',
        'fixed_version_id' => '対象バージョン',
        'parent_id' => '親チケット',
        'child_id' => '子チケット',
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
      when 'category_id' then text(issue.category&.name || 'なし')
      when 'tracker_id' then text(issue.tracker&.name || 'なし')
      when 'fixed_version_id' then text(issue.fixed_version&.name || 'なし')
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
               when 'category_id' then IssueCategory.find_by(id: value)
               when 'tracker_id' then Tracker.find_by(id: value)
               when 'fixed_version_id' then Version.find_by(id: value)
               end
      record ? text(record.name) : text(value)
    end

    def detail_new_value(issue, detail)
      detail_value(issue, detail)
    end

    def relation_type_label(relation_type)
      {
        'relates' => '関連',
        'duplicates' => '重複',
        'duplicated' => '重複元',
        'blocks' => 'ブロック',
        'blocked' => 'ブロック元',
        'precedes' => '先行',
        'follows' => '後続',
        'copied_to' => 'コピー先',
        'copied_from' => 'コピー元'
      }.fetch(relation_type.to_s, relation_type.to_s)
    end

    def relation_issue_link(issue_id)
      related_issue = Issue.find_by(id: issue_id)
      return "##{text(issue_id)}" unless related_issue

      "<#{url('/issues/' + related_issue.id.to_s)}|##{related_issue.id} #{text(related_issue.subject)}>"
    end
  end
end
