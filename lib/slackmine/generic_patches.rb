# frozen_string_literal: true

module Slackmine
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

      Slackmine.enqueue(
        Slackmine::Formatter.generic_payload(
          noun: noun, action: action, subject: title,
          url: Slackmine::Formatter.url(action == 'deleted' ? "/projects/#{project.identifier}/news" : "/news/#{id}"),
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

      fields = [['hours', "#{hours}h"], ['spent_on', spent_on.to_s]]
      Slackmine.enqueue(
        Slackmine::Formatter.generic_payload(
          noun: noun, action: action, subject: "##{id}", url: Slackmine::Formatter.url("/projects/#{project.identifier}/time_entries"),
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

      fields = [['status', status.to_s], ['due_date', effective_date.to_s]]
      Slackmine.enqueue(
        Slackmine::Formatter.generic_payload(
          noun: noun, action: action, subject: name,
          url: Slackmine::Formatter.url(action == 'deleted' ? "/projects/#{project.identifier}/versions" : "/versions/#{id}"),
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

      Slackmine.enqueue(
        Slackmine::Formatter.generic_payload(
          noun: 'News comment', action: 'added', subject: news.title,
          url: Slackmine::Formatter.url("/news/#{news.id}"), project: project,
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

      Slackmine.enqueue(
        Slackmine::Formatter.generic_payload(
          noun: 'News comment', action: 'deleted', subject: news.title,
          url: Slackmine::Formatter.url("/news/#{news.id}"), project: project,
          actor: User.current, body_diff: [content, ''],
          body_diff_label: :comment
        ), project: project, event: 'news_comment_deleted'
      )
    end

    def notify_slack_news_comment_updated
      return unless saved_change_to_content?

      news = respond_to?(:commented) ? commented : nil
      return unless news.is_a?(News)

      project = news.project
      return unless project

      Slackmine.enqueue(
        Slackmine::Formatter.generic_payload(
          noun: 'News comment', action: 'updated', subject: news.title,
          url: Slackmine::Formatter.url("/news/#{news.id}"), project: project,
          actor: User.current, body_diff: [content_before_last_save, content],
          body_diff_label: :comment,
          body_full_label: :updated_comment
        ), project: project, event: 'news_comment_updated'
      )
    end
  end

  module DocumentPatch
    def self.included(base)
      base.after_create_commit :notify_slack_document_created
      base.after_update_commit :notify_slack_document_updated
      base.after_destroy_commit :notify_slack_document_deleted
    end

    private

    def notify_slack_document_created
      notify_slack_document('created')
    end

    def notify_slack_document_updated
      return unless (previous_changes.keys & %w[title description category_id]).any?
      notify_slack_document('updated')
    end

    def notify_slack_document_deleted
      notify_slack_document('deleted')
    end

    def notify_slack_document(action)
      path = action == 'deleted' ? "/projects/#{project.identifier}/documents" : "/documents/#{id}"
      Slackmine.enqueue(
        Slackmine::Formatter.generic_payload(
          noun: 'Document', action: action, subject: title,
          url: Slackmine::Formatter.url(path), project: project,
          actor: User.current, summary: description,
          body_diff: action == 'updated' && previous_changes['description']
        ), project: project, event: "document_#{action}"
      )
    end
  end

  module AttachmentPatch
    def self.included(base)
      base.after_save_commit :notify_slack_file_added
      base.after_update_commit :notify_slack_file_updated
      base.after_destroy_commit :notify_slack_file_deleted
    end

    private

    def notify_slack_file_added
      # Redmine uploads first, then assigns a container in a later save.
      return unless saved_change_to_container_id? && container_id_before_last_save.nil?

      notify_slack_file('added')
    end

    def notify_slack_file_updated
      # Container assignment is an addition, not a file edit.
      return if saved_change_to_container_id? || container_id.nil?
      return unless (previous_changes.keys & %w[filename description content_type digest]).any?
      notify_slack_file('updated')
    end

    def notify_slack_file_deleted
      notify_slack_file('deleted')
    end

    def notify_slack_file(action)
      case container&.class&.name
      when 'Project'
        destination = container
        event = "file_#{action}"
      when 'Version'
        destination = container.project
        event = "file_#{action}"
      when 'Document'
        destination = container.project
        event = "document_file_#{action}"
      else
        return
      end
      path = if action != 'deleted'
               "/attachments/#{id}"
             elsif container.class.name == 'Document'
               "/documents/#{container.id}"
             else
               "/projects/#{destination.identifier}/files"
             end
      Slackmine.enqueue(
        Slackmine::Formatter.generic_payload(
          noun: 'File', action: action, subject: filename,
          url: Slackmine::Formatter.url(path), project: destination,
          actor: action == 'added' ? author : User.current, summary: description
        ), project: destination, event: event
      )
    end
  end

  module MessagePatch
    def self.included(base)
      base.after_create_commit :notify_slack_message_posted
      base.after_update_commit :notify_slack_message_updated
      base.after_destroy_commit :notify_slack_message_deleted
    end

    private

    def notify_slack_message_posted
      notify_slack_message('posted')
    end

    def notify_slack_message_updated
      return unless (previous_changes.keys & %w[subject content sticky locked]).any?
      notify_slack_message('updated')
    end

    def notify_slack_message_deleted
      notify_slack_message('deleted')
    end

    def notify_slack_message(action)
      path = action == 'deleted' ? "/projects/#{project.identifier}/boards/#{board_id}" :
        "/boards/#{board_id}/topics/#{parent_id || id}?r=#{id}#message-#{id}"
      Slackmine.enqueue(
        Slackmine::Formatter.generic_payload(
          noun: 'Message', action: action, subject: subject,
          url: Slackmine::Formatter.url(path), project: project,
          actor: action == 'posted' ? author : User.current,
          notes: content, body_diff: action == 'updated' && previous_changes['content']
        ), project: project, event: "message_#{action}"
      )
    end
  end

  module ProjectPatch
    def self.included(base)
      base.after_update { notify_slack_project_updated }
    end

    private

    def notify_slack_project_updated
      Slackmine.enqueue(
        Slackmine::Formatter.generic_payload(
          noun: 'Project', action: 'updated', subject: name,
          url: Slackmine::Formatter.url("/projects/#{identifier}"), project: self,
          actor: User.current, summary: description
        ), project: self, event: 'project_updated'
      )
    end
  end
end
