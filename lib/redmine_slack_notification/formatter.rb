# frozen_string_literal: true

module RedmineSlackNotification
  module Formatter
    BODY_DIFF_MAX_CHARS = 6_000
    BODY_DIFF_MAX_LINE_CHARS = 400
    BODY_DIFF_CONTEXT_LINES = 2
    BODY_DIFF_LCS_CELLS = 40_000
    DUE_REMINDER_COLORS = { 'overdue' => '#D92D20', 'today' => '#F79009' }.freeze
    EVENT_NOUN_KEYS = {
      'Issue' => 'issue', 'Comment' => 'comment', 'Wiki page' => 'wiki', 'News' => 'news',
      'News comment' => 'news_comment', 'Time entry' => 'time_entry', 'Version' => 'version',
      'Project' => 'project'
    }.freeze
    DETAIL_FIELD_KEYS = {
      'status_id' => 'status', 'priority_id' => 'priority', 'assigned_to_id' => 'assignee',
      'category_id' => 'category', 'tracker_id' => 'tracker', 'fixed_version_id' => 'target_version',
      'parent_id' => 'parent_issue', 'child_id' => 'child_issue', 'subject' => 'subject',
      'description' => 'description', 'start_date' => 'start_date', 'due_date' => 'due_date',
      'done_ratio' => 'done_ratio', 'estimated_hours' => 'estimated_hours'
    }.freeze
    ISSUE_OPTIONAL_METADATA_KEYS = %w[status assignee author target_version start_date due_date
                                      estimated_hours done_ratio parent_issue children relations
                                      custom_fields attachments watchers].freeze
    DEFAULT_MESSAGES = {
      'work_objects' => { 'product_name' => 'Redmine' },
      'thread_notifications' => {
        'added_header' => '%{product_name} #%{id}: New comment',
        'updated_header' => '%{product_name} #%{id}: Comment updated',
        'deleted_header' => '%{product_name} #%{id}: Comment deleted'
      },
      'thread_comments' => {
        'saved' => '✅ Comment added to Redmine #%{id}.',
        'restricted' => '⚠️ Could not add the comment. Check the user mapping, Issue permissions and state, and text length.'
      },
      'events' => {
        'issue' => { 'created' => 'Issue created', 'updated' => 'Issue updated', 'deleted' => 'Issue deleted' },
        'comment' => { 'added' => 'Comment added', 'updated' => 'Comment updated', 'deleted' => 'Comment deleted' },
        'wiki' => { 'created' => 'Wiki page created', 'updated' => 'Wiki page updated', 'deleted' => 'Wiki page deleted' },
        'news' => { 'created' => 'News created', 'updated' => 'News updated', 'deleted' => 'News deleted' },
        'news_comment' => { 'added' => 'News comment added', 'updated' => 'News comment updated', 'deleted' => 'News comment deleted' },
        'time_entry' => { 'created' => 'Time entry created', 'updated' => 'Time entry updated', 'deleted' => 'Time entry deleted' },
        'version' => { 'created' => 'Version created', 'updated' => 'Version updated', 'deleted' => 'Version deleted' },
        'project' => { 'updated' => 'Project updated' }
      },
      'icons' => {
        'issue' => { 'created' => '🆕', 'updated' => '🔄', 'deleted' => '🗑️' },
        'comment' => { 'added' => '💬', 'updated' => '💬', 'deleted' => '🗑️' },
        'wiki' => { 'created' => '📚', 'updated' => '✏️', 'deleted' => '🗑️' },
        'news' => { 'created' => '📰', 'updated' => '📰', 'deleted' => '🗑️' },
        'news_comment' => { 'added' => '💬', 'updated' => '✏️', 'deleted' => '🗑️' },
        'time_entry' => { 'created' => '⏱️', 'updated' => '⏱️', 'deleted' => '🗑️' },
        'version' => { 'created' => '🏷️', 'updated' => '🏷️', 'deleted' => '🗑️' },
        'project' => { 'updated' => '🗂️' }
      },
      'sections' => {
        'content' => 'Content', 'comment' => 'Comment', 'summary' => 'Summary', 'changes' => 'Changes',
        'metadata' => 'Metadata', 'added_comment' => 'Added comment', 'updated_comment' => 'Updated comment',
        'description' => 'Description', 'body' => 'Body'
      },
      'fields' => {
        'project' => 'Project', 'updater' => 'Updated by', 'poster' => 'Posted by', 'tracker' => 'Tracker',
        'category' => 'Category', 'priority' => 'Priority', 'status' => 'Status', 'assignee' => 'Assignee',
        'target_version' => 'Target version', 'parent_issue' => 'Parent issue', 'child_issue' => 'Child issue',
        'subject' => 'Subject', 'description' => 'Description', 'start_date' => 'Start date', 'due_date' => 'Due date',
        'attachment' => 'Attachment', 'relation' => 'Related issue (%{type})', 'location' => 'Changed location',
        'hours' => 'Hours', 'spent_on' => 'Spent on', 'author' => 'Author',
        'estimated_hours' => 'Estimated hours', 'done_ratio' => 'Done ratio',
        'children' => 'Child issues', 'relations' => 'Related issues',
        'attachments' => 'Attachments', 'watchers' => 'Watchers',
        'custom_fields' => 'Custom fields'
      },
      'relations' => {
        'relates' => 'Related', 'duplicates' => 'Duplicates', 'duplicated' => 'Duplicated by', 'blocks' => 'Blocks',
        'blocked' => 'Blocked by', 'precedes' => 'Precedes', 'follows' => 'Follows', 'copied_to' => 'Copied to',
        'copied_from' => 'Copied from'
      },
      'values' => { 'unknown_user' => 'Unknown user', 'unknown' => 'Unknown', 'unset' => 'Not set',
                    'none' => 'None', 'empty' => '(empty)', 'added' => 'Added', 'removed' => 'Removed',
                    'created' => 'created', 'updated' => 'updated', 'deleted' => 'deleted' },
      'diff' => { 'heading' => '%{label} diff', 'omitted' => 'Diff truncated. See the linked page for the full text.' },
      'images' => { 'preparing' => 'Preparing image', 'alt' => 'Image', 'link_label' => 'Image: %{name}' },
      'templates' => {
        'issue_updated_header' => '%{actor} *%{event}*',
        'issue_fallback' => '[%{project}] %{actor} %{action} %{tracker} #%{id}: %{subject}',
        'journal_fallback' => '[%{project}] %{actor} %{event} %{tracker} #%{id}: %{subject}',
        'generic_fallback' => '%{event} - %{subject}'
      },
      'due_reminders' => {
        'part_suffix' => ' (%{part}/%{total_parts})',
        'fallback' => '期日リマインダー%{suffix}: %{count}件（期限超過%{overdue_count}件・本日期日%{today_count}件）',
        'title' => '📋 *期日リマインダー %{count}件%{suffix}*',
        'overdue_label' => '🚨 期限超過',
        'today_label' => '⏰ 本日期日',
        'upcoming_label' => '📅 期日が近い課題',
        'group_fallback' => '%{label}: %{count}件',
        'group_heading' => '*%{label}（%{count}件）*',
        'group_continued' => '*%{label}（続き）*',
        'overdue_timing' => '%{days}日超過',
        'upcoming_timing' => '残り%{days}日',
        'timing_suffix' => ' · %{timing}',
        'issue_line' => '• <%{url}|#%{id} %{subject}> · %{project}%{timing}'
      }
    }.freeze

    module_function

    def message(*path)
      default = DEFAULT_MESSAGES.dig(*path)
      configured = RedmineSlackNotification.effective_config['messages']
      path.each do |key|
        configured = configured.is_a?(Hash) ? configured[key] : nil
      end
      configured.is_a?(String) && !configured.empty? ? configured : default
    end

    def link_issue_reference(value, issue_id)
      # Preserve existing Slack links and mentions instead of nesting links.
      value.to_s.split(/(<[^>]*>)/).map do |part|
        part.start_with?('<') ? part : part.gsub(/##{issue_id}(?!\d)/) { "<#{url('/issues/' + issue_id.to_s)}|##{issue_id}>" }
      end.join
    end

    def interpolate(template, values, fallback: nil)
      template % values
    rescue KeyError, ArgumentError
      fallback ? fallback % values : template
    end

    def section_label(key)
      message('sections', key)
    end

    def field_label(key)
      message('fields', key)
    end

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
      return message('values', 'unknown_user') if user.nil?

      mapping = RedmineSlackNotification.user_mapping
      slack_id = mapping[user.login.to_s] || mapping[user.mail.to_s]
      slack_id = RedmineSlackNotification.slack_user_id_for_name(user.login) if (slack_id == false || slack_id.to_s.strip.empty?) && user.is_a?(User)
      slack_id == false || slack_id.to_s.strip.empty? ? text(user.name) : "<@#{text(slack_id)}>"
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
          'color' => attachment_color,
          'blocks' => blocks
        }]
      }
    end

    def attachment_color
      color = RedmineSlackNotification.effective_config.dig('slack', 'attachment_color')
      color.is_a?(String) && color.match?(/\A#[0-9a-fA-F]{6}\z/) ? color : '#6D5DFB'
    end

    def due_reminder_color(group)
      settings = RedmineSlackNotification.effective_config['due_reminders']
      colors = settings.is_a?(Hash) ? settings['colors'] : nil
      color = colors[group] if colors.is_a?(Hash)
      return color if color.is_a?(String) && color.match?(/\A#[0-9a-fA-F]{6}\z/)

      DUE_REMINDER_COLORS.fetch(group) { attachment_color }
    end

    def due_digest_payload(issues, today: Date.current, part: 1, total_parts: 1)
      overdue, rest = issues.partition { |issue| issue.due_date < today }
      current, upcoming = rest.partition { |issue| issue.due_date == today }
      suffix = total_parts > 1 ? due_message('part_suffix', part: part, total_parts: total_parts) : ''
      fallback = due_message('fallback', suffix: suffix, count: issues.size,
                                        overdue_count: overdue.size, today_count: current.size)
      attachments = [
        due_digest_attachment(message('due_reminders', 'overdue_label'), overdue, today, due_reminder_color('overdue')),
        due_digest_attachment(message('due_reminders', 'today_label'), current, today, due_reminder_color('today')),
        due_digest_attachment(message('due_reminders', 'upcoming_label'), upcoming, today, due_reminder_color('upcoming'))
      ].compact
      {
        'text' => fallback,
        'blocks' => [section_text(due_message('title', count: issues.size, suffix: suffix))],
        'attachments' => attachments
      }
    end

    def due_message(key, **values)
      interpolate(message('due_reminders', key), values,
                  fallback: DEFAULT_MESSAGES.dig('due_reminders', key))
    end

    def due_digest_attachment(label, issues, today, color)
      return if issues.empty?

      {
        'fallback' => due_message('group_fallback', label: label, count: issues.size),
        'color' => color,
        'blocks' => due_digest_group_blocks(label, issues, today)
      }
    end

    def due_digest_group_blocks(label, issues, today)
      return [] if issues.empty?

      heading = due_message('group_heading', label: label, count: issues.size)
      sections = []
      content = heading
      issues.each do |issue|
        line = due_digest_line(issue, today)
        if content.length + line.length + 1 > 2_900
          sections << section_text(content)
          content = due_message('group_continued', label: label)
        end
        content = "#{content}\n#{line}"
      end
      sections << section_text(content)
      sections
    end

    def due_digest_line(issue, today)
      subject = text(issue.subject.to_s.gsub(/[|\r\n]/, ' ').strip[0, 120])
      project = text(issue.project.name.to_s.gsub(/[|\r\n]/, ' ').strip[0, 60])
      days_left = (issue.due_date - today).to_i
      timing = if days_left.negative?
                 due_message('overdue_timing', days: -days_left)
               elsif days_left.positive?
                 due_message('upcoming_timing', days: days_left)
               end
      suffix = timing ? due_message('timing_suffix', timing: timing) : ''
      line = due_message('issue_line', url: url("/issues/#{issue.id}"), id: issue.id,
                                       subject: subject, project: project, timing: suffix)
      link_issue_reference(line, issue.id)
    end

    def issue_payload(issue, **options)
      RedmineSlackNotification.with_project(issue.project) { build_issue_payload(issue, **options) }
    end

    def build_issue_payload(issue, actor:, action:, details: [], notes: nil)
      event_label = event_label('Issue', action)
      title = interpolate(message('templates', 'issue_fallback'),
                          { project: issue.project.name, actor: actor&.name || message('values', 'unknown_user'),
                            action: message('values', action), tracker: issue.tracker.name, id: issue.id, subject: issue.subject },
                          fallback: DEFAULT_MESSAGES.dig('templates', 'issue_fallback'))
      blocks = [
        section_text("#{event_icon(action, noun: 'Issue')} #{issue_heading(action, actor, event_label)}"),
        section_text("*<#{url('/issues/' + issue.id.to_s)}|##{issue.id} #{text(issue.subject)}>*")
      ]

      description_detail = details.find { |detail| detail.property == 'attr' && detail.prop_key == 'description' }
      description = issue.description.to_s.strip
      description = description.sub(/\A[ \t]*\#{1,6}[ \t]+[^\n]+\n?/, '').strip
      if action == 'created'
        blocks.insert(2, *mrkdwn_sections(section_label('content'), description)) if description.present?
      end

      if notes.to_s.strip.present?
        if ordered_list?(notes)
          blocks.insert(2, *mrkdwn_sections(section_label('comment'), notes.to_s))
        else
          blocks.insert(2, { 'type' => 'section', 'expand' => true, 'text' => { 'type' => 'mrkdwn', 'text' => "*#{text(section_label('comment'))}*\n> #{mrkdwn(notes.to_s).gsub("\n", "\n> ")}" } })
        end
      end
      if action != 'created' && description_detail
        blocks.insert(2, *updated_body_blocks(section_label('description'), description_detail.old_value, description_detail.value,
                                              blocks: blocks, full_heading: section_label('summary'), full_text: description,
                                              diff_kind: :issue_description))
      end

      changes = change_fields(issue, visible_issue_changes(details))
      if changes.present?
        blocks << { 'type' => 'divider' }
        blocks << section_text("*#{text(section_label('changes'))}*")
        blocks.concat(change_field_blocks(changes))
      end

      if %w[created updated].include?(action)
        append_metadata(blocks, 'issue', metadata_fields(issue, actor, action), action: action)
      end

      result = payload(title, blocks: blocks)
      action == 'deleted' ? result : with_issue_work_object(result, issue, actor: actor, action: action)
    end

    def journal_payload(issue, **options)
      RedmineSlackNotification.with_project(issue.project) { build_journal_payload(issue, **options) }
    end

    def build_journal_payload(issue, actor:, notes:, details: [], comment_action: 'added', previous_notes: nil)
      combined_update = details.any?
      label = combined_update ? event_label('Issue', 'updated') : message('events', 'comment', comment_action)
      icon = combined_update ? event_icon('updated', noun: 'Issue') : event_icon(comment_action, noun: 'Comment')
      fallback = interpolate(message('templates', 'journal_fallback'),
                             { project: issue.project.name, actor: actor&.name || message('values', 'unknown_user'),
                               event: label.downcase, tracker: issue.tracker.name, id: issue.id, subject: issue.subject },
                             fallback: DEFAULT_MESSAGES.dig('templates', 'journal_fallback'))
      heading = combined_update ? issue_heading('updated', actor, label) : "*#{text(label)}*"
      blocks = [
        section_text("#{icon} #{heading}"),
        section_text("*<#{url('/issues/' + issue.id.to_s)}|##{issue.id} #{text(issue.subject)}>*"),
        { 'type' => 'divider' }
      ]
      if comment_action == 'deleted' && !previous_notes.nil?
        blocks.concat(body_diff_blocks(section_label('comment'), previous_notes, '', blocks: blocks))
      elsif comment_action == 'updated' && !previous_notes.nil?
        blocks.concat(updated_body_blocks(section_label('comment'), previous_notes, notes, blocks: blocks,
                                          full_heading: section_label('updated_comment'), diff_kind: :issue_comment))
        if RedmineSlackNotification.body_diff_enabled?(:issue_comment)
          image_references(notes).each { |name| blocks << section_text("![](#{name})") }
        end
      elsif notes.to_s.strip.present?
        heading = section_label(comment_action == 'updated' ? 'updated_comment' : 'added_comment')
        blocks.concat(mrkdwn_sections(heading, notes.to_s))
      end

      description_detail = details.find { |detail| detail.property == 'attr' && detail.prop_key == 'description' }
      if description_detail
        blocks.concat(updated_body_blocks(section_label('description'), description_detail.old_value, description_detail.value,
                                          blocks: blocks, full_heading: section_label('summary'), diff_kind: :issue_description))
      end
      changes = change_fields(issue, visible_issue_changes(details))
      if changes.present?
        blocks << { 'type' => 'divider' }
        blocks << section_text("*#{text(section_label('changes'))}*")
        blocks.concat(change_field_blocks(changes))
      end
      append_metadata(blocks, 'issue', metadata_fields(issue, actor, 'updated'), action: 'updated') if combined_update
      result = with_issue_work_object(payload(fallback, blocks: blocks), issue, actor: actor, action: 'updated')
      if !combined_update && RedmineSlackNotification.effective_config.dig('slack', 'comment_notifications_in_threads') == true
        body = comment_action == 'added' ? mrkdwn_sections(nil, notes.to_s) : blocks.drop(3)
        header_key = "#{comment_action}_header"
        header = interpolate(message('thread_notifications', header_key),
          { product_name: message('work_objects', 'product_name'), id: issue.id,
            actor: actor&.name || message('values', 'unknown_user'), subject: issue.subject.to_s },
          fallback: DEFAULT_MESSAGES.dig('thread_notifications', header_key))
        result['_redmine_thread_comment_payload'] = {
          # Only the heading is top-level text; the body is rendered once.
          'text' => link_issue_reference(text(header), issue.id),
          'attachments' => [{ 'fallback' => notes.to_s, 'blocks' => body }],
          'unfurl_links' => false, 'unfurl_media' => false
        }
      end
      result
    end

    # Work Object metadata augments the existing event card; it never contains
    # comments or description bodies. Hidden Issue fields stay hidden here too.
    def with_issue_work_object(result, issue, actor:, action:)
      return result unless RedmineSlackNotification.effective_config.dig('slack', 'work_object_previews') == true
      return result if issue.is_private?

      attributes = {
        'title' => { 'text' => issue.subject.to_s },
        'display_id' => "##{issue.id}",
        'display_type' => issue.tracker.name.to_s,
        'product_name' => message('work_objects', 'product_name')
      }
      fields = {}
      {
        'status' => ['status', -> { issue.status&.name }],
        'priority' => ['priority', -> { issue.priority&.name }],
        'due_date' => ['due_date', -> { issue.due_date&.iso8601 }]
      }.each do |key, (setting, getter)|
        next unless metadata_enabled?('issue', setting, action: action)

        value = getter.call.to_s
        next if value.empty?

        fields[key] = { 'value' => value }
        fields[key]['type'] = 'slack#/types/date' if key == 'due_date'
      end
      { 'assignee' => ['assignee', :assigned_to], 'created_by' => ['author', :author] }.each do |key, (setting, accessor)|
        next unless metadata_enabled?('issue', setting, action: action)

        user = issue.public_send(accessor)
        next unless user

        fields[key] = work_object_user_field(user)
      end
      custom_fields = []
      {
        'project' => -> { issue.project.name },
        'tracker' => -> { issue.tracker.name },
        'category' => -> { issue.category&.name },
        'updater' => -> { actor&.name },
        'target_version' => -> { issue.fixed_version&.name }
      }.each do |key, getter|
        next unless metadata_enabled?('issue', key, action: action)

        value = getter.call.to_s
        next if value.empty?

        custom_fields << { 'key' => key, 'label' => field_label(key), 'type' => 'string', 'value' => value }
      end
      issue_url = url("/issues/#{issue.id}")
      entity_payload = { 'attributes' => attributes, 'fields' => fields }
      entity_payload['custom_fields'] = custom_fields unless custom_fields.empty?
      result.merge(
        'text' => link_issue_reference(result.dig('attachments', 0, 'fallback'), issue.id),
        'metadata' => { 'entities' => [{
          'entity_type' => 'slack#/entities/task',
          'url' => issue_url,
          # Slack restricts IDs to [0-9a-zA-Z\-_:!/=]. URLs contain dots (and
          # potentially other forbidden characters), so use an opaque stable ID.
          'external_ref' => { 'id' => Digest::SHA256.hexdigest(issue_url), 'type' => 'redmine_issue' },
          'entity_payload' => entity_payload
        }] }
      )
    end

    def issue_work_object_details(issue)
      fields = {}
      { 'status' => issue.status&.name, 'priority' => issue.priority&.name }.each do |key, value|
        fields[key] = { 'value' => value.to_s } unless value.to_s.empty?
      end
      { 'assignee' => issue.assigned_to, 'created_by' => issue.author }.each do |key, user|
        fields[key] = work_object_user_field(user) if user
      end
      fields['due_date'] = { 'type' => 'slack#/types/date', 'value' => issue.due_date.iso8601 } if issue.due_date
      { 'date_created' => issue.created_on, 'date_updated' => issue.updated_on }.each do |key, value|
        fields[key] = { 'type' => 'slack#/types/timestamp', 'value' => value.to_i } if value
      end
      description = issue.description.to_s.strip
      fields['description'] = { 'value' => description[0, 10_000], 'format' => 'markdown' } unless description.empty?
      issue_url = url("/issues/#{issue.id}")
      {
        'entity_type' => 'slack#/entities/task', 'url' => issue_url,
        'external_ref' => { 'id' => Digest::SHA256.hexdigest(issue_url), 'type' => 'redmine_issue' },
        'entity_payload' => {
          'attributes' => { 'title' => { 'text' => issue.subject.to_s }, 'display_id' => "##{issue.id}",
                            'display_type' => issue.tracker.name.to_s, 'product_name' => message('work_objects', 'product_name') },
          'fields' => fields,
          'custom_fields' => [{ 'key' => 'project', 'label' => field_label('project'), 'type' => 'string', 'value' => issue.project.name.to_s }]
        }
      }
    end

    def work_object_user_field(user)
      slack_id = RedmineSlackNotification.slack_user_id_for(user)
      identity = slack_id ? { 'user_id' => slack_id } : { 'text' => user.name.to_s }
      { 'type' => 'slack#/types/user', 'user' => identity }
    end

    def wiki_payload(content, project, **options)
      RedmineSlackNotification.with_project(project) { build_wiki_payload(content, project, **options) }
    end

    def build_wiki_payload(content, project, actor:, action:, body_diff: nil)
      title = content.page.title
      label = event_label('Wiki page', action)
      fallback = interpolate(message('templates', 'generic_fallback'), { event: label, subject: title },
                             fallback: DEFAULT_MESSAGES.dig('templates', 'generic_fallback'))
      change_summary = content.comments.to_s.strip
      blocks = [
        section_text("#{event_icon(action, noun: 'Wiki page')} *#{label}*"),
        section_text("*<#{url('/projects/' + project.identifier.to_s + '/wiki/' + title.to_s)}|#{text(title)}>*")
      ]
      blocks.concat(mrkdwn_sections(section_label('changes'), change_summary)) if change_summary.present?
      blocks.concat(updated_body_blocks(section_label('body'), *body_diff, blocks: blocks,
                                        diff_kind: :wiki_body)) if body_diff
      append_metadata(blocks, 'wiki', [
        ['project', text(project.name)],
        ['updater', text(actor&.name || message('values', 'unknown'))],
        ['location', text(title)]
      ])
      payload(fallback, blocks: blocks)
    end

    def generic_payload(project:, **options)
      RedmineSlackNotification.with_project(project) { build_generic_payload(project: project, **options) }
    end

    def build_generic_payload(noun:, action:, subject:, url:, project:, actor:, fields: [], summary: nil, notes: nil, body_diff: nil, body_diff_label: nil, body_full_label: nil)
      label = event_label(noun, action)
      fallback = interpolate(message('templates', 'generic_fallback'), { event: label, subject: subject },
                             fallback: DEFAULT_MESSAGES.dig('templates', 'generic_fallback'))
      body_diff_label = section_label(body_diff_label.to_s) if body_diff_label.is_a?(Symbol)
      body_full_label = section_label(body_full_label.to_s) if body_full_label.is_a?(Symbol)
      body_diff_label ||= section_label('body')
      body_full_label ||= section_label('summary')
      blocks = [
        section_text("#{event_icon(action, noun: noun)} *#{label}*"),
        section_text("*<#{url}|#{text(subject)}>*")
      ]
      if body_diff
        body_blocks = if action == 'deleted'
                        body_diff_blocks(body_diff_label, *body_diff, blocks: blocks)
                      else
                        diff_kind = noun == 'News' ? :news_description : noun == 'News comment' ? :news_comment : nil
                        updated_body_blocks(body_diff_label, *body_diff, blocks: blocks,
                                            full_heading: body_full_label, diff_kind: diff_kind)
                      end
        blocks.concat(body_blocks)
      elsif summary.to_s.strip.present?
        blocks << section_text("*#{text(section_label('summary'))}*\n#{mrkdwn(summary.to_s.truncate(1200))}")
      end
      metadata = [['project', text(project.name)], ['updater', text(actor&.name || message('values', 'unknown'))]] + fields
      append_metadata(blocks, event_key(noun), metadata)
      if notes.to_s.strip.present?
        blocks.insert(2, *(ordered_list?(notes) ? mrkdwn_sections(section_label('comment'), notes.to_s) : [section_text("*#{text(section_label('comment'))}*\n> #{mrkdwn(notes.to_s).gsub("\n", "\n> ")}")]))
      end
      payload(fallback, blocks: blocks)
    end

    def event_label(noun, action)
      key = event_key(noun)
      configured = message('events', key, action) if key
      return configured if configured

      "#{noun} #{action}"
    end

    def issue_heading(action, actor, label)
      return "*#{text(label)}*" unless action == 'updated'

      values = { actor: text(actor&.name || message('values', 'unknown_user')), event: text(label) }
      interpolate(message('templates', 'issue_updated_header'), values,
                  fallback: DEFAULT_MESSAGES.dig('templates', 'issue_updated_header'))
    end

    def event_icon(action, noun: 'Issue')
      message('icons', event_key(noun), action) || '🔧'
    end

    def event_key(noun)
      EVENT_NOUN_KEYS[noun]
    end

    def header_block(value)
      { 'type' => 'header', 'text' => { 'type' => 'plain_text', 'text' => value.to_s.truncate(150), 'emoji' => true } }
    end

    def mrkdwn_sections(heading, value, limit: 2800)
      markdown = value.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
      markdown_text = heading ? "**#{text(heading)}**\n\n#{markdown}" : markdown
      # Slack caps all Markdown blocks in one message at 12,000 characters.
      # Keep the existing section path for longer notes rather than dropping text.
      return [{ 'type' => 'markdown', 'text' => markdown_text }] if ordered_list?(markdown) && markdown_text.length <= 12_000

      chunks = value.to_s.each_char.each_slice(limit).map(&:join)
      chunks.each_with_index.map do |chunk, index|
        content = index.zero? && heading ? "*#{text(heading)}*\n#{mrkdwn(chunk)}" : mrkdwn(chunk)
        section_text(content)
      end
    end

    def ordered_list?(value)
      value.to_s.match?(/^[ \t]*\d+\.[ \t]+/)
    end

    def updated_body_blocks(label, before, after, blocks: [], full_heading: label, full_text: nil, diff_kind: nil)
      return body_diff_blocks(label, before, after, blocks: blocks) if RedmineSlackNotification.body_diff_enabled?(diff_kind)
      return [] if body_lines(before) == body_lines(after)

      content = full_text.nil? ? after.to_s : full_text.to_s
      mrkdwn_sections(full_heading, content.strip.empty? ? message('values', 'empty') : content)
    end

    def body_diff_blocks(label, before, after, blocks: [])
      old_lines = body_lines(before)
      new_lines = body_lines(after)
      return [] if old_lines == new_lines

      operations = body_diff_operations(old_lines, new_lines)
      shown = Array.new(operations.length, false)
      operations.each_with_index do |(kind, _line), index|
        next if kind == :same

        ((index - BODY_DIFF_CONTEXT_LINES)..(index + BODY_DIFF_CONTEXT_LINES)).each do |nearby|
          shown[nearby] = true if nearby >= 0 && nearby < shown.length
        end
      end

      markdown_used = blocks.sum { |block| block['type'] == 'markdown' ? block['text'].to_s.length : 0 }
      markdown_available = 12_000 - markdown_used - 100
      use_markdown = markdown_available >= 500
      max_chars = use_markdown ? [BODY_DIFF_MAX_CHARS, markdown_available].min : 2_800
      diff_heading = interpolate(message('diff', 'heading'), { label: label }, fallback: DEFAULT_MESSAGES.dig('diff', 'heading'))
      heading = use_markdown ? "**#{text(diff_heading)}**\n\n" : "*#{text(diff_heading)}*\n"
      body = +''
      previous = -1
      shortened = false
      operations.each_with_index do |(kind, line), index|
        next unless shown[index]

        marker = { same: '  ', removed: '- ', added: '+ ' }.fetch(kind)
        if line.length > BODY_DIFF_MAX_LINE_CHARS
          line = "#{line[0, BODY_DIFF_MAX_LINE_CHARS]}…"
          shortened = true
        end
        addition = +''
        addition << "  …\n" if index > previous + 1
        addition << "#{marker}#{line}\n"
        if body.length + addition.length > max_chars - heading.length - 150
          shortened = true
          break
        end
        body << addition
        previous = index
      end
      body << "  … (#{message('diff', 'omitted')})" if shortened
      longest_ticks = body.scan(/`+/).map(&:length).max || 0
      fence = '`' * [3, longest_ticks + 1].max
      opening = use_markdown ? "#{fence}diff" : fence
      content = "#{heading}#{opening}\n#{body.rstrip}\n#{fence}"
      use_markdown ? [{ 'type' => 'markdown', 'text' => content }] : [section_text(content)]
    end

    def body_lines(value)
      source = value.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
      source.empty? ? [] : source.split("\n", -1)
    end

    def body_diff_operations(before, after)
      prefix = 0
      prefix += 1 while prefix < before.length && prefix < after.length && before[prefix] == after[prefix]
      suffix = 0
      while suffix < before.length - prefix && suffix < after.length - prefix &&
            before[-suffix - 1] == after[-suffix - 1]
        suffix += 1
      end

      old_middle = before[prefix, before.length - prefix - suffix]
      new_middle = after[prefix, after.length - prefix - suffix]
      middle = if old_middle.length * new_middle.length > BODY_DIFF_LCS_CELLS
                 old_middle.map { |line| [:removed, line] } + new_middle.map { |line| [:added, line] }
               else
                 body_diff_lcs(old_middle, new_middle)
               end
      before.first(prefix).map { |line| [:same, line] } + middle +
        (suffix.zero? ? [] : before.last(suffix).map { |line| [:same, line] })
    end

    def body_diff_lcs(before, after)
      lengths = Array.new(before.length + 1) { Array.new(after.length + 1, 0) }
      (before.length - 1).downto(0) do |old_index|
        (after.length - 1).downto(0) do |new_index|
          lengths[old_index][new_index] = if before[old_index] == after[new_index]
                                             lengths[old_index + 1][new_index + 1] + 1
                                           else
                                             [lengths[old_index + 1][new_index], lengths[old_index][new_index + 1]].max
                                           end
        end
      end

      operations = []
      old_index = 0
      new_index = 0
      while old_index < before.length || new_index < after.length
        if old_index < before.length && new_index < after.length && before[old_index] == after[new_index]
          operations << [:same, before[old_index]]
          old_index += 1
          new_index += 1
        elsif old_index < before.length &&
              (new_index == after.length || lengths[old_index + 1][new_index] >= lengths[old_index][new_index + 1])
          operations << [:removed, before[old_index]]
          old_index += 1
        else
          operations << [:added, after[new_index]]
          new_index += 1
        end
      end
      operations
    end

    def section_text(value)
      { 'type' => 'section', 'expand' => true, 'text' => { 'type' => 'mrkdwn', 'text' => value } }
    end

    def metadata_enabled?(kind, key, action: nil)
      slack = RedmineSlackNotification.effective_config['slack']
      settings = slack['metadata'] if slack.is_a?(Hash)
      return false if settings == false

      group = settings[kind] if settings.is_a?(Hash)
      return false if group == false

      if kind == 'issue'
        legacy = group.is_a?(Hash) && (group.key?('created') || group.key?('updated'))
        group = group[action] if legacy
        return false if group == false
        return true if group == true

        default = (!legacy || action == 'created') && !ISSUE_OPTIONAL_METADATA_KEYS.include?(key)
        value = group[key] if group.is_a?(Hash)
        return default if value.nil?

        return value == true || (key == 'custom_fields' && value.is_a?(Hash))
      end

      !group.is_a?(Hash) || group[key] != false
    end

    def append_metadata(blocks, kind, entries, action: nil)
      shown = entries.each_with_object([]) do |(key, value, label), visible|
        visible << field(label || field_label(key), value) if metadata_enabled?(kind, key, action: action)
      end
      return if shown.empty?

      blocks << { 'type' => 'divider' } unless blocks.last&.dig('type') == 'divider'
      blocks << section_text("*#{text(section_label('metadata'))}*")
      shown.each_slice(10) do |slice|
        blocks << { 'type' => 'section', 'expand' => true, 'fields' => slice }
      end
    end

    def metadata_fields(issue, actor, action)
      fields = [
        ['project', text(issue.project.name)],
        ['updater', text(actor&.name || message('values', 'unknown'))],
        ['tracker', text(issue.tracker&.name || message('values', 'unset'))],
        ['category', text(issue.category&.name || message('values', 'unset'))],
        ['priority', text(issue.priority&.name || message('values', 'unset'))]
      ]
      optional = {
        'status' => -> { text(issue.status&.name) },
        'assignee' => -> { issue.assigned_to && user_mention(issue.assigned_to) },
        'author' => -> { text(issue.author&.name) },
        'target_version' => -> { text(issue.fixed_version&.name) },
        'start_date' => -> { text(issue.start_date) },
        'due_date' => -> { text(issue.due_date) },
        'estimated_hours' => -> { text(issue.estimated_hours) },
        'done_ratio' => -> { issue.done_ratio && "#{issue.done_ratio}%" },
        'parent_issue' => -> { issue.parent && issue_link(issue.parent) },
        'children' => -> { issue_list(issue.children) },
        'relations' => -> { issue_relations(issue) },
        'attachments' => -> { issue.attachments.map { |attachment| text(attachment.filename) }.join(', ') },
        'watchers' => -> { issue.visible_watcher_users.map { |watcher| text(watcher.name) }.join(', ') }
      }
      optional.each do |key, getter|
        next unless metadata_enabled?('issue', key, action: action)
        accessor = { 'parent_issue' => :parent, 'target_version' => :fixed_version,
                     'assignee' => :assigned_to, 'watchers' => :visible_watcher_users }.fetch(key, key)
        next unless issue.respond_to?(accessor)

        value = getter.call
        fallback = %w[children relations attachments watchers].include?(key) ? 'none' : 'unset'
        fields << [key, value.to_s.empty? ? text(message('values', fallback)) : value.to_s[0, 1800]]
      end
      if issue.respond_to?(:visible_custom_field_values) && metadata_enabled?('issue', 'custom_fields', action: action)
        count = fields.length
        issue.visible_custom_field_values.each do |custom_value|
          custom_field = custom_value.custom_field
          next unless custom_field && custom_field_enabled?(custom_field.id, action: action)

          value = Array(custom_value.value).reject { |item| item.to_s.empty? }.join(', ')
          fields << ['custom_fields', value.empty? ? text(message('values', 'unset')) : text(value[0, 1800]), custom_field.name]
        end
        group = issue_metadata_group(action)
        setting = group['custom_fields'] if group.is_a?(Hash)
        setting = true if group == true
        fields << ['custom_fields', text(message('values', 'none'))] if setting == true && fields.length == count
      end
      fields
    end

    def issue_link(related)
      return nil if related.respond_to?(:is_private?) && related.is_private?

      "<#{url('/issues/' + related.id.to_s)}|##{related.id} #{text(related.subject)}>"
    end

    def issue_list(issues)
      links = Array(issues).first(20).map { |related| issue_link(related) }.compact
      links.join(', ')
    end

    def issue_relations(issue)
      Array(issue.relations).first(20).map do |relation|
        related = relation.other_issue(issue)
        link = issue_link(related) if related
        "#{text(relation_type_label(relation.relation_type_for(issue)))}: #{link}" if link
      end.compact.join("\n")
    end

    def issue_metadata_group(action)
      group = RedmineSlackNotification.effective_config.dig('slack', 'metadata', 'issue')
      return group[action] if group.is_a?(Hash) && (group.key?('created') || group.key?('updated'))

      group
    end

    def custom_field_enabled?(id, action: 'updated')
      group = issue_metadata_group(action)
      settings = group['custom_fields'] if group.is_a?(Hash)
      return settings != false unless settings.is_a?(Hash)

      settings.fetch(id.to_s, settings.fetch('default', true)) != false
    end

    def visible_issue_changes(details)
      return details if RedmineSlackNotification.effective_config.dig('slack', 'issue_changes_when_hidden') != false

      details.select do |detail|
        key = if detail.property == 'cf'
                'custom_fields'
              elsif detail.property == 'relation'
                'relations'
              elsif detail.property == 'attachment'
                'attachments'
              elsif detail.property == 'attr'
                { 'child_id' => 'children' }.fetch(detail.prop_key.to_s, DETAIL_FIELD_KEYS[detail.prop_key.to_s])
              end
        key.nil? || %w[subject description].include?(key) ||
          (metadata_enabled?('issue', key, action: 'updated') &&
           (key != 'custom_fields' || custom_field_enabled?(detail.prop_key)))
      end
    end

    def change_fields(issue, details)
      details.each_with_object([]) do |detail, changes|
        label = detail_label(detail)
        next unless label

        value = if detail.property == 'relation'
                  relation_id = detail.value.presence || detail.old_value
                  action = message('values', detail.value.present? ? 'added' : 'removed')
                  "#{action}: #{relation_issue_link(relation_id)}"
                elsif detail.property == 'attachment'
                  action = message('values', detail.value.present? ? 'added' : 'removed')
                  filename = detail.value.presence || detail.old_value
                  "#{action}: #{text(filename)}"
                elsif detail.property == 'attr' && detail.prop_key == 'description'
                  next
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
      issue_id.present? ? relation_issue_link(issue_id) : message('values', 'none')
    end

    def issue_fields(issue, details)
      current = [
        [field_label('status'), issue.status&.name],
        [field_label('priority'), issue.priority&.name],
        [field_label('assignee'), user_mention(issue.assigned_to)]
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

        old_value = text(detail.old_value.presence || message('values', 'none'))
        new_value = text(detail.value.presence || message('values', 'none'))
        "• *#{text(label)}*: #{old_value} → #{new_value}"
      end
    end

    def detail_label(detail)
      return CustomField.find_by(id: detail.prop_key)&.name || detail.prop_key.to_s if detail.property == 'cf'
      return interpolate(field_label('relation'), { type: relation_type_label(detail.prop_key) },
                         fallback: DEFAULT_MESSAGES.dig('fields', 'relation')) if detail.property == 'relation'
      return field_label('attachment') if detail.property == 'attachment'

      key = DETAIL_FIELD_KEYS[detail.prop_key]
      field_label(key) if key
    end

    def detail_value(issue, detail)
      return text(detail.value.presence || message('values', 'none')) unless detail.property == 'attr'

      case detail.prop_key
      when 'status_id' then text(issue.status&.name || message('values', 'none'))
      when 'priority_id' then text(issue.priority&.name || message('values', 'none'))
      when 'assigned_to_id' then user_mention(issue.assigned_to)
      when 'category_id' then text(issue.category&.name || message('values', 'none'))
      when 'tracker_id' then text(issue.tracker&.name || message('values', 'none'))
      when 'fixed_version_id' then text(issue.fixed_version&.name || message('values', 'none'))
      else text(detail.value.presence || message('values', 'none'))
      end
    end

    def detail_old_value(detail)
      value = detail.old_value.presence || message('values', 'none')
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
      message('relations', relation_type.to_s) || relation_type.to_s
    end

    def relation_issue_link(issue_id)
      related_issue = Issue.find_by(id: issue_id)
      unless related_issue
        id = issue_id.to_s
        return "##{text(id)}" unless id.match?(/\A[1-9]\d*\z/)
        return "<#{url('/issues/' + id)}|##{id}>"
      end

      "<#{url('/issues/' + related_issue.id.to_s)}|##{related_issue.id} #{text(related_issue.subject)}>"
    end
  end
end
