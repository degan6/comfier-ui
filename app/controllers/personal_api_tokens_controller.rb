# Token creation renders the secret directly, never putting it in a URL, session, or flash.
class PersonalApiTokensController < ApplicationController
  include SettingsNav

  before_action :prevent_caching
  before_action :load_tokens

  rate_limit to: 10, within: 1.hour, only: :create, by: -> { current_user.id },
             with: -> { redirect_to personal_api_tokens_path, alert: 'Too many new tokens. Try again later.' }

  def index
    @token = current_user.personal_api_tokens.new
  end

  def create
    @token, @new_secret = PersonalApiToken.issue!(user: current_user, name: params.require(:personal_api_token)[:name])
    audit(:api_token_created, "Created API token #{@token.name} (#{@token.display})")
    render :index, status: :created
  rescue ActiveRecord::RecordInvalid => e
    @token = e.record
    render :index, status: :unprocessable_content
  end

  def destroy
    token = current_user.personal_api_tokens.find(params[:id])
    token.destroy!
    audit(:api_token_deleted, "Deleted API token #{token.name} (#{token.display})")
    redirect_to personal_api_tokens_path, notice: 'API token deleted.', status: :see_other
  end

  private

  def audit(kind, message)
    ActivityLog.record(kind:, message:, user: current_user, request:)
  end

  def load_tokens
    @tokens = current_user.personal_api_tokens.order(created_at: :desc, id: :desc)
  end

  def prevent_caching
    response.headers['Cache-Control'] = 'no-store'
  end
end
