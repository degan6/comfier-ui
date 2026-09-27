module GenerationActivityLogging
  extend ActiveSupport::Concern

  included do
    after_commit :log_generation_created, on: :create
    after_commit :log_generation_finished, if: :saved_change_to_status?
  end

  private

  def log_generation_created
    ActivityLog.record_generation_queued(self)
  end

  def log_generation_finished
    return unless finished?

    ActivityLog.record_generation_finished(self)
  end
end
