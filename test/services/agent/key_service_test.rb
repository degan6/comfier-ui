# frozen_string_literal: true

require 'test_helper'

module Agent
  class KeyServiceTest < ActiveSupport::TestCase
    test 'generate produces a cmf key, its prefix and digest' do
      full, prefix, digest = KeyService.generate!

      assert full.start_with?(KeyService::PREFIX)
      assert_equal 47, full.length
      assert_equal KeyService::PREFIX_LEN, prefix.length
      assert_equal Digest::SHA256.hexdigest(full), digest
    end

    test 'matches? compares digests' do
      full, _, digest = KeyService.generate!

      assert KeyService.matches?(full, digest)
      assert_not KeyService.matches?('cmf_other', digest)
    end

    test 'the key itself is never stored' do
      backend = create_agent_backend!(owner: users(:alice))
      full = backend.issue_agent_key!
      key = backend.backend_keys.first

      assert_not_includes key.attributes.values.map(&:to_s), full
      assert_equal "cmf_#{key.prefix}…", key.display
    end
  end
end
