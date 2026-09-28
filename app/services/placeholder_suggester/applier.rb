class PlaceholderSuggester
  # Writes validated substitutions into a copy of the graph and proves nothing else changed.
  module Applier
    # Raised when applying would alter anything but the substituted inputs. That's a bug, never bad input.
    class IntegrityError < StandardError; end

    module_function

    def call(graph, substitutions)
      applied = graph.deep_dup
      substitutions.each { applied.fetch(it.node).fetch('inputs')[it.input] = it.token }
      assert_only_substituted!(graph, applied, substitutions)
      applied
    end

    def assert_only_substituted!(before, after, substitutions)
      expected = substitutions.to_h { [it.key, it.token] }
      raise IntegrityError, 'node IDs changed' unless before.keys == after.keys

      before.each do |node_id, node|
        changed = after.fetch(node_id)
        unchanged = node.except('inputs') == changed.except('inputs')
        raise IntegrityError, "node #{node_id} changed outside its inputs" unless unchanged

        assert_inputs!(node_id, node['inputs'], changed['inputs'], expected)
      end
    end

    def assert_inputs!(node_id, before, after, expected)
      raise IntegrityError, "node #{node_id} gained or lost inputs" unless before.keys == after.keys

      before.each do |input, value|
        wanted = expected.fetch([node_id, input], value)
        raise IntegrityError, %(node #{node_id} input "#{input}" changed unexpectedly) unless after[input] == wanted
      end
    end
  end
end
