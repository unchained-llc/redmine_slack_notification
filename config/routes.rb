# frozen_string_literal: true

post 'redmine_slack/events', to: 'redmine_slack_events#receive'
post 'redmine_slack/interactions', to: 'redmine_slack_events#receive'
post 'redmine_slack/commands', to: 'redmine_slack_commands#receive'
