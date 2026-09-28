module Chat
  # Builds OpenAI-style message arrays for a conversation, including vision parts.
  class TranscriptBuilder
    HISTORY_LIMIT = 40

    def self.for(conversation) = new(conversation).build

    def initialize(conversation)
      @conversation = conversation
    end

    def build
      messages_for_history.map { |message| { role: message.role, content: content_for(message) } }
    end

    private

    def messages_for_history
      @conversation.chat_messages
                   .where(status: :succeeded)
                   .order(created_at: :asc, id: :asc)
                   .last(HISTORY_LIMIT)
    end

    def content_for(message)
      return message.content unless message.image.attached?

      parts = []
      parts << { type: 'text', text: message.content } if message.content.present?
      parts << image_part(message.image)
      parts.one? ? parts.first : parts
    end

    def image_part(attachment)
      blob = attachment.blob
      data = Base64.strict_encode64(blob.download)
      {
        type: 'image_url',
        image_url: { url: "data:#{blob.content_type};base64,#{data}" }
      }
    end
  end
end
