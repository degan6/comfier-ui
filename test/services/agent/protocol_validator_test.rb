# frozen_string_literal: true

require 'test_helper'

module Agent
  class ProtocolValidatorTest < ActiveSupport::TestCase
    HELLO = { 'type' => 'hello', 'protocol' => 1, 'agent_version' => '1', 'backend_name' => 'x' }.freeze

    test 'accepts a valid hello' do
      assert ProtocolValidator.validate_inbound!(HELLO.dup)
    end

    test 'unknown inbound types are reported, not raised' do
      assert_equal :unknown, ProtocolValidator.validate_inbound!({ 'type' => 'nope' })
    end

    test 'rejects hello with another protocol' do
      error = assert_raises(ProtocolValidator::ValidationError) do
        ProtocolValidator.validate_inbound!(HELLO.merge('protocol' => 2))
      end
      assert_match %r{/protocol}, error.message
    end

    test 'rejects status without accepting' do
      assert_raises(ProtocolValidator::ValidationError) do
        ProtocolValidator.validate_inbound!({ 'type' => 'status', 'state' => 'idle' })
      end
    end

    test 'job.completed outputs need upload ids' do
      assert_raises(ProtocolValidator::ValidationError) do
        ProtocolValidator.validate_inbound!({ 'type' => 'job.completed', 'job_id' => 'j_1', 'outputs' => [{}] })
      end
    end

    test 'object_info chunks must say how many there are' do
      assert_raises(ProtocolValidator::ValidationError) do
        ProtocolValidator.validate_inbound!({ 'type' => 'object_info', 'hash' => 'h', 'index' => 0,
                                              'encoding' => 'gzip+base64', 'data' => 'x' })
      end
    end

    test 'every message the frontend sends validates' do
      messages = [
        { 'type' => 'job.assign', 'request_id' => 'r_1', 'job_id' => 'j_1', 'workflow' => { '1' => {} },
          'inputs' => [{ 'id' => 'in_0', 'url' => 'https://x.test/i', 'filename' => 'a.png', 'bytes' => 3 }],
          'upload_url' => 'https://x.test/o', 'requires' => { 'node_types' => [], 'models' => {} },
          'timeout_s' => 600 },
        { 'type' => 'job.cancel', 'job_id' => 'j_1' },
        { 'type' => 'model.download', 'download_id' => 'd_1', 'url' => 'https://hf.test/a', 'folder' => 'vae',
          'filename' => 'a.safetensors', 'headers' => {}, 'overwrite' => false },
        { 'type' => 'model.download.cancel', 'download_id' => 'd_1' },
        { 'type' => 'config.pause' }, { 'type' => 'config.resume' },
        { 'type' => 'inventory.refresh' }, { 'type' => 'object_info.request' }
      ]

      messages.each do |message|
        assert_empty ProtocolValidator.errors_for(message), message['type']
      end
    end

    test 'the Rails and agent copies of the schema are identical' do
      rails_copy = Rails.root.join('protocol/agent-v1.schema.json').read
      agent_copy = Rails.root.join('comfyui/comfier_agent/protocol/agent-v1.schema.json').read

      assert_equal JSON.parse(rails_copy), JSON.parse(agent_copy),
                   'Copy protocol/agent-v1.schema.json to comfyui/comfier_agent/protocol/'
    end
  end
end
