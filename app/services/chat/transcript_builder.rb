module Chat
  # Builds OpenAI-style message arrays for a conversation, including vision parts.
  class TranscriptBuilder
    MUSIC_STYLE_INSTRUCTIONS = <<~PROMPT.strip.freeze
      You can help draft and refine reusable music style presets. When asked for a preset,
      write a concise style description covering the requested genre, mood, instruments,
      vocals, tempo, and production feel. Keep song-specific lyrics separate.
      Users can choose "Save as music preset" on your reply, review the description,
      give it a name, and save it to their private presets in Settings.
      You cannot save, list, edit, or delete presets yourself. Do not claim that you have saved one.
      For a final preset draft, reply with just the reusable style description so it is ready to save.
    PROMPT

    HISTORY_LIMIT = 40

    def self.for(conversation) = new(conversation).build

    def initialize(conversation)
      @conversation = conversation
    end

    def build
      [{ role: 'system', content: MUSIC_STYLE_INSTRUCTIONS }] +
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
