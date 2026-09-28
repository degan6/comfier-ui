# frozen_string_literal: true

module Api
  module Agent
    class BaseController < ActionController::API
      before_action :authenticate_agent!

      attr_reader :current_backend

      private

      def authenticate_agent!
        result = ::Agent::Authenticator.from_header(request.authorization, ip: request.remote_ip)
        @current_backend = result.backend
      rescue ::Agent::Authenticator::AuthenticationError
        head :unauthorized
      end
    end
  end
end
