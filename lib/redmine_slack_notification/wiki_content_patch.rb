# frozen_string_literal: true

require_relative 'formatter'

module RedmineSlackNotification
  module WikiContentPatch
    def self.included(base)
      base.after_commit :notify_slack_wiki_created, on: :create
      base.after_commit :notify_slack_wiki_updated, on: :update
    end

    private

    def notify_slack_wiki_created
      notify_slack_wiki('created')
    end

    def notify_slack_wiki_updated
      return unless saved_change_to_text? || saved_change_to_comments?

      notify_slack_wiki('updated')
    end

    def notify_slack_wiki(action)
      project = page&.wiki&.project
      return unless project

      author = respond_to?(:author) ? self.author : User.current
      RedmineSlackNotification.enqueue(
        RedmineSlackNotification::Formatter.wiki_payload(self, project, actor: author, action: action),
        project: project
      )
    end
  end
end
