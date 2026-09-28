require 'test_helper'

module Admin
  class ChatSettingsTest < ActionDispatch::IntegrationTest
    setup do
      @previous = {
        'LITELLM_URL' => ENV.fetch('LITELLM_URL', nil),
        'LITELLM_MODEL' => ENV.fetch('LITELLM_MODEL', nil)
      }
      ENV['LITELLM_URL'] = 'http://litellm.test'
      ENV['LITELLM_MODEL'] = 'gpt-test'
      stub_request(:get, 'http://litellm.test/v1/models')
        .to_return(body: { data: [{ id: 'gpt-test' }] }.to_json)
    end

    teardown do
      @previous.each { |key, value| ENV[key] = value }
    end

    test 'non-admins cannot edit chat settings' do
      sign_in_as users(:alice)

      get edit_admin_chat_setting_path

      assert_response :not_found
    end

    test 'admins can update chat settings' do
      sign_in_as users(:admin)

      get edit_admin_chat_setting_path

      assert_response :success
      assert_select 'h1', text: 'Chat'

      patch admin_chat_setting_path, params: {
        app_setting: {
          chat_default_model: 'gpt-test',
          chat_notice_text: 'Try the full assistant',
          chat_notice_url: 'https://chat.example.com'
        }
      }

      assert_redirected_to edit_admin_chat_setting_path
      settings = app_settings(:default).reload

      assert_equal 'gpt-test', settings.chat_default_model
      assert_equal 'Try the full assistant', settings.chat_notice_text
      assert_equal 'https://chat.example.com', settings.chat_notice_url
    end
  end
end
