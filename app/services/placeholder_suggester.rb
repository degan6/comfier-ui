# Proposes {{placeholders}} for a ComfyUI API workflow without letting anything rewrite the graph.
#
# Rules classify most inputs; an LLM, when configured, only picks placeholders for the literal inputs the rules
# can't place, and replies with a short list of substitutions. Every substitution is validated, and applying
# them may change nothing but the substituted inputs.
class PlaceholderSuggester
  class Error < StandardError; end

  Candidate = Data.define(:node, :class_type, :title, :input, :value, :hints, :role, :latent_source,
                          :skip_reason) do
    def key = [node, input]
    def skip? = !skip_reason.nil?
    def label = title.presence || class_type
  end

  Substitution = Data.define(:node, :input, :placeholder, :old_value, :source) do
    def key = [node, input]
    def token = "{{#{placeholder}}}"
  end

  Applied = Data.define(:graph, :substitutions, :errors)

  Result = Data.define(:graph, :proposed_graph, :candidates, :substitutions, :unclassified, :dropped, :llm) do
    def rule_count = substitutions.count { it.source == 'rule' }
    def llm_count = substitutions.count { it.source == 'llm' }
    delegate :notes, to: :llm

    def node_label(node_id)
      node = graph.fetch(node_id)
      node.dig('_meta', 'title').presence || node['class_type']
    end

    # Literal inputs the admin can still point a placeholder at by hand.
    def manual_targets
      taken = substitutions.to_set(&:key)
      candidates.reject { taken.include?(it.key) }
    end
  end

  def self.call(workflow, user: nil, llm: LiteLlm::Client.configured?) = new(workflow, user:, llm:).call

  # Validates reviewed substitutions against the graph they're being saved into, then applies the valid ones.
  def self.apply(graph, substitutions)
    graph = WorkflowFormat.parse(graph)
    validation = Validator.call(substitutions, graph)
    Applied.new(graph: Applier.call(graph, validation.valid), substitutions: validation.valid,
                errors: validation.errors)
  end

  def initialize(workflow, user:, llm:)
    @workflow = workflow
    @user = user
    @llm = llm
  end

  def call
    graph = WorkflowFormat.parse(@workflow)
    candidates = Candidates.call(graph, LinkIndex.new(graph))
    rules = Rules.call(candidates, graph)
    ruled = Validator.call(rules.substitutions, graph)
    llm = llm_pass(rules.remaining, graph)
    combined = Validator.call(ruled.valid + llm.substitutions, graph)
    substitutions = combined.valid

    Result.new(graph:, proposed_graph: Applier.call(graph, substitutions), candidates:, substitutions:,
               unclassified: llm.ran? ? [] : rules.remaining, dropped: ruled.errors + llm.errors + combined.errors,
               llm:)
  end

  private

  def llm_pass(remaining, graph)
    return LlmPass::Outcome.skipped(:not_needed) if remaining.empty?
    return LlmPass::Outcome.skipped(:disabled) unless @llm

    LlmPass.call(remaining, graph, user: @user)
  end
end
