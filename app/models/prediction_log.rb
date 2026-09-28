# Predicted against actual total time for a completed job, for accuracy tracking.
class PredictionLog < ApplicationRecord
  belongs_to :generation
  belongs_to :backend, optional: true

  def abs_pct_error
    return if actual_total_ms.to_i.zero? || predicted_total_ms.nil?

    ((predicted_total_ms - actual_total_ms).abs.to_f / actual_total_ms) * 100
  end
end
