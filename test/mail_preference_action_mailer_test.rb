# frozen_string_literal: true

# Run separately with ActionMailer available. No Redmine database or SMTP
# connection is used: all messages use ActionMailer's test delivery method.
require 'action_mailer'
require 'minitest/autorun'
require 'ostruct'
require_relative '../lib/slackmine/mail_preference'

class PreferenceTestMailer < ActionMailer::Base
  self.delivery_method = :test
  default from: 'sender@example.com'

  def issue_add(user, _issue)
    mail(to: user.mail, subject: 'Issue', body: 'Issue notification')
  end

  def lost_password(user)
    mail(to: user.mail, subject: 'Password', body: 'Password notification')
  end

  prepend Slackmine::MailerPatch
end

class MailPreferenceActionMailerTest < Minitest::Test
  def setup
    ActionMailer::Base.deliveries.clear
    @user = OpenStruct.new(mail: 'recipient@example.com')
  end

  def test_suppressed_action_produces_null_mail_and_no_delivery
    Slackmine::MailPreference.stub(:suppress?, true) do
      message = PreferenceTestMailer.issue_add(@user, Object.new)
      assert_instance_of ActionMailer::Base::NullMail, message.message
      message.deliver_now
    end
    assert_empty ActionMailer::Base.deliveries
  end

  def test_retained_action_delivers_original_mail
    Slackmine::MailPreference.stub(:suppress?, false) do
      PreferenceTestMailer.issue_add(@user, Object.new).deliver_now
    end
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_equal 'Issue', ActionMailer::Base.deliveries.first.subject
  end

  def test_password_mail_does_not_consult_suppression_policy
    Slackmine::MailPreference.stub(:suppress?, ->(*) { flunk 'Account email must bypass policy' }) do
      PreferenceTestMailer.lost_password(@user).deliver_now
    end
    assert_equal 'Password', ActionMailer::Base.deliveries.first.subject
  end
end
