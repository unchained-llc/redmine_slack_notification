# frozen_string_literal: true

require_relative 'formatter'

module Slackmine
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
      body_diff = [text_before_last_save, text] if action == 'updated' && saved_change_to_text?
      Slackmine.enqueue(
        Slackmine::Formatter.wiki_payload(self, project, actor: author, action: action,
                                                         body_diff: body_diff),
        project: project, event: "wiki_#{action}"
      )
    end
  end

  module WikiPagePatch
    def self.included(base)
      base.after_destroy_commit :notify_slack_wiki_deleted
    end

    private

    def notify_slack_wiki_deleted
      project = self.project
      return unless project

      Slackmine.enqueue(
        Slackmine::Formatter.generic_payload(
          noun: 'Wiki page', action: 'deleted', subject: title,
          url: Slackmine::Formatter.url("/projects/#{project.identifier}/wiki"),
          project: project, actor: User.current
        ), project: project, event: 'wiki_deleted'
      )
    end
  end
end
