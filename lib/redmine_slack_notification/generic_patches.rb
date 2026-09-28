# frozen_string_literal: true

module RedmineSlackNotification
  module GenericPatches
  end

  module NewsPatch
    def self.included(base)
      base.after_create { notify_slack_generic('News', 'created') }
      base.after_update { notify_slack_generic('News', 'updated') }
      base.after_destroy_commit { notify_slack_generic('News', 'deleted') }
    end

    private

    def notify_slack_generic(noun, action)
      project = self.project
      return unless project

      description_diff = if action == 'updated' && saved_change_to_description?
                           [description_before_last_save, description]
                         end

      RedmineSlackNotification.enqueue(
        RedmineSlackNotification::Formatter.generic_payload(
          noun: noun, action: action, subject: title,
          url: RedmineSlackNotification::Formatter.url(action == 'deleted' ? "/projects/#{project.identifier}/news" : "/news/#{id}"),
          project: project, actor: action == 'deleted' ? User.current : (respond_to?(:author) ? author : User.current),
          summary: respond_to?(:description) ? description : nil,
          body_diff: description_diff,
          notes: nil
        ), project: project, event: "news_#{action}"
      )
    end
  end

  module TimeEntryPatch
    def self.included(base)
      base.after_create { notify_slack_generic('Time entry', 'created') }
      base.after_update { notify_slack_generic('Time entry', 'updated') }
      base.after_destroy_commit { notify_slack_generic('Time entry', 'deleted') }
    end

    private

    def notify_slack_generic(noun, action)
      project = self.project
      return unless project

      fields = [['作業時間', "#{hours}h"], ['作業日', spent_on.to_s]]
      RedmineSlackNotification.enqueue(
        RedmineSlackNotification::Formatter.generic_payload(
          noun: noun, action: action, subject: "##{id}", url: RedmineSlackNotification::Formatter.url("/projects/#{project.identifier}/time_entries"),
          project: project, actor: action == 'deleted' ? User.current : (user || User.current), fields: fields, notes: comments
        ), project: project, event: "time_entry_#{action}"
      )
    end
  end

  module VersionPatch
    def self.included(base)
      base.after_create { notify_slack_generic('Version', 'created') }
      base.after_update { notify_slack_generic('Version', 'updated') }
      base.after_destroy_commit { notify_slack_generic('Version', 'deleted') }
    end

    private

    def notify_slack_generic(noun, action)
      project = self.project
      return unless project

      fields = [['ステータス', status.to_s], ['期日', effective_date.to_s]]
      RedmineSlackNotification.enqueue(
        RedmineSlackNotification::Formatter.generic_payload(
          noun: noun, action: action, subject: name,
          url: RedmineSlackNotification::Formatter.url(action == 'deleted' ? "/projects/#{project.identifier}/versions" : "/versions/#{id}"),
          project: project, actor: User.current, fields: fields, summary: description
        ), project: project, event: "version_#{action}"
      )
    end
  end

  module CommentPatch
    def self.included(base)

      base.after_create { notify_slack_news_comment }
      base.after_update_commit :notify_slack_news_comment_updated
      base.after_destroy_commit :notify_slack_news_comment_deleted
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
          notes: comment_body
        ), project: project, event: 'news_comment_added'
      )
    end

    def notify_slack_news_comment_deleted
      news = respond_to?(:commented) ? commented : nil
      return unless news.is_a?(News)

      project = news.project
      return unless project

      RedmineSlackNotification.enqueue(
        RedmineSlackNotification::Formatter.generic_payload(
          noun: 'News comment', action: 'deleted', subject: news.title,
          url: RedmineSlackNotification::Formatter.url("/news/#{news.id}"), project: project,
          actor: User.current
        ), project: project, event: 'news_comment_deleted'
      )
    end

    def notify_slack_news_comment_updated
      return unless saved_change_to_content?

      news = respond_to?(:commented) ? commented : nil
      return unless news.is_a?(News)

      project = news.project
      return unless project

      RedmineSlackNotification.enqueue(
        RedmineSlackNotification::Formatter.generic_payload(
          noun: 'News comment', action: 'updated', subject: news.title,
          url: RedmineSlackNotification::Formatter.url("/news/#{news.id}"), project: project,
          actor: User.current, body_diff: [content_before_last_save, content], body_diff_label: 'コメント'
        ), project: project, event: 'news_comment_updated'
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
        ), project: self, event: 'project_updated'
      )
    end
  end
end
