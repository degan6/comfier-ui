class AddPromptPreprocessingToWorkflows < ActiveRecord::Migration[8.1]
  def change
    change_table :workflows, bulk: true do |t|
      t.boolean :prompt_preprocessing_enabled, default: false, null: false
      t.text :prompt_preprocessing_system_prompt
    end
  end
end
