# frozen_string_literal: true

# An API key an agent uses to connect. Only a sha256 digest is stored; the key itself is shown once.
class BackendKey < ApplicationRecord
  ROTATION_GRACE = 24.hours

  belongs_to :backend

  scope :active, -> { where(revoked_at: nil).where('expires_at IS NULL OR expires_at > ?', Time.current) }
  scope :recent, -> { order(created_at: :desc) }

  def revoked? = revoked_at.present?
  def expired? = expires_at.present? && expires_at <= Time.current
  def usable? = !revoked? && !expired?

  def display = Agent::KeyService.display(prefix)

  def touch_used!(ip:)
    update_columns(last_used_at: Time.current, last_ip: ip) # rubocop:disable Rails/SkipsModelValidations
  end

  def revoke!
    update!(revoked_at: Time.current)
  end
end
