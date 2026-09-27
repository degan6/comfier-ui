# A token for downloading models from one host (huggingface.co, civitai.com). Global when
# owner_user is nil (admin-managed); otherwise used only for that user's servers.
class SourceCredential < ApplicationRecord
  encrypts :secret

  belongs_to :owner_user, class_name: 'User', optional: true

  normalizes :host, with: ->(host) { host.to_s.strip.downcase.sub(%r{\Ahttps?://}, '').sub(%r{/.*\z}, '') }

  validates :host, presence: true, format: { with: /\A[a-z0-9.-]+\z/ }, uniqueness: { scope: :owner_user_id }
  validates :secret, presence: true
  validates :label, length: { maximum: 80 }

  before_validation { self.last4 = secret.to_s.last(4) if secret.present? }

  scope :global, -> { where(owner_user_id: nil) }

  def global? = owner_user_id.nil?

  # Matches the host itself and its subdomains (cdn-lfs.huggingface.co for huggingface.co).
  def matches_host?(other)
    other = other.to_s.downcase
    other == host || other.end_with?(".#{host}")
  end
end
