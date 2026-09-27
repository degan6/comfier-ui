# frozen_string_literal: true

module Agent
  # Authorization headers for a model download. A credential applies only to its own host and
  # that host's subdomains; the server owner's credential wins over the global one. Nothing is
  # sent for hosts without a credential.
  module CredentialHeaders
    module_function

    def for_url(url, backend:)
      host = URI.parse(url.to_s).host.to_s.downcase
      return {} if host.empty?

      credential = find(host, backend.owner_user_id)
      credential ? { 'Authorization' => "Bearer #{credential.secret}" } : {}
    rescue URI::InvalidURIError
      {}
    end

    def find(host, owner_user_id)
      candidates = SourceCredential.where(owner_user_id: [owner_user_id, nil].uniq).to_a
                                   .select { it.matches_host?(host) }
      candidates.min_by { [it.owner_user_id ? 0 : 1, -it.host.length] }
    end
  end
end
