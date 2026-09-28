# Seconds online, busy, and in local use for one server in one minute.
class BackendLoadMinute < ApplicationRecord
  belongs_to :backend
end
