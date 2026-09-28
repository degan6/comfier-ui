require 'test_helper'

class ChatMessageTest < ActiveSupport::TestCase
  test 'user message requires content or an image' do
    message = ChatMessage.new(chat_conversation: chat_conversations(:alice_chat), role: :user, content: nil)

    assert_not message.valid?
    assert_includes message.errors[:content], "can't be blank"
  end

  test 'rejects unsupported image types' do
    message = ChatMessage.new(chat_conversation: chat_conversations(:alice_chat), role: :user, content: 'see this')
    message.image.attach(
      io: StringIO.new('not an image'),
      filename: 'note.txt',
      content_type: 'text/plain'
    )

    assert_not message.valid?
    assert_includes message.errors[:image], 'must be PNG, JPEG, WebP, or GIF'
  end
end
