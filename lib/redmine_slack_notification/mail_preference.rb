# frozen_string_literal: true

module RedmineSlackNotification
  module UserPreferencePatch
    def slack_suppress_mail
      self[:slack_suppress_mail] == true || self[:slack_suppress_mail] == '1'
    end

    def slack_suppress_mail=(value)
      self[:slack_suppress_mail] = value
    end
  end

  module MailerPatch
    # Returning without calling mail lets ActionMailer use its normal NullMail.
    # Account and security mail actions deliberately do not participate.
    %i[issue_add issue_edit news_added news_comment_added wiki_content_added wiki_content_updated].each do |action|
      define_method(action) do |user, object|
        return if MailPreference.suppress?(user, action, object)

        super(user, object)
      end
    end
  end

  module MailPreference
    module_function

    def suppress?(user, action, object)
      return false unless user.pref.slack_suppress_mail
      return false if Thread.current[:redmine_slack_thread_comment]

      project, events = notification(action, object, user)
      return false unless project && events && !events.empty?
      return false unless project.active?
      return false unless events.all? { |event| RedmineSlackNotification.event_enabled?(project, event) }

      RedmineSlackNotification.with_project(project) do
        token = RedmineSlackNotification.bot_token(project)
        channel = RedmineSlackNotification.channel_id(project)
        return false if token.to_s.empty? || !channel.to_s.match?(/\A[CG][A-Z0-9]+\z/)

        slack_id = recipient_id(user, token)
        return false unless slack_id

        member?(channel, slack_id, token)
      end
    rescue StandardError => error
      # Never include tokens, identities, API response bodies, or content here.
      Rails.logger&.warn("[redmine_slack_notification] Mail retained: #{error.class}")
      false
    end

    def recipient_id(user, token)
      mapping = RedmineSlackNotification.user_mapping
      key = [user.login.to_s, user.mail.to_s].find { |candidate| mapping.key?(candidate) }
      if key
        id = mapping[key].to_s.strip
        return id if id.match?(/\A[UW][A-Z0-9]+\z/)

        return nil
      end

      # Reuse outgoing name matching, then verify ownership against a fresh
      # Slack profile before suppressing mail. Do not cache identity evidence.
      id = RedmineSlackNotification.slack_user_id_for_name(user.login)
      return unless id.to_s.match?(/\A[UW][A-Z0-9]+\z/)

      response = RedmineSlackNotification.slack_api('users.info', { 'user' => id }, token,
                                                   form: true, open_timeout: 2, read_timeout: 3)
      member = response['user']
      return unless member.is_a?(Hash) && member['id'] == id
      return if member['deleted'] || member['is_bot'] || member['is_app_user'] || member['is_stranger']

      team = RedmineSlackNotification.effective_config.dig('slack', 'events', 'team_id').to_s
      return if !team.empty? && (member['team_id'] || member['team']) != team

      email = member.dig('profile', 'email').to_s.strip.downcase
      return if email.empty? || email != user.mail.to_s.strip.downcase

      id
    end

    def notification(action, object, user)
      case action
      when :issue_add
        return if object.is_private?

        [object.project, ['issue_created']]
      when :issue_edit
        issue = object.journalized
        return unless issue.is_a?(Issue)
        return if issue.is_private? || object.private_notes?

        events = object.visible_details(user).map { |detail| object.send(:slack_event_for_detail, detail) }
        events << 'comment_added' unless object.notes.to_s.strip.empty?
        [issue.project, events.uniq]
      when :news_added
        [object.project, ['news_created']]
      when :news_comment_added
        return unless object.commented.is_a?(News)
        return if object.comments.to_s.strip.empty?

        [object.commented.project, ['news_comment_added']]
      when :wiki_content_added, :wiki_content_updated
        [object.page.wiki.project, [action == :wiki_content_added ? 'wiki_created' : 'wiki_updated']]
      end
    end

    def member?(channel, slack_id, token)
      cursor = nil
      seen = {}
      # Bound synchronous work; incomplete or failed lookups retain email.
      10.times do
        params = { 'channel' => channel, 'limit' => 200 }
        params['cursor'] = cursor if cursor
        response = RedmineSlackNotification.slack_api('conversations.members', params, token,
                                                     form: true, open_timeout: 2, read_timeout: 3)
        return false unless response['members'].is_a?(Array)
        return true if response['members'].include?(slack_id)

        cursor = response.dig('response_metadata', 'next_cursor').to_s.strip
        return false if cursor.empty? || seen[cursor]

        seen[cursor] = true
      end
      false
    end
  end

  if defined?(Redmine::Hook::ViewListener)
    class MailPreferenceHook < Redmine::Hook::ViewListener
      render_on :view_layouts_base_html_head, partial: 'redmine_slack_notification/mail_preference_assets'
      render_on :view_my_account_preferences, partial: 'redmine_slack_notification/mail_preference'
    end
  end
end
