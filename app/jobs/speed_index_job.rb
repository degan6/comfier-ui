# frozen_string_literal: true

# Hourly: recompute each server's relative speed and cold-start penalty.
class SpeedIndexJob < ApplicationJob
  queue_as :default

  def perform = Perf::SpeedIndex.recompute!
end
