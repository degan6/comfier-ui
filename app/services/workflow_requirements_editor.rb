# Applies an admin's edits to a workflow's model list. Edited rows become source "admin", which
# re-extraction never overwrites; removed rows are deleted (and re-appear only if the graph still
# names them and the admin hasn't overridden them).
class WorkflowRequirementsEditor
  EDITABLE = %w[folder filename url sha256].freeze

  def initialize(workflow)
    @workflow = workflow
  end

  def apply!(rows, _previous = nil)
    WorkflowModel.transaction do
      rows.each { apply_row(it) }
    end
    Agent::Requirements.extract!(@workflow)
    RecomputeAvailabilityJob.perform_later(workflow_id: @workflow.id)
  end

  private

  def apply_row(row)
    model = model_for(row)
    return unless model
    return model.destroy! if removing?(row, model)
    return unless row.values_at('folder', 'filename').all?(&:present?)

    model.assign_attributes(edited_attributes(row))
    model.update!(source: 'admin') if model.new_record? || model.changed?
  end

  def removing?(row, model) = row['remove'] == '1' && model.persisted?

  def model_for(row)
    row['id'].present? ? @workflow.workflow_models.find_by(id: row['id']) : @workflow.workflow_models.new
  end

  def edited_attributes(row)
    attrs = row.slice(*EDITABLE).transform_values { it.to_s.strip.presence }
    attrs['url'] = ModelRequirement.new(directory: 'x', name: 'x', url: attrs['url']).url
    attrs
  end
end
