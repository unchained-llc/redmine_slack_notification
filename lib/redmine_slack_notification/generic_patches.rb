# frozen_string_literal: true

module RedmineSlackNotification
  module GenericPatches
  end

  module NewsPatch
    def self.included(base)
      base.after_create { notify_slack_generic('News', 'created') }
      base.after_update { notify_slack_generic('News', 'updated') }
    end

    private

    def notify_slack_generic(noun, action)
      project = self.project
      return unless project

      RedmineSlackNotification.enqueue(
        RedmineSlackNotification::Formatter.generic_payload(
          noun: noun, action: action, subject: title, url: RedmineSlackNotification::Formatter.url("/news/#{id}"),
          project: project, actor: respond_to?(:author) ? author : User.current,
          summary: respond_to?(:description) ? description : nil,
          notes: nil
        ), project: project
      )
    end
  end

  module TimeEntryPatch
    def self.included(base)
      base.after_create { notify_slack_generic('Time entry', 'created') }
      base.after_update { notify_slack_generic('Time entry', 'updated') }
    end

    private

    def notify_slack_generic(noun, action)
      project = self.project
      return unless project

      fields = [['作業時間', "#{hours}h"], ['作業日', spent_on.to_s]]
      RedmineSlackNotification.enqueue(
        RedmineSlackNotification::Formatter.generic_payload(
          noun: noun, action: action, subject: "##{id}", url: RedmineSlackNotification::Formatter.url("/projects/#{project.identifier}/time_entries"),
          project: project, actor: user || User.current, fields: fields, notes: comments
        ), project: project
      )
    end
  end

  module VersionPatch
    def self.included(base)
      base.after_create { notify_slack_generic('Version', 'created') }
      base.after_update { notify_slack_generic('Version', 'updated') }
    end

    private

    def notify_slack_generic(noun, action)
      project = self.project
      return unless project

      fields = [['ステータス', status.to_s], ['期日', effective_date.to_s]]
      RedmineSlackNotification.enqueue(
        RedmineSlackNotification::Formatter.generic_payload(
          noun: noun, action: action, subject: name, url: RedmineSlackNotification::Formatter.url("/versions/#{id}"),
          project: project, actor: User.current, fields: fields, summary: description
        ), project: project
      )
    end
  end

  module CommentPatch
    def self.included(base)

      base.after_create { notify_slack_news_comment }
    end

    private

    def notify_slack_news_comment

      news = respond_to?(:commented) ? commented : nil

      return unless news.is_a?(News)

      project = news.project

      return unless project

      comment_body = if respond_to?(:read_attribute)
                       read_attribute(:comments).presence || read_attribute(:comment).presence
                     end
      comment_body ||= comments if respond_to?(:comments) && comments.is_a?(String)

      RedmineSlackNotification.enqueue(
        RedmineSlackNotification::Formatter.generic_payload(
          noun: 'News', action: 'updated', subject: news.title,
          url: RedmineSlackNotification::Formatter.url("/news/#{news.id}"), project: project,
          actor: respond_to?(:author) ? author : User.current,
          summary: 'ニュースにコメントが追加されました。',
          notes: comment_body
        ), project: project
      )
    end
  end

  module ProjectPatch
    def self.included(base)
      base.after_update { notify_slack_project_updated }
    end

    private

    def notify_slack_project_updated
      RedmineSlackNotification.enqueue(
        RedmineSlackNotification::Formatter.generic_payload(
          noun: 'Project', action: 'updated', subject: name,
          url: RedmineSlackNotification::Formatter.url("/projects/#{identifier}"), project: self,
          actor: User.current, summary: description
        ), project: self
      )
    end
  end
end
