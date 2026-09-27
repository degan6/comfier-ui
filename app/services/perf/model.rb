# frozen_string_literal: true

module Perf
  # execute_ms ≈ a + b × work_units, fitted by weighted least squares over exponentially decayed
  # sums kept on a PerfStat row, so each new sample is an O(1) update.
  class Model
    DECAY = 0.97
    MIN_FIT_N = 3
    Z90 = 1.28

    attr_reader :stat

    def initialize(stat)
      @stat = stat
    end

    def n = stat.n.to_f

    def coefficients # rubocop:disable Metrics/AbcSize
      sw = stat.sw.to_f
      return [0.0, 0.0] if sw <= 0

      variance = (sw * stat.swxx.to_f) - (stat.swx.to_f**2)
      return proportional if n < MIN_FIT_N || variance.abs < 1e-9 * [sw * stat.swxx.to_f, 1].max

      b = ((sw * stat.swxy.to_f) - (stat.swx.to_f * stat.swy.to_f)) / variance
      a = (stat.swy.to_f - (b * stat.swx.to_f)) / sw
      return [stat.swy.to_f / sw, 0.0] if b.negative?
      return [0.0, stat.swxy.to_f / stat.swxx] if a.negative?

      [a, b]
    end

    def p50(work_units)
      a, b = coefficients
      [a + (b * work_units.to_f), 0].max
    end

    def p90(work_units) = p50(work_units) + (Z90 * Math.sqrt([stat.sres2.to_f, 0].max))

    def per_unit_ms(work_units = nil)
      units = work_units || stat.median_work_units || 1.0
      units = 1.0 if units.to_f <= 0
      p50(units) / units.to_f
    end

    # Decay the old sums, then add (x, y) with weight w. The residual variance is a weighted mean
    # of squared errors against the fit before this sample.
    def add!(x, y, weight: 1.0) # rubocop:disable Metrics/AbcSize
      x = x.to_f
      y = y.to_f
      residual = n.positive? ? y - p50(x) : 0.0
      old_weight = stat.sw.to_f * DECAY
      total = old_weight + weight
      stat.sres2 = total.positive? ? ((stat.sres2.to_f * old_weight) + (weight * (residual**2))) / total : 0
      stat.sw = total
      stat.swx = (stat.swx.to_f * DECAY) + (weight * x)
      stat.swy = (stat.swy.to_f * DECAY) + (weight * y)
      stat.swxx = (stat.swxx.to_f * DECAY) + (weight * x * x)
      stat.swxy = (stat.swxy.to_f * DECAY) + (weight * x * y)
      stat.n = stat.n.to_i + 1
      stat.median_work_units = stat.median_work_units ? (0.9 * stat.median_work_units) + (0.1 * x) : x
      stat
    end

    private

    # With too few samples or no spread in x, assume time scales with work units.
    def proportional
      return [stat.swy.to_f / stat.sw, 0.0] if stat.swx.to_f <= 0

      [0.0, stat.swy.to_f / stat.swx]
    end
  end
end
