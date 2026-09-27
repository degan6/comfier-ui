require 'test_helper'

class PlaceholderSuggester
  class ApplierTest < ActiveSupport::TestCase
    setup do
      @graph = JSON.parse(file_fixture('workflows/hunyuan3d.json').read)
    end

    test 'changes only the substituted paths' do
      applied = Applier.call(@graph, [sub('7', 'seed', 'seed'), sub('4', 'batch_size', 'batch_size')])

      assert_equal @graph.keys, applied.keys
      assert_equal @graph['7']['inputs'].keys, applied['7']['inputs'].keys
      assert_equal({ '7.seed' => '{{seed}}', '4.batch_size' => '{{batch_size}}' }, differences(@graph, applied))
      assert_equal 952_805_179_515_179, @graph.dig('7', 'inputs', 'seed')
    end

    test 'the safety check catches anything else changing' do
      tampered = @graph.deep_dup
      tampered['7']['inputs']['seed'] = '{{seed}}'
      tampered['7']['inputs']['model'] = ['1', 0]

      error = assert_raises(Applier::IntegrityError) do
        Applier.assert_only_substituted!(@graph, tampered, [sub('7', 'seed', 'seed')])
      end
      assert_match(/"model" changed/, error.message)
    end

    test 'the safety check catches new inputs and class changes' do
      assert_raises(Applier::IntegrityError) { Applier.call(@graph, [sub('7', 'invented', 'seed')]) }

      renamed = @graph.deep_dup
      renamed['7']['class_type'] = 'KSamplerAdvanced'
      assert_raises(Applier::IntegrityError) { Applier.assert_only_substituted!(@graph, renamed, []) }
    end

    private

    def sub(node, input, placeholder)
      Substitution.new(node:, input:, placeholder:, old_value: nil, source: 'rule')
    end

    def differences(before, after)
      before.each_with_object({}) do |(node_id, node), changed|
        node['inputs'].each do |input, value|
          now = after.dig(node_id, 'inputs', input)
          changed["#{node_id}.#{input}"] = now unless now == value
        end
      end
    end
  end
end
