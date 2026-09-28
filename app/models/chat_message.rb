class ChatMessage < ApplicationRecord
  IMAGE_CONTENT_TYPES = %w[image/png image/jpeg image/webp image/gif].freeze
  MAX_IMAGE_BYTES = 10.megabytes

  belongs_to :chat_conversation, touch: true

  has_one_attached :image

  enum :role, { user: 'user', assistant: 'assistant' }, validate: true
  enum :status, { pending: 'pending', succeeded: 'succeeded', failed: 'failed' }, default: :succeeded, validate: true

  validates :content, presence: true, if: -> { user? && !image.attached? }
  validate :image_valid, if: -> { image.attached? }

  after_update_commit :broadcast_message_update
  after_update_commit :broadcast_composer_refresh, if: :assistant_reply_finished?

  def display_content
    content.to_s
  end

  private

  def broadcast_message_update
    broadcast_replace_later_to(
      [chat_conversation, :messages],
      partial: 'chat_messages/message',
      locals: { message: self }
    )
  end

  def assistant_reply_finished?
    assistant? && saved_change_to_status? && !pending?
  end

  def broadcast_composer_refresh
    conversation = chat_conversation
    Turbo::StreamsChannel.broadcast_replace_later_to(
      [conversation, :messages],
      target: 'chat_composer',
      partial: 'chat_conversations/composer',
      locals: conversation.composer_locals
    )
  end

  def image_valid
    blob = image.blob
    unless IMAGE_CONTENT_TYPES.include?(blob.content_type)
      errors.add(:image, 'must be PNG, JPEG, WebP, or GIF')
      return
    end
    return if blob.byte_size <= MAX_IMAGE_BYTES

    errors.add(:image, 'is too large (max 10 MB)')
  end
end
