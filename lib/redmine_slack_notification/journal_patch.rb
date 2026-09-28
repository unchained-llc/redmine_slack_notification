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

      payload = if notes.to_s.strip.present?
                  RedmineSlackNotification::Formatter.journal_payload(
                    issue,
                    actor: user,
                    notes: notes,
                    details: details
                  )
                elsif details.any?
                  RedmineSlackNotification::Formatter.issue_payload(
                    issue,
                    actor: user,
                    action: 'updated',
                    details: details
                  )
                else
                  return
                end
      RedmineSlackNotification.enqueue(
        payload,
        project: issue.project,
        image_names: RedmineSlackNotification::Formatter.image_references(notes),
        journal_id: id
      )
    end
  end
end
