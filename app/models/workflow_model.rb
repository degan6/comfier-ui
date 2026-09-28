# One model file a workflow needs, normalized from the API and UI forms. Admin edits (source
# "admin") win over re-extracted rows for the same folder and filename.
class WorkflowModel < ApplicationRecord
  SOURCES = %w[api ui admin enriched].freeze

  belongs_to :workflow

  validates :folder, :filename, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :filename, uniqueness: { scope: %i[workflow_id folder] }

  def requirement = ModelRequirement.new(directory: folder, name: filename, url:)
  def basename = File.basename(filename)
  def unknown_folder? = folder == 'unknown'

  def to_requirement_h
    { 'folder' => folder, 'filename' => filename, 'url' => url, 'sha256' => sha256, 'bytes' => bytes,
      'source' => source }
  end
end
