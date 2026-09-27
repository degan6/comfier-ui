# A user's own download tokens, used only for model downloads onto their servers.
class SourceCredentialsController < ApplicationController
  include SettingsNav
  include SourceCredentialActions

  private

  def credential_scope = current_user.source_credentials
  def credentials_path = source_credentials_path
end
