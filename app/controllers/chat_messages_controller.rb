class ChatMessagesController < ApplicationController
  include ChatPage

  before_action :load_chat_availability
  before_action :load_chat_sidebar, if: -> { chat_available? }
  before_action :set_conversation

  def create
    return redirect_to chats_path, alert: 'Chat is not available.' unless chat_available?
    return render_show_error('Wait for the current reply to finish.') if @conversation.reply_pending?

    user_message = build_user_message
    return render_show_error(user_message.errors.full_messages.to_sentence) unless user_message.save

    record_user_turn(user_message)
    start_assistant_reply
    respond_to_create
  end

  def retry
    message = @conversation.chat_messages.assistant.failed.find(params[:id])
    return render_show_error('A reply is already in progress.') if @conversation.reply_pending?

    message.update!(status: :pending, content: '', error: nil)
    ChatReplyJob.perform_later(message.id)

    respond_to do |format|
      format.turbo_stream { render turbo_stream: retry_streams(message) }
      format.html { redirect_to chat_path(@conversation) }
    end
  end

  private

  def set_conversation
    @conversation = current_user.chat_conversations.find(params[:chat_id])
  end

  def build_user_message
    message = @conversation.chat_messages.build(role: :user, content: message_params[:content])
    message.image.attach(message_params[:image]) if message_params[:image].present?
    message
  end

  def record_user_turn(user_message)
    @conversation.set_title_from!(user_message.content)
    @conversation.update!(model: message_params[:model]) if message_params[:model].present?
    @user_message = user_message
  end

  def start_assistant_reply
    @assistant_message = @conversation.chat_messages.create!(role: :assistant, status: :pending, content: '')
    ChatReplyJob.perform_later(@assistant_message.id)
    @conversation.reload
  end

  def respond_to_create
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to chat_path(@conversation) }
    end
  end

  def retry_streams(message)
    [
      turbo_stream.replace(message, partial: 'chat_messages/message', locals: { message: }),
      turbo_stream.replace(
        'chat_composer',
        partial: 'chat_conversations/composer',
        locals: @conversation.composer_locals(pending: true, chat_models: @chat_models)
      )
    ]
  end

  def message_params
    params.expect(chat_message: %i[content model image])
  end

  def render_show_error(text)
    @conversation.reload
    flash.now[:alert] = text
    render 'chat_conversations/show', status: :unprocessable_content
  end
end
