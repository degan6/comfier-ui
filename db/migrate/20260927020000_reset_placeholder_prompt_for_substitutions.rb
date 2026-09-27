# Custom placeholder prompts were written for the model to return a whole rewritten workflow. The assistant now
# only accepts a list of substitutions, so those prompts would contradict it; fall back to the built-in prompt.
class ResetPlaceholderPromptForSubstitutions < ActiveRecord::Migration[8.1]
  def up
    execute 'UPDATE app_settings SET placeholder_prompt = NULL'
  end

  def down; end
end
