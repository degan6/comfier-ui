class ChatConversationsController < ApplicationController
  include ChatPage

  before_action :load_chat_availability
  before_action :load_chat_sidebar, if: -> { chat_available? }, except: :destroy

  def index
    return render :unconfigured unless chat_available?

    latest = @conversations.first
    return redirect_to chat_path(latest) if latest

    render :index
  end

  def show
    return render :unconfigured unless chat_available?

    @conversation = current_user.chat_conversations.find(params[:id])
  end

  def create
    return redirect_to chats_path, alert: 'Chat is not available.' unless chat_available?

    conversation = current_user.chat_conversations.create!(model: params[:model].presence || default_chat_model)
    start_music_style_conversation(conversation) if params[:purpose] == 'music_style'
    redirect_to chat_path(conversation), status: :see_other
  end

  def update
    conversation = current_user.chat_conversations.find(params[:id])
    if conversation.update(conversation_params)
      redirect_to chat_path(conversation), notice: 'Model updated.', status: :see_other
    else
      @conversation = conversation
      render :show, status: :unprocessable_content
    end
  end

  def notice_redirect
    url = AppSetting.current.allowed_chat_notice_redirect_url
    unless url
      redirect_to chats_path, alert: 'Notice link is not available.', status: :see_other
      return
    end

    redirect_to url, allow_other_host: true
  end

  def destroy
    unless LiteLlm::Client.configured?
      redirect_to chats_path, alert: 'Chat is not available.', status: :see_other
      return
    end

    conversation = current_user.chat_conversations.find(params[:id])
    conversation.destroy!
    next_conversation = current_user.chat_conversations.find_by(id: params[:return_to]) ||
                        current_user.chat_conversations.recent_first.first
    redirect_to next_conversation ? chat_path(next_conversation) : chats_path,
                notice: 'Conversation deleted.', status: :see_other
  end

  private

  def start_music_style_conversation(conversation)
    prompt = 'Help me create a reusable music style preset. Ask me about the sound I want, ' \
             'then help refine a style description I can save.'
    conversation.chat_messages.create!(role: :user, content: prompt)
    conversation.set_title_from!('Create a music style preset')
    reply = conversation.chat_messages.create!(role: :assistant, status: :pending, content: '')
    ChatReplyJob.perform_later(reply.id)
  end

  def conversation_params
    params.expect(chat_conversation: [:model])
  end
end
