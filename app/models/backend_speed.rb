# How fast a server is relative to others (1.0 typical, 2.0 twice as slow), plus per-server EWMAs.
class BackendSpeed < ApplicationRecord
  belongs_to :backend
end
