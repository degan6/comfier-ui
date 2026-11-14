class RemovePersonalApiTokenRevocation < ActiveRecord::Migration[8.1]
  def up
    execute 'DELETE FROM personal_api_tokens WHERE revoked_at IS NOT NULL'
    remove_column :personal_api_tokens, :revoked_at
  end

  def down
    add_column :personal_api_tokens, :revoked_at, :datetime
  end
end
