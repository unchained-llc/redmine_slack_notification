# frozen_string_literal: true

require_relative 'formatter'

module RedmineSlackNotification
  module JournalPatch
    def self.included(base)

      base.after_create_commit :notify_slack_journal_created
      base.after_update_commit :notify_slack_journal_comment_changed
    end

    private

    def notify_slack_journal_created
      return if Thread.current[:redmine_slack_thread_comment]
      issue = journalized
      return unless issue.is_a?(Issue)
      return if issue.is_private? || private_notes?

      comment_enabled = !notes.to_s.strip.empty? && RedmineSlackNotification.event_enabled?(issue.project, 'comment_added')
      enabled_details = details.select do |detail|
        RedmineSlackNotification.event_enabled?(issue.project, slack_event_for_detail(detail))
      end
      return unless comment_enabled || enabled_details.any?

      payload = if comment_enabled
                  RedmineSlackNotification::Formatter.journal_payload(
                    issue, actor: user, notes: notes,
                    details: enabled_details
                  )
                else
                  RedmineSlackNotification::Formatter.issue_payload(
                    issue, actor: user, action: 'updated', details: enabled_details
                  )
                end
      if comment_enabled && enabled_details.empty? &&
         RedmineSlackNotification.effective_config(issue.project).dig('slack', 'comment_notifications_in_threads') == true
        payload = payload.merge('_redmine_comment_issue_id' => issue.id)
      end
      RedmineSlackNotification.enqueue(
        payload,
        project: issue.project,
        event: enabled_details.any? ? slack_event_for_detail(enabled_details.first) : 'comment_added',
        image_names: comment_enabled ? RedmineSlackNotification::Formatter.image_references(notes) : [],
        journal_id: comment_enabled ? id : nil
      )
    end

    def notify_slack_journal_comment_changed
      issue = journalized
      return unless issue.is_a?(Issue)
      return if issue.is_private? || private_notes? || attribute_before_last_save('private_notes')
      return unless saved_change_to_notes?

      previous_notes = notes_before_last_save.to_s.strip
      return if previous_notes.empty?

      action = notes.to_s.strip.empty? ? 'deleted' : 'updated'
      event = "comment_#{action}"
      return unless RedmineSlackNotification.event_enabled?(issue.project, event)

      image_names = action == 'updated' ? RedmineSlackNotification::Formatter.image_references(notes) : []

      payload = RedmineSlackNotification::Formatter.journal_payload(
        issue, actor: updated_by || User.current, notes: notes, comment_action: action,
        previous_notes: notes_before_last_save
      )
      if RedmineSlackNotification.effective_config(issue.project).dig('slack', 'comment_notifications_in_threads') == true
        payload = payload.merge('_redmine_comment_issue_id' => issue.id)
      end
      RedmineSlackNotification.enqueue(
        payload,
        project: issue.project, event: event,
        image_names: image_names, journal_id: action == 'updated' ? id : nil
      )
    end

    def slack_event_for_detail(detail)
      return 'issue_updated' unless detail.respond_to?(:property)

      case detail.property
      when 'relation'
        detail.value.to_s.empty? ? 'relation_removed' : 'relation_added'
      when 'attachment'
        detail.value.to_s.empty? ? 'attachment_removed' : 'attachment_added'
      when 'cf'
        'custom_field_changed'
      when 'attr'
        {
          'status_id' => 'status_changed',
          'assigned_to_id' => 'assignee_changed',
          'priority_id' => 'priority_changed',
          'category_id' => 'category_changed',
          'due_date' => 'due_date_changed',
          'start_date' => 'start_date_changed',
          'fixed_version_id' => 'version_changed',
          'subject' => 'subject_changed',
          'description' => 'description_changed',
          'parent_id' => 'parent_changed'
        }.fetch(detail.prop_key.to_s) do
          if detail.prop_key.to_s == 'child_id'
            detail.value.to_s.empty? ? 'child_removed' : 'child_added'
          else
            'issue_updated'
          end
        end
      else
        'issue_updated'
      end
    end
  end
end
