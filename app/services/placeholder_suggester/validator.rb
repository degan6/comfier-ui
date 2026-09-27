class PlaceholderSuggester
  # Drops any substitution that would touch wiring, a missing input, an existing placeholder or an unknown
  # placeholder name. Errors are phrased for the LLM, which gets them back on its retry.
  class Validator
    Validation = Data.define(:valid, :errors)

    # `allowed` limits substitutions to these [node, input] pairs, so an LLM can't reach past the inputs it was
    # asked about (such as a checkpoint filename the rules deliberately skipped).
    def self.call(substitutions, graph, allowed: nil) = new(graph, allowed).call(substitutions)

    def initialize(graph, allowed)
      @graph = graph
      @allowed = allowed&.to_set
    end

    def call(substitutions)
      errors = []
      checked = substitutions.filter_map do |substitution|
        error = problem(substitution)
        errors << error if error
        substitution.with(old_value: current_value(substitution)) unless error
      end
      valid = first_per_input(checked, errors)
      errors.each { Rails.logger.info("Placeholder substitution dropped: #{it}") }
      Validation.new(valid:, errors:)
    end

    private

    def problem(substitution)
      node_id, input = substitution.key
      inputs = @graph.dig(node_id, 'inputs')
      return "node #{node_id} doesn't exist" unless inputs
      return %(node #{node_id} has no input "#{input}") unless inputs.key?(input)
      return %(placeholder "#{substitution.placeholder}" is not allowed) unless known?(substitution.placeholder)

      where = describe(substitution)
      value_problem(where, inputs[input]) ||
        ("#{where} wasn't one of the listed inputs" if @allowed&.exclude?(substitution.key))
    end

    def value_problem(where, value)
      return "#{where} is wired to another node" if LinkIndex.link?(value, @graph)
      return "#{where} is already a placeholder" if Candidates.placeholder?(value)

      "#{where} isn't a single literal value" unless Candidates.literal?(value)
    end

    def describe(substitution) = %(node #{substitution.node} input "#{substitution.input}")

    def known?(placeholder) = placeholder.is_a?(String) && Workflow::PLACEHOLDERS.key?(placeholder)

    def current_value(substitution) = @graph.dig(substitution.node, 'inputs', substitution.input)

    # One placeholder per input. A rule beats the LLM; otherwise the first suggestion stands.
    def first_per_input(substitutions, errors)
      keep = substitutions.group_by(&:key).transform_values do |group|
        group.find { it.source == 'rule' } || group.first
      end
      substitutions.select do |substitution|
        kept = keep.fetch(substitution.key)
        next true if kept.equal?(substitution)

        errors << "#{describe(substitution)} was listed more than once; kept #{kept.token}"
        false
      end
    end
  end
end
