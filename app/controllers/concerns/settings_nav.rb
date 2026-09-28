# Counts shown in the Settings sidebar, so admins see what needs attention from any settings page.
module SettingsNav
  extend ActiveSupport::Concern

  included do
    layout 'settings'
    before_action :load_settings_nav
  end

  private

  def load_settings_nav
    return unless current_user

    @nav_public_link_count = current_user.generations.publicly_linked.count
    load_admin_settings_nav if current_user.admin?
  end

  def load_admin_settings_nav
    @nav_open_reports = ReportCase.open_cases.count
    @nav_user_count = User.count
    @nav_backend_count = Backend.kept.count
    @nav_unhealthy_backends = Backend.legacy.enabled.unhealthy.count
    @nav_workflow_count = Workflow.count
    @nav_privacy_version = PrivacyNotice.current.version
    @nav_kinds_without_workflows = GenerationKind.keys - Workflow.enabled.distinct.pluck(:kind)
    @nav_workflows_missing_models = workflows_missing_models_count
  end

  def workflows_missing_models_count
    backends = Backend.legacy.enabled.to_a
    Workflow.enabled.count do |workflow|
      backends.any? { |backend| backend.missing_models(workflow).any? }
    end
  end
end
