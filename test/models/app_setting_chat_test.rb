require 'test_helper'

class AppSettingChatTest < ActiveSupport::TestCase
  test 'chat notice url must be http or https when present' do
    settings = app_settings(:default)
    settings.chat_notice_url = 'ftp://example.com'

    assert_not settings.valid?
    assert_includes settings.errors[:chat_notice_url], 'is invalid'
  end

  test 'chat_notice? is true when text is present' do
    settings = app_settings(:default)
    settings.chat_notice_text = 'Use the main chat bot'

    assert_predicate settings, :chat_notice?
  end
end
