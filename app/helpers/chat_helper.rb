module ChatHelper
  def chat_model_options(selected, models: nil)
    ids = models.presence || LiteLlm::Client.fallback_model_ids
    options_for_select(ids, selected)
  end

  def chat_message_image_tag(message)
    return unless message.image.attached?

    image_tag message.image, class: 'chat-message-image', alt: ''
  end
end
