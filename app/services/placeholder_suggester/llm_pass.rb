class PlaceholderSuggester
  # Asks the LLM to place only the candidates the rules couldn't. The reply is a list of substitutions held to
  # a JSON schema; invalid ones go back to the model once, and whatever is still invalid after that is dropped.
  class LlmPass
    SCHEMA_NAME = 'placeholder_substitutions'.freeze
    ATTEMPTS = 2

    Debug = Data.define(:model, :endpoint, :system_prompt, :transcript)

    # status is :ran, :failed (the LLM couldn't be reached or never gave a readable reply), :disabled (not
    # configured) or :not_needed (the rules classified everything).
    Outcome = Data.define(:status, :substitutions, :errors, :notes, :failure, :debug) do
      def self.skipped(status) = new(status:, substitutions: [], errors: [], notes: '', failure: nil, debug: nil)

      def ran? = status == :ran
    end

    Reply = Data.define(:substitutions, :notes, :problems, :readable)

    def self.call(candidates, graph, user: nil) = new(candidates, graph, user:).call

    def initialize(candidates, graph, user:)
      @candidates = candidates
      @graph = graph
      @user = user
      @system = AppSetting.current.placeholder_prompt_or_default
      @transcript = []
    end

    def call
      ATTEMPTS.times do |attempt|
        @reply = ask(attempt.zero? ? Prompt.user_message(@candidates) : retry_message)
        @validation = Validator.call(@reply.substitutions, @graph, allowed: @candidates.map(&:key))
        break if problems.empty?
      end
      finished
    rescue LiteLlm::Error => e
      @validation ? finished(["retry failed: #{e.message}"]) : outcome(:failed, failure: e.message)
    end

    private

    def problems = @reply.problems + @validation.errors

    # A failed retry still leaves the first reply's valid substitutions standing.
    def finished(extra = [])
      unless @reply.readable
        return outcome(:failed, errors: problems + extra, failure: 'the LLM never gave a readable reply')
      end

      outcome(:ran, substitutions: @validation.valid, errors: problems + extra, notes: @reply.notes)
    end

    def ask(message)
      history = @transcript.dup
      @transcript << { role: 'user', content: message }
      content = LiteLlm::Client.chat(system: @system, user: message, history:, temperature: 0, audit:,
                                     json_schema: { name: SCHEMA_NAME, schema: Prompt.schema })
      @transcript << { role: 'assistant', content: }
      parse(content)
    end

    def parse(content)
      json = JSON.parse(strip_fences(content))
      return unreadable('the reply must be a JSON object') unless json.is_a?(Hash)

      rows = Array(json['substitutions'])
      Reply.new(substitutions: rows.filter_map { substitution(it) }, notes: json['notes'].to_s.strip,
                problems: rows.grep_v(Hash).map { "#{it.to_json.truncate(80)} isn't an object" },
                readable: true)
    rescue JSON::ParserError => e
      unreadable("the reply wasn't valid JSON (#{e.message.truncate(120)})")
    end

    def strip_fences(content)
      text = content.to_s.strip
      text = Regexp.last_match(1) if text =~ /\A```(?:json)?\s*(.*?)```\z/m
      text
    end

    def unreadable(problem) = Reply.new(substitutions: [], notes: '', problems: [problem], readable: false)

    def substitution(row)
      return unless row.is_a?(Hash)

      Substitution.new(node: row['node'].to_s, input: row['input'].to_s, placeholder: row['placeholder'].to_s,
                       old_value: nil, source: 'llm')
    end

    def retry_message
      "Some of those substitutions can't be used: #{problems.join('; ')}. " \
        'Reply again with the corrected JSON for the same input lines.'
    end

    def outcome(status, substitutions: [], errors: [], notes: '', failure: nil)
      Outcome.new(status:, substitutions:, errors:, notes:, failure:, debug:)
    end

    def debug
      Debug.new(model: LiteLlm::Client.model, endpoint: "#{LiteLlm::Client.url}/v1/chat/completions",
                system_prompt: @system, transcript: @transcript)
    end

    def audit = LiteLlm::Client::AuditContext.new(user: @user, source: 'placeholder_suggester')
  end
end
