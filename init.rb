# frozen_string_literal: true


require_relative 'lib/slackmine'


Redmine::Plugin.register :slackmine do
  name 'Slackmine'
  author 'Unchained'
  description 'Integrate Redmine 7 with Slack: notifications, Work Objects, issue actions, search, and thread replies.'
  version '0.1.0'
  requires_redmine version_or_higher: '7.0.0'


end
