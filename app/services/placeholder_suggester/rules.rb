class PlaceholderSuggester
  # Deterministic placeholders for the node types every workflow uses. The first matching rule decides:
  # a placeholder name substitutes, :skip leaves the value fixed, and nil hands the input to the LLM.
  class Rules
    Rule = Data.define(:matches, :inputs, :placeholder) do
      def applies?(candidate, node) = inputs.include?(candidate.input) && matches.call(candidate, node)
      def decide(candidate) = placeholder.respond_to?(:call) ? placeholder.call(candidate) : placeholder
    end

    Outcome = Data.define(:substitutions, :skipped, :remaining)

    SAMPLER = lambda do |candidate, node|
      candidate.class_type.include?('Sampler') || (node['inputs'].key?('steps') && node['inputs'].key?('cfg'))
    end
    EMPTY_LATENT = lambda do |candidate, _|
      candidate.class_type.start_with?('Empty') && candidate.class_type.include?('Latent')
    end
    TEXT_ENCODER = ->(candidate, _) { !candidate.role.nil? && candidate.value.is_a?(String) }
    DENOISE = ->(candidate) { { encoded: 'denoise', empty: :skip }[candidate.latent_source] }
    PROMPT = ->(candidate) { { positive: 'prompt', negative: 'negative_prompt' }[candidate.role] }

    def self.class_is(name) = ->(candidate, _) { candidate.class_type == name }
    def self.class_includes(text) = ->(candidate, _) { candidate.class_type.include?(text) }

    RULES = [
      Rule.new(SAMPLER, %w[seed noise_seed], 'seed'),
      Rule.new(SAMPLER, %w[steps], 'steps'),
      Rule.new(SAMPLER, %w[cfg], 'cfg'),
      Rule.new(SAMPLER, %w[denoise], DENOISE),
      Rule.new(class_is('RandomNoise'), %w[noise_seed], 'seed'),
      Rule.new(class_includes('Scheduler'), %w[steps], 'steps'),
      Rule.new(class_is('BasicScheduler'), %w[denoise], DENOISE),
      Rule.new(class_is('CFGGuider'), %w[cfg], 'cfg'),
      Rule.new(class_includes('LoadImage'), %w[image], 'image'),
      Rule.new(EMPTY_LATENT, %w[width], 'width'),
      Rule.new(EMPTY_LATENT, %w[height], 'height'),
      Rule.new(EMPTY_LATENT, %w[batch_size], 'batch_size'),
      Rule.new(EMPTY_LATENT, %w[length frames num_frames], 'frames'),
      Rule.new(TEXT_ENCODER, Candidates::TEXT_INPUTS, PROMPT)
    ].freeze

    def self.call(candidates, graph) = new(graph).call(candidates)

    def initialize(graph)
      @graph = graph
    end

    def call(candidates)
      substitutions = []
      skipped = []
      remaining = []
      candidates.each do |candidate|
        case decide(candidate)
        in String => placeholder then substitutions << substitution(candidate, placeholder)
        in :skip then skipped << candidate
        in nil then remaining << candidate
        end
      end
      Outcome.new(substitutions:, skipped:, remaining:)
    end

    private

    def decide(candidate)
      return :skip if candidate.skip?

      rule = RULES.find { it.applies?(candidate, @graph.fetch(candidate.node)) }
      rule&.decide(candidate)
    end

    def substitution(candidate, placeholder)
      Substitution.new(node: candidate.node, input: candidate.input, placeholder:, old_value: candidate.value,
                       source: 'rule')
    end
  end
end
