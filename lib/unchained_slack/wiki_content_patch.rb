# frozen_string_literal: true

require_relative 'formatter'

module UnchainedSlack
  module WikiContentPatch
    def self.included(base)
      base.after_create :notify_slack_wiki_created
      base.after_update :notify_slack_wiki_updated
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
      project = wiki&.project
      return unless project

      path = "/projects/#{project.identifier}/wiki/#{title}"
      link = "<#{UnchainedSlack::Formatter.url(path)}|#{UnchainedSlack::Formatter.text(title)}>"
      author = respond_to?(:author) ? self.author : User.current
      message = "[Agent] #{UnchainedSlack::Formatter.user_mention(author)} #{action} wiki #{link} (#{UnchainedSlack::Formatter.text(project.name)})"
      message += "\n> #{UnchainedSlack::Formatter.text(text.to_s.truncate(500))}" if action == 'created'
      UnchainedSlack.notify(UnchainedSlack::Formatter.payload(message), project: project)
    end
  end
end
