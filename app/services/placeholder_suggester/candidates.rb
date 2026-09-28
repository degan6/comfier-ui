class PlaceholderSuggester
  # Lists every literal input a placeholder could replace, with the hints needed to classify it, and marks
  # the ones that are obviously fixed (model files, wiring, empty strings, switches, internal settings).
  class Candidates
    TEXT_INPUTS = %w[text text_g text_l clip_l t5xxl prompt].freeze
    WIRING_INPUTS = %w[sampler_name scheduler filename_prefix format type device weight_dtype].freeze
    # Internal quality and size settings that look like dimensions but aren't.
    FIXED_SETTINGS = %w[resolution octree_resolution num_chunks threshold shift].freeze
    # Words in an input name that suggest a per-generation choice. Literals without one are fixed configuration.
    OPEN_WORDS = %w[seed steps step cfg guidance denoise width height batch length frames frame duration seconds
                    text prompt lyrics tags caption image].to_set.freeze

    def self.call(graph, links = LinkIndex.new(graph)) = new(graph, Hints.new(graph, links)).call

    def self.placeholder?(value) = value.is_a?(String) && value.match?(WorkflowRenderer::WHOLE_PLACEHOLDER)

    def self.literal?(value)
      [String, Numeric, TrueClass, FalseClass].any? { value.is_a?(it) } && !placeholder?(value)
    end

    def initialize(graph, hints)
      @graph = graph
      @hints = hints
    end

    def call
      @graph.flat_map do |node_id, node|
        node['inputs'].filter_map do |input, value|
          candidate(node_id, node, input, value) if self.class.literal?(value)
        end
      end
    end

    private

    def candidate(node_id, node, input, value)
      role = @hints.conditioning_role(node_id) if text_encoder?(node)
      latent = @hints.latent_source(node_id) if input == 'denoise'
      Candidate.new(
        node: node_id, class_type: node['class_type'], title: title(node), input:, value:,
        hints: [*role&.hints, latent&.hint].compact, role: role&.role, latent_source: latent&.source,
        skip_reason: skip_reason(input, value)
      )
    end

    def title(node)
      meta = node['_meta']
      meta['title'] if meta.is_a?(Hash) && meta['title'].is_a?(String)
    end

    def skip_reason(input, value)
      return :model_or_wiring if input.match?(/_name\d*\z/) || WIRING_INPUTS.include?(input)
      return :empty if value == ''
      return :switch if [true, false].include?(value)

      :fixed_setting if FIXED_SETTINGS.include?(input) || !open_input?(input)
    end

    def open_input?(input)
      TEXT_INPUTS.include?(input) || input.split(/[_\d]+/).any? { OPEN_WORDS.include?(it) }
    end

    def text_encoder?(node)
      node['class_type'].include?('TextEncode') || node['inputs'].values_at('text', 'prompt').any?(String)
    end
  end
end
