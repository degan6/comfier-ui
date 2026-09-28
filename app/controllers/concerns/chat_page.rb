module ChatPage
  extend ActiveSupport::Concern

  private

  def load_chat_availability
    @chat_unconfigured = !LiteLlm::Client.configured?
  end

  def load_chat_sidebar
    @conversations = current_user.chat_conversations.recent_first.limit(50)
    @chat_models = LiteLlm::Client.models
    @chat_settings = AppSetting.current
  end

  def default_chat_model
    AppSetting.current.chat_default_model.presence || LiteLlm::Client.model
  end

  def chat_available?
    !@chat_unconfigured
  end
end
