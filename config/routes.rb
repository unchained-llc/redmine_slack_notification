# frozen_string_literal: true

get 'admin/slackmine', to: 'slackmine_admin#index', as: :slackmine_admin

post 'admin/slackmine/test_notification', to: 'slackmine_admin#test_notification', as: :slackmine_admin_test_notification

post 'slackmine/events', to: 'slackmine_events#receive'
post 'slackmine/interactions', to: 'slackmine_events#receive'
post 'slackmine/commands', to: 'slackmine_commands#receive'
