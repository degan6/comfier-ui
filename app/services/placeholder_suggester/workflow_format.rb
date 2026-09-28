class PlaceholderSuggester
  # Turns uploaded JSON (or an already-parsed graph) into a private copy of an API-format workflow.
  module WorkflowFormat
    UI_FORMAT_MESSAGE = 'This is a UI-format workflow. In ComfyUI, use Export (API) and upload that file.'.freeze
    BLANK_MESSAGE = 'Paste or upload an API-format workflow JSON first.'.freeze
    NOT_API_MESSAGE = 'This isn\'t an API-format workflow: every node needs a class_type and inputs.'.freeze

    module_function

    def parse(workflow)
      graph = workflow.is_a?(String) ? parse_json(workflow) : workflow
      raise Error, BLANK_MESSAGE if graph.blank?
      raise Error, NOT_API_MESSAGE unless graph.is_a?(Hash)

      graph = graph.deep_stringify_keys.deep_dup
      raise Error, UI_FORMAT_MESSAGE if graph['nodes'].is_a?(Array) && graph['links'].is_a?(Array)
      raise Error, NOT_API_MESSAGE unless WorkflowModels.api_format?(graph)

      graph
    end

    def parse_json(text)
      raise Error, BLANK_MESSAGE if text.strip.empty?

      JSON.parse(WorkflowGraphJson.normalize(text))
    rescue JSON::ParserError => e
      raise Error, "The workflow isn't valid JSON: #{e.message.truncate(200)}"
    end
  end
end
