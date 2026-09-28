class ChatConversation < ApplicationRecord
  belongs_to :user
  has_many :chat_messages, -> { order(created_at: :asc, id: :asc) }, dependent: :destroy, inverse_of: :chat_conversation

  scope :recent_first, -> { order(updated_at: :desc, id: :desc) }

  validates :model, length: { maximum: 255 }, allow_nil: true

  def effective_model
    model.presence || AppSetting.current.chat_default_model.presence || LiteLlm::Client.model
  end

  def title_or_default
    title.presence || 'New chat'
  end

  def reply_pending?
    chat_messages.assistant.pending.exists?
  end

  def set_title_from!(text)
    return if title.present?

    snippet = text.to_s.strip.truncate(60)
    update!(title: snippet.presence || 'New chat')
  end
end
