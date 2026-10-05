# frozen_string_literal: true
require 'minitest/autorun'

class LinkCardsLoadingTest < Minitest::Test
  def test_new_files_define_the_constants_expected_by_zeitwerk
    %w[link_cards slack_markup link_cards_helper link_quotes].each do |basename|
      require_relative "../lib/redmine_slack_notification/#{basename}"
      expected = basename.split('_').map(&:capitalize).join
      assert RedmineSlackNotification.const_defined?(expected, false), "#{basename}.rb must define #{expected}"
    end
  end
end
