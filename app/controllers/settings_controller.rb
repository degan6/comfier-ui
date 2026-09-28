class SettingsController < ApplicationController
  include SettingsNav

  before_action :set_user

  def show; end

  def update
    if @user.update(settings_params)
      redirect_to settings_path, notice: 'Settings saved.', status: :see_other
    else
      render :show, status: :unprocessable_content
    end
  end

  private

  def set_user
    @user = current_user
    @backends = Backend.legacy.enabled.ordered.to_a
    @agent_servers = BackendPolicy.new(@user).usable_agent_backends.exists?
  end

  def settings_params
    params.expect(user: %i[preferred_backend_id default_aspect_ratio default_negative_prompt share_by_default
                           notify_email notify_slack notify_include_asset backend_affinity
                           delete_uploads_after_run])
  end
end
