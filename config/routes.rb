# frozen_string_literal: true

post 'redmine_slack/events', to: 'redmine_slack_events#receive'
