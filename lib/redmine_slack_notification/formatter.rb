# frozen_string_literal: true

module RedmineSlackNotification
  module Formatter
    module_function

    MARKDOWN_LIMIT = 12_000

    def escape_markdown(value)
      value.to_s.gsub(/[\\`*_{}\[\]()#+\-.!<>|&]/) { |character| "\\#{character}" }
    end

    def normalize_markdown(value)
      value.to_s.gsub("\r\n", "\n").gsub("\r", "\n").sub(/\A\n+/, '').sub(/\n+\z/, '')
    end

    # Only local Redmine attachment names are eligible for upload. Remote URLs
    # and paths must never be fetched on behalf of a notification.
    def image_references(value)
      value.to_s.scan(/!\[[^\]\n]*\]\(([^)\n]+\.(?:png|jpe?g|gif))\)/i).flatten.uniq.reject do |name|
        name.include?('/') || name.include?('\\') || name.include?(':')
      end
    end

    def url(path)
      base = "#{Setting.protocol}://#{Setting.host_name}".sub(%r{/$}, '')
      base.empty? ? path : "#{base}#{path}"
    end

    def markdown_link(label, target)
      "[#{escape_markdown(label)}](#{target})"
    end

    def user_mention(user)
      return escape_markdown('不明なユーザー') if user.blank?

      mapping = RedmineSlackNotification.user_mapping
      slack_id = mapping[user.login.to_s] || mapping[user.mail.to_s]
      slack_id.present? ? "<@#{slack_id}>" : escape_markdown(user.name)
    end

    def payload(message, markdown:, source_url:)
      content = normalize_markdown(markdown)
      if content.length > MARKDOWN_LIMIT
        suffix = "\n\n… #{markdown_link('全文を WAC で確認', source_url)}"
        excerpt = content[0, MARKDOWN_LIMIT - suffix.length - 6]
        excerpt = excerpt[0, excerpt.rindex("\n")] if excerpt.include?("\n")
        excerpt += "\n```" if excerpt.scan(/^[ \t]*```/).length.odd?
        content = excerpt.rstrip + suffix
      end
      { 'text' => message, 'blocks' => [{ 'type' => 'markdown', 'text' => content }] }
    end

    def heading(label, subject, target, icon)
      "#{icon} **#{label}**\n#{markdown_link(subject, target)}"
    end

    def section(label, body)
      "**#{label}**\n\n#{normalize_markdown(body)}"
    end

    def field_section(label, fields)
      return nil if fields.empty?

      section(label, fields.map { |name, value| "- **#{escape_markdown(name)}:** #{value}" }.join("\n"))
    end

    def issue_payload(issue, actor:, action:, details: [], notes: nil)
      label = event_label('Issue', action)
      issue_url = url("/issues/#{issue.id}")
      title = "[#{issue.project.name}] #{actor&.name || '不明なユーザー'} #{action} #{issue.tracker.name} ##{issue.id}: #{issue.subject}"
      parts = [heading(label, "##{issue.id} #{issue.subject}", issue_url, event_icon(action, noun: 'Issue'))]

      description_changed = details.any? { |detail| detail.property == 'attr' && detail.prop_key == 'description' }
      description = issue.description.to_s.strip.sub(/\A[ \t]*\#{1,6}[ \t]+[^\n]+\n?/, '').strip
      if description.present? && (action == 'created' || description_changed)
        parts << section(action == 'created' ? '内容' : '概要', description)
      end
      parts << section('コメント', notes) if notes.to_s.strip.present?
      parts << field_section('変更内容', change_fields(issue, details)) if details.any?
      parts << field_section('メタ情報', metadata_fields(issue, actor))
      payload(title, markdown: parts.compact.join("\n\n"), source_url: issue_url)
    end

    def journal_payload(issue, actor:, notes:, details: [])
      combined_update = details.any?
      label = combined_update ? 'Issue updated' : 'Comment added'
      icon = combined_update ? '🔄' : '💬'
      issue_url = url("/issues/#{issue.id}")
      fallback = "[#{issue.project.name}] #{actor&.name || '不明なユーザー'} updated #{issue.tracker.name} ##{issue.id}: #{issue.subject}"
      parts = [heading(label, "##{issue.id} #{issue.subject}", issue_url, icon)]
      parts << section('追加コメント', notes) if notes.to_s.strip.present?
      parts << field_section('変更内容', change_fields(issue, details)) if combined_update
      parts << field_section('メタ情報', [
        ['プロジェクト', escape_markdown(issue.project.name)],
        ['投稿者', escape_markdown(actor&.name || '不明')]
      ])
      payload(fallback, markdown: parts.compact.join("\n\n"), source_url: issue_url)
    end

    def wiki_payload(content, project, actor:, action:)
      title = content.page.title
      label = event_label('Wiki page', action)
      fallback = "WAC: #{label} - #{title}"
      path = "/projects/#{project.identifier}/wiki/#{URI::DEFAULT_PARSER.escape(title.to_s, /[^A-Za-z0-9\-._~]/)}"
      wiki_url = url(path)
      parts = [heading(label, title, wiki_url, event_icon(action, noun: 'Wiki page'))]
      change_summary = content.comments.to_s.strip
      parts << section('変更内容', change_summary) if change_summary.present?
      parts << field_section('メタ情報', [
        ['プロジェクト', escape_markdown(project.name)],
        ['更新者', escape_markdown(actor&.name || '不明')],
        ['変更箇所', escape_markdown(title)]
      ])
      payload(fallback, markdown: parts.compact.join("\n\n"), source_url: wiki_url)
    end

    def generic_payload(noun:, action:, subject:, url:, project:, actor:, fields: [], summary: nil, notes: nil)
      label = event_label(noun, action)
      fallback = "WAC: #{label} - #{subject}"
      parts = [heading(label, subject, url, event_icon(action, noun: noun))]
      parts << section('概要', summary.to_s.truncate(1200)) if summary.to_s.strip.present?
      parts << section('コメント', notes) if notes.to_s.strip.present?
      metadata = [['プロジェクト', project.name], ['更新者', actor&.name || '不明']] + fields
      parts << field_section('メタ情報', metadata.map { |name, value| [name, escape_markdown(value)] })
      payload(fallback, markdown: parts.compact.join("\n\n"), source_url: url)
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

    def metadata_fields(issue, actor)
      [
        ['プロジェクト', escape_markdown(issue.project.name)],
        ['更新者', escape_markdown(actor&.name || '不明')],
        ['トラッカー', escape_markdown(issue.tracker&.name || '未設定')],
        ['カテゴリー', escape_markdown(issue.category&.name || '未設定')],
        ['優先度', escape_markdown(issue.priority&.name || '未設定')]
      ]
    end

    def change_fields(issue, details)
      details.filter_map do |detail|
        label = detail_label(detail)
        next unless label

        if detail.property == 'relation'
          relation_id = detail.value.presence || detail.old_value
          action = detail.value.present? ? '追加' : '削除'
          [label, "#{action}: #{relation_issue_link(relation_id)}"]
        elsif detail.property == 'attr' && detail.prop_key == 'description'
          [label, '変更あり']
        else
          [label, "#{detail_old_value(detail)} → #{detail_value(issue, detail)}"]
        end
      end.uniq { |label, _value| label }
    end

    def detail_label(detail)
      return detail.prop_key if detail.property == 'cf'
      return "関連チケット（#{relation_type_label(detail.prop_key)}）" if detail.property == 'relation'

      {
        'status_id' => 'ステータス',
        'priority_id' => '優先度',
        'assigned_to_id' => '担当者',
        'category_id' => 'カテゴリー',
        'tracker_id' => 'トラッカー',
        'subject' => '題名',
        'description' => '説明',
        'start_date' => '開始日',
        'due_date' => '期日'
      }[detail.prop_key]
    end

    def detail_value(issue, detail)
      return escape_markdown(detail.value.presence || 'なし') unless detail.property == 'attr'

      case detail.prop_key
      when 'status_id' then escape_markdown(issue.status&.name || 'なし')
      when 'priority_id' then escape_markdown(issue.priority&.name || 'なし')
      when 'assigned_to_id' then user_mention(issue.assigned_to)
      when 'category_id' then escape_markdown(issue.category&.name || 'なし')
      when 'tracker_id' then escape_markdown(issue.tracker&.name || 'なし')
      else escape_markdown(detail.value.presence || 'なし')
      end
    end

    def detail_old_value(detail)
      value = detail.old_value.presence || 'なし'
      return escape_markdown(value) unless detail.property == 'attr'

      record = case detail.prop_key
               when 'status_id' then IssueStatus.find_by(id: value)
               when 'priority_id' then IssuePriority.find_by(id: value)
               when 'assigned_to_id' then User.find_by(id: value)
               when 'category_id' then IssueCategory.find_by(id: value)
               when 'tracker_id' then Tracker.find_by(id: value)
               end
      escape_markdown(record ? record.name : value)
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
      return "##{escape_markdown(issue_id)}" unless related_issue

      markdown_link("##{related_issue.id} #{related_issue.subject}", url("/issues/#{related_issue.id}"))
    end
  end
end
