# A file an agent uploaded for a generation, before and after it is attached as an output.
class GenerationOutput < ApplicationRecord
  belongs_to :generation
  belongs_to :backend, optional: true
end
