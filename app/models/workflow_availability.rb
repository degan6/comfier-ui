# Cached answer to "can this server run this workflow?", recomputed when either side changes.
class WorkflowAvailability < ApplicationRecord
  STATUSES = %w[ready needs_downloads blocked].freeze

  belongs_to :workflow
  belongs_to :backend

  validates :status, inclusion: { in: STATUSES }

  def ready? = status == 'ready'
  def needs_downloads? = status == 'needs_downloads'
  def blocked? = status == 'blocked'
end
