class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[new create failure]
  layout 'bare'

  def new
    redirect_to root_path if signed_in?
  end

  def create
    auth = request.env['omniauth.auth']
    if auth.nil?
      log_login_failed('Sign-in link expired or missing', reason: 'missing_auth')
      return redirect_to login_path, alert: 'That sign-in link has expired. Please sign in again.'
    end

    user = User.from_omniauth(auth)
    ActivityLog.record(
      kind: :login,
      user:,
      message: "#{user.display_name} signed in",
      details: { provider: user.provider, method: 'omniauth' },
      request:
    )
    return_to = sign_in(user)
    redirect_to safe_return_path(return_to), status: :see_other
  end

  def failure
    message = params[:message].to_s.humanize.presence || 'unknown error'
    log_login_failed("Sign-in failed: #{message}", reason: params[:message], strategy: params[:strategy])
    redirect_to login_path, alert: "Sign-in failed: #{message}"
  end

  def destroy
    user = current_user
    if user
      ActivityLog.record(
        kind: :logout,
        user:,
        message: "#{user.display_name} signed out",
        details: { method: 'session_destroy' },
        request:
      )
    end
    reset_session
    redirect_to login_path, notice: 'You have been signed out.', status: :see_other
  end

  private

  def log_login_failed(message, details)
    ActivityLog.record(kind: :login_failed, message:, details:, request:)
  end
end
