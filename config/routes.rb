# frozen_string_literal: true

post 'slackmine/events', to: 'slackmine_events#receive'
post 'slackmine/interactions', to: 'slackmine_events#receive'
post 'slackmine/commands', to: 'slackmine_commands#receive'
