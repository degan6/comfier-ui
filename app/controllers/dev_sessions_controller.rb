class DevSessionsController < ApplicationController
  allow_unauthenticated_access
  before_action { head :not_found unless DevLogin.enabled? }

  def create
    if DevLogin.authenticate(params[:email], params[:password])
      user = DevLogin.user
      ActivityLog.record(
        kind: :login,
        user:,
        message: "#{user.display_name} signed in (dev login)",
        details: { method: 'dev_login', email: params[:email].to_s },
        request:
      )
      redirect_to safe_return_path(sign_in(user)), status: :see_other
    else
      ActivityLog.record(
        kind: :login_failed,
        message: 'Developer login failed',
        details: { method: 'dev_login', email: params[:email].to_s },
        request:
      )
      redirect_to login_path, alert: 'That email and password don’t match the developer login.', status: :see_other
    end
  end
end
