class CreateActivityLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :activity_logs do |t|
      t.string :kind, null: false
      t.references :user, foreign_key: true
      t.references :subject, polymorphic: true
      t.text :message, null: false
      t.jsonb :details, null: false, default: {}
      t.string :ip_address
      t.text :user_agent
      t.datetime :created_at, null: false
    end

    add_index :activity_logs, :created_at, order: { created_at: :desc }
    add_index :activity_logs, :kind
    add_index :activity_logs, %i[kind created_at]
  end
end
