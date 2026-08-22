# frozen_string_literal: true

warn 'RedmineSlackNotification: loading plugin init.rb'
Rails.logger.info('RedmineSlackNotification: loading plugin init.rb') if defined?(Rails)
require_relative 'lib/redmine_slack_notification'


Redmine::Plugin.register :redmine_slack_notification do
  name 'Redmine Event Notifications'
  author 'Unchained'
  description 'Send Redmine 7 issue and wiki notifications to Slack.'
  version '0.1.0'
  requires_redmine version_or_higher: '7.0.0'


end
