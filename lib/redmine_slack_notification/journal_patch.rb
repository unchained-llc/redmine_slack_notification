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
      update_enabled = details.any? && RedmineSlackNotification.event_enabled?(issue.project, 'issue_updated')
      return unless comment_enabled || update_enabled

      payload = if comment_enabled
                  RedmineSlackNotification::Formatter.journal_payload(
                    issue, actor: user, notes: notes,
                    details: update_enabled ? details : []
                  )
                else
                  RedmineSlackNotification::Formatter.issue_payload(
                    issue, actor: user, action: 'updated', details: details
                  )
                end
      RedmineSlackNotification.enqueue(
        payload,
        project: issue.project,
        event: update_enabled ? 'issue_updated' : 'comment_added',
        image_names: comment_enabled ? RedmineSlackNotification::Formatter.image_references(notes) : [],
        journal_id: comment_enabled ? id : nil
      )
    end
  end
end
