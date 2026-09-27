# Hourly rollup of BackendLoadMinute, kept for a year.
class BackendLoadHour < ApplicationRecord
  belongs_to :backend
end
