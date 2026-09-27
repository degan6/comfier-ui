class PlaceholderSuggester
  # Graph context for classifying an input: which side of a sampler a text encoder feeds, and whether a
  # sampler starts from an empty latent (txt2x) or an encoded image (img2img).
  class Hints
    SIDES = %w[positive negative].freeze
    CONDITIONING_HOPS = 10
    LATENT_HOPS = 4
    SAMPLER_HOPS = 3

    Role = Data.define(:role, :hints)
    Latent = Data.define(:source, :hint)

    def initialize(graph, links)
      @graph = graph
      @links = links
      @reach = {}
      @latents = {}
    end

    # Follows the conditioning forward until it lands on a positive or negative input. A `conditioning` input
    # is usually a pass-through (FluxGuidance, ConditioningSetArea); it only counts as positive when nothing
    # further downstream says otherwise, as with BasicGuider.
    def conditioning_role(node_id)
      found = reach(node_id, 0)
      roles = found.map(&:first).uniq
      role = case roles
             in [] then :unknown
             in [side] then side
             else :ambiguous
             end
      Role.new(role:, hints: found.map(&:last).uniq)
    end

    # Where the sampler this node belongs to gets its latent. Schedulers have no latent of their own, so they
    # borrow the one from the sampler they feed.
    def latent_source(node_id)
      @latents[node_id] ||= begin
        sampler = latent_consumer(node_id)
        sampler ? trace_latent(@links.source(sampler, 'latent_image')) : Latent.new(source: :unknown, hint: nil)
      end
    end

    private

    def reach(node_id, depth)
      @reach[node_id] ||= @links.consumers(node_id).flat_map { edge_roles(it, depth) }
    end

    def edge_roles(edge, depth)
      hint = "feeds #{@graph.dig(edge.node, 'class_type')}.#{edge.input}"
      return [[edge.input.to_sym, hint]] if SIDES.include?(edge.input)

      downstream = depth + 1 < CONDITIONING_HOPS ? reach(edge.node, depth + 1) : []
      downstream.empty? && edge.input == 'conditioning' ? [[:positive, hint]] : downstream
    end

    def latent_consumer(node_id)
      frontier = [node_id]
      SAMPLER_HOPS.times do
        found = frontier.find { @links.source(it, 'latent_image') }
        return found if found

        frontier = frontier.flat_map { @links.consumers(it).map(&:node) }.uniq
      end
      nil
    end

    def trace_latent(source)
      LATENT_HOPS.times do
        break unless source

        latent = classify_latent(@graph.dig(source, 'class_type'))
        return latent if latent

        source = upstream_latent(source)
      end
      Latent.new(source: :unknown, hint: nil)
    end

    def classify_latent(class_type)
      if class_type.start_with?('Empty')
        Latent.new(source: :empty, hint: "latent from #{class_type} (empty; txt2x)")
      elsif class_type.include?('VAEEncode')
        Latent.new(source: :encoded, hint: "latent from #{class_type} (encoded image; img2img)")
      end
    end

    def upstream_latent(node_id)
      names = @graph.dig(node_id, 'inputs').keys
      preferred = %w[latent_image samples latent] + names.select { it.include?('latent') }
      preferred.lazy.filter_map { @links.source(node_id, it) }.first
    end
  end
end
