require 'test_helper'

class PlaceholderSuggester
  class WorkflowFormatTest < ActiveSupport::TestCase
    test 'parses API-format JSON into a private copy' do
      graph = { '1' => { 'class_type' => 'SaveImage', 'inputs' => { 'filename_prefix' => 'x' } } }

      parsed = WorkflowFormat.parse(graph)
      parsed['1']['inputs']['filename_prefix'] << 'y'

      assert_equal 'x', graph.dig('1', 'inputs', 'filename_prefix')
      assert_equal parsed, WorkflowFormat.parse(parsed.to_json)
    end

    test 'reports JSON syntax errors' do
      error = assert_raises(Error) { WorkflowFormat.parse('{ oops') }

      assert_match(/isn't valid JSON/, error.message)
    end

    test 'asks for a workflow when there is nothing to read' do
      assert_equal WorkflowFormat::BLANK_MESSAGE, assert_raises(Error) { WorkflowFormat.parse('  ') }.message
      assert_equal WorkflowFormat::BLANK_MESSAGE, assert_raises(Error) { WorkflowFormat.parse({}) }.message
    end

    test 'rejects UI-format exports with the export hint' do
      error = assert_raises(Error) { WorkflowFormat.parse({ nodes: [{ id: 1 }], links: [] }) }

      assert_equal WorkflowFormat::UI_FORMAT_MESSAGE, error.message
    end

    test 'rejects nodes without class_type and inputs' do
      error = assert_raises(Error) { WorkflowFormat.parse({ '1' => { 'inputs' => {} } }) }

      assert_equal WorkflowFormat::NOT_API_MESSAGE, error.message
    end
  end
end
