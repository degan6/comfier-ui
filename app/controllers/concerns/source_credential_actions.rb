# Listing, saving, and deleting download tokens. Secrets are write-only: after saving, only the
# last four characters are ever shown.
module SourceCredentialActions
  extend ActiveSupport::Concern

  def index
    @credentials = credential_scope.order(:host)
    @credential = SourceCredential.new
  end

  def create
    host = SourceCredential.new(host: credential_params[:host]).host
    @credential = credential_scope.find_or_initialize_by(host:)
    @credential.assign_attributes(credential_params)
    if @credential.save
      audit(:source_credential_saved, "Saved a download token for #{@credential.host}")
      redirect_to credentials_path, notice: "Saved the token for #{@credential.host}.", status: :see_other
    else
      @credentials = credential_scope.order(:host)
      render :index, status: :unprocessable_content
    end
  end

  def destroy
    credential = credential_scope.find(params[:id])
    credential.destroy!
    audit(:source_credential_deleted, "Deleted the download token for #{credential.host}")
    redirect_to credentials_path, notice: "Deleted the token for #{credential.host}.", status: :see_other
  end

  private

  def credential_params = params.expect(source_credential: %i[host secret label])

  def audit(kind, message)
    ActivityLog.record(kind:, message:, user: current_user, request:)
  end
end
