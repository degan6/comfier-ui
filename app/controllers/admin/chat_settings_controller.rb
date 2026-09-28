module Admin
  class ChatSettingsController < BaseController
    def edit
      @settings = AppSetting.current
      @chat_models = LiteLlm::Client.models
    end

    def update
      @settings = AppSetting.current
      @chat_models = LiteLlm::Client.models
      if @settings.update(settings_params)
        redirect_to edit_admin_chat_setting_path, notice: 'Chat settings saved.', status: :see_other
      else
        render :edit, status: :unprocessable_content
      end
    end

    private

    def settings_params
      params.expect(app_setting: %i[chat_default_model chat_notice_text chat_notice_url])
    end
  end
end
