require 'test_helper'

module Admin
  class ActivityLogsTest < ActionDispatch::IntegrationTest
    test 'non-admins cannot see the log' do
      sign_in_as users(:alice)

      get admin_activity_logs_path

      assert_response :not_found
    end

    test 'admins see paginated searchable log entries' do
      sign_in_as users(:admin)
      ActivityLog.create!(
        kind: :login,
        user: users(:alice),
        message: 'Alice signed in',
        details: { provider: 'authentik' },
        created_at: Time.current
      )

      get admin_activity_logs_path

      assert_response :success
      assert_select 'h1', text: 'Log'
      assert_select '.navbar-nav .nav-link.active', text: /Log/
      assert_select 'td', text: /Alice signed in/

      get admin_activity_logs_path(q: 'authentik')

      assert_response :success
      assert_select 'td', text: /Alice signed in/

      get admin_activity_logs_path(kind: 'logout')

      assert_response :success
      assert_select 'td', text: /Alice signed in/, count: 0
    end

    test 'show displays full details json' do
      sign_in_as users(:admin)
      log = ActivityLog.create!(
        kind: :llm_chat,
        message: 'LLM placeholder_suggester succeeded (120ms)',
        details: { request: { model: 'gpt-test' }, response: { ok: true } },
        created_at: Time.current
      )

      get admin_activity_log_path(log)

      assert_response :success
      assert_select 'pre', text: /gpt-test/
    end
  end
end
