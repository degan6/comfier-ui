# frozen_string_literal: true

module Agent
  # Sends messages to agents from any process. When this process holds the backend's socket the
  # command runs directly; otherwise it is published for the web process that does.
  module Commands
    CHANNEL = 'commands'

    module_function

    def send_message(backend_id, message)
      ProtocolValidator.validate_outbound!(message)
      run('send', backend_id, 'message' => message)
    end

    def close(backend_id, code, reason)
      run('close', backend_id, 'code' => code, 'reason' => reason)
    end

    def run(op, backend_id, args)
      return execute(op, backend_id, args) if Hub.instance.local?(backend_id)

      Store.publish(CHANNEL, JSON.generate(args.merge('op' => op, 'backend_id' => backend_id)))
      true
    end

    def execute(op, backend_id, args)
      case op
      when 'send' then Hub.instance.send_message(backend_id, args['message'])
      when 'close' then Hub.instance.close(backend_id, args['code'], args['reason'])
      end
    end

    def execute_payload(payload)
      data = JSON.parse(payload)
      backend_id = data['backend_id'].to_i
      return unless Hub.instance.local?(backend_id)

      execute(data['op'], backend_id, data)
    rescue JSON::ParserError => e
      Rails.logger.warn("[Agent] bad command payload: #{e.message}")
    end
  end
end
