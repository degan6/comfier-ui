class CreateChat < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_conversations do |t|
      t.references :user, null: false, foreign_key: true
      t.string :title
      t.string :model

      t.timestamps
    end

    add_index :chat_conversations, %i[user_id updated_at]

    create_table :chat_messages do |t|
      t.references :chat_conversation, null: false, foreign_key: true
      t.string :role, null: false
      t.text :content
      t.string :status, null: false, default: 'succeeded'
      t.text :error

      t.timestamps
    end

    change_table :app_settings, bulk: true do |t|
      t.string :chat_default_model
      t.text :chat_notice_text
      t.string :chat_notice_url
    end
  end
end
