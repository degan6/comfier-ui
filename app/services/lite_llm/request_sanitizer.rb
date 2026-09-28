module LiteLlm
  # Strips bulky image data from chat payloads before they are written to ActivityLog.
  module RequestSanitizer
    module_function

    def sanitize(body)
      body.deep_dup.tap { |copy| redact_messages!(copy['messages'] || copy[:messages]) }
    end

    def redact_messages!(messages)
      return unless messages.is_a?(Array)

      messages.each do |message|
        content = message['content'] || message[:content]
        next unless content.is_a?(Array)

        message['content'] = content.map { |part| redact_part(part) }
        message[:content] = message['content'] if message.key?(:content)
      end
    end

    def redact_part(part)
      return part unless image_part?(part)

      url = part.dig('image_url', 'url') || part.dig(:image_url, :url)
      size = data_url_byte_size(url)
      label = size ? "[image #{size} KB]" : '[image]'
      part.deep_dup.tap do |copy|
        if copy['image_url']
          copy['image_url'] = { 'url' => label }
        else
          copy[:image_url] = { url: label }
        end
      end
    end

    def image_part?(part)
      (part['type'] || part[:type]) == 'image_url'
    end

    def data_url_byte_size(url)
      return unless url.to_s.start_with?('data:')

      encoded = url.to_s.split(',', 2).last
      return if encoded.blank?

      ((encoded.length * 3) / 4.0 / 1024).round
    end
  end
end
