# The models and node types an agent last reported.
class BackendInventory < ApplicationRecord
  belongs_to :backend

  def model_count = models_json.values.sum { Array(it).size }
  def node_type_count = Array(node_types_json).size
end
