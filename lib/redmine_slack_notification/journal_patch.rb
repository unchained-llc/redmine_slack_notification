# frozen_string_literal: true

require_relative 'formatter'

module RedmineSlackNotification
  module JournalPatch
    def self.included(base)

      base.after_create_commit :notify_slack_journal_created
    end

    private

    def notify_slack_journal_created

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
      RedmineSlackNotification.enqueue(
        payload,
        project: issue.project,
        event: enabled_details.any? ? slack_event_for_detail(enabled_details.first) : 'comment_added',
        image_names: comment_enabled ? RedmineSlackNotification::Formatter.image_references(notes) : [],
        journal_id: comment_enabled ? id : nil
      )
    end

    def slack_event_for_detail(detail)
      return 'issue_updated' unless detail.respond_to?(:property) && detail.property == 'relation'

      detail.value.to_s.empty? ? 'relation_removed' : 'relation_added'
    end
  end
end
