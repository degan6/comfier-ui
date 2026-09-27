# frozen_string_literal: true

module Agent
  # Backend API keys: `cmf_` + 32 random bytes in base62. The first 8 characters after `cmf_`
  # are a plain-text prefix for lookup and display; only sha256(key) is stored.
  module KeyService
    PREFIX = 'cmf_'
    PREFIX_LEN = 8
    ALPHABET = [*'0'..'9', *'A'..'Z', *'a'..'z'].freeze

    module_function

    # Returns [full_key, prefix, digest].
    def generate!
      body = base62(SecureRandom.random_bytes(32))
      full = "#{PREFIX}#{body}"
      [full, prefix_of(full), digest(full)]
    end

    def prefix_of(token) = token.to_s.delete_prefix(PREFIX)[0, PREFIX_LEN]

    def digest(token) = Digest::SHA256.hexdigest(token.to_s)

    def matches?(token, stored_digest)
      ActiveSupport::SecurityUtils.secure_compare(digest(token), stored_digest.to_s)
    end

    def display(prefix) = "#{PREFIX}#{prefix}…"

    def base62(bytes)
      number = bytes.unpack1('H*').to_i(16)
      out = +''
      while number.positive?
        number, remainder = number.divmod(62)
        out << ALPHABET[remainder]
      end
      out.reverse.rjust(43, '0')
    end
  end
end
