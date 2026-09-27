# Lets one user run jobs on a server shared with them.
class BackendShare < ApplicationRecord
  belongs_to :backend
  belongs_to :user

  validates :user_id, uniqueness: { scope: :backend_id }
end
