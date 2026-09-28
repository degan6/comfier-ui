module Admin
  # Global download tokens, used for any server whose owner hasn't saved their own for that host.
  class SourceCredentialsController < BaseController
    include SourceCredentialActions

    private

    def credential_scope = SourceCredential.global
    def credentials_path = admin_source_credentials_path
  end
end
