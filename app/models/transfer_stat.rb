# EWMA throughput and fixed overhead for input fetches, output uploads, and model downloads.
class TransferStat < ApplicationRecord
  KINDS = %w[input output download dispatch].freeze

  belongs_to :backend

  validates :kind, inclusion: { in: KINDS }
end
