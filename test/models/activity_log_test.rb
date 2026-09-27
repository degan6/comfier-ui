require 'test_helper'

class ActivityLogTest < ActiveSupport::TestCase
  test 'search matches message and user email' do
    user = users(:alice)
    ActivityLog.create!(kind: :login, user:, message: 'Alice signed in', details: {}, created_at: Time.current)
    ActivityLog.create!(kind: :logout, user: users(:bob), message: 'Bob signed out', details: {}, created_at: Time.current)

    assert_equal 1, ActivityLog.search('Alice').count
    assert_equal 1, ActivityLog.search(user.email).count
  end

  test 'record_generation_finished logs cancelled separately from failed' do
    generation = generations(:alice_running)

    assert_difference -> { ActivityLog.generation_cancelled.count }, 1 do
      generation.update!(status: :failed, error_message: Generation::CANCELLED_MESSAGE, completed_at: Time.current)
    end

    log = ActivityLog.generation_cancelled.order(:id).last

    assert_equal generation.id, log.subject_id
  end
end
