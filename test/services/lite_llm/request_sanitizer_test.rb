require 'test_helper'

module LiteLlm
  class RequestSanitizerTest < ActiveSupport::TestCase
    test 'redacts base64 image urls in message content arrays' do
      body = {
        'messages' => [
          {
            'role' => 'user',
            'content' => [
              { 'type' => 'text', 'text' => 'look' },
              { 'type' => 'image_url', 'image_url' => { 'url' => 'data:image/png;base64,AAAA' } }
            ]
          }
        ]
      }

      sanitized = RequestSanitizer.sanitize(body)
      image_url = sanitized.dig('messages', 0, 'content', 1, 'image_url', 'url')

      assert_match(/\[image/, image_url)
      assert_no_match(/AAAA/, image_url)
    end
  end
end
