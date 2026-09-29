class ChatReplyJob < ApplicationJob
  queue_as :default

  def perform(assistant_message_id)
    message = ChatMessage.assistant.pending.find_by(id: assistant_message_id)
    return unless message

    conversation = message.chat_conversation
    audit = LiteLlm::Client::AuditContext.new(user: conversation.user, source: 'chat')
    content = LiteLlm::Client.complete(
      messages: Chat::TranscriptBuilder.for(conversation),
      model: conversation.effective_model,
      audit:
    )
    message.update!(status: :succeeded, content:, error: nil)
  rescue LiteLlm::Error => e
    message&.update!(status: :failed, error: e.message)
  end
end
