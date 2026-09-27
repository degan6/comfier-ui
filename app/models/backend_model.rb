# One model file a server has, normalized from its inventory for queries.
class BackendModel < ApplicationRecord
  belongs_to :backend

  validates :folder, :filename, presence: true
end
