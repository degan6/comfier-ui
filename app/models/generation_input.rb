# A file the agent fetches for a generation, referenced in the workflow as comfier-input://<input_id>.
class GenerationInput < ApplicationRecord
  belongs_to :generation

  def blob = ActiveStorage::Blob.find_by(key: storage_key)
end
