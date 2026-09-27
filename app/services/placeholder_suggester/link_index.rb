class PlaceholderSuggester
  # The wiring of an API workflow: which inputs read from which nodes, in both directions.
  class LinkIndex
    Edge = Data.define(:node, :input)

    # A link is [source node id, output index] naming a node that exists.
    def self.link?(value, graph)
      value.is_a?(Array) && value.size == 2 && value[1].is_a?(Integer) &&
        (value[0].is_a?(String) || value[0].is_a?(Integer)) && graph.key?(value[0].to_s)
    end

    def initialize(graph)
      @consumers = Hash.new { |hash, key| hash[key] = [] }
      @sources = {}
      graph.each do |node_id, node|
        node['inputs'].each do |input, value|
          next unless self.class.link?(value, graph)

          source = value[0].to_s
          @consumers[source] << Edge.new(node: node_id, input:)
          @sources[[node_id, input]] = source
        end
      end
    end

    # Every input that reads from this node.
    def consumers(node_id) = @consumers.fetch(node_id, [])

    # The node feeding a linked input, or nil when the input is a literal.
    def source(node_id, input) = @sources[[node_id, input]]
  end
end
