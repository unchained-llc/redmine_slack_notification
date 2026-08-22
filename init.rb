# frozen_string_literal: true

warn 'UnchainedSlack: loading plugin init.rb'
Rails.logger.info('UnchainedSlack: loading plugin init.rb') if defined?(Rails)
require_relative 'lib/unchained_slack'


Redmine::Plugin.register :unchained_slack do
  name 'Unchained Slack notifications'
  author 'Unchained'
  description 'Send Redmine 7 issue and wiki notifications to Slack.'
  version '0.1.0'
  requires_redmine version_or_higher: '7.0.0'


end
