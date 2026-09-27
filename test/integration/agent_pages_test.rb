require 'test_helper'

# Every page that shows agent servers renders with a live server, a queue, a download and a
# failed agent job present.
class AgentPagesTest < ActionDispatch::IntegrationTest
  setup do
    @alice = users(:alice)
    @workflow = workflows(:sd_image)
    @backend = create_agent_backend!(owner: @alice, visibility: 'public')
    @backend.issue_agent_key!
    bring_online_for!(@backend, @workflow)
    Agent::Availability.recompute_for_backend!(@backend)
    @queued = Generation.create!(user: @alice, workflow: @workflow, prompt: 'queued one', kind: :image, status: :queued,
                                 backend: @backend, agent_state: 'queued', filled_workflow_json: {},
                                 predicted_total_ms: 30_000, predicted_start_at: 1.minute.from_now,
                                 predicted_end_at: 2.minutes.from_now, prediction_confidence: 'medium')
    @failed = Generation.create!(user: @alice, workflow: @workflow, prompt: 'failed one', kind: :image, status: :failed,
                                 backend: @backend, agent_state: 'failed', filled_workflow_json: {},
                                 error_message: 'Node 3 (KSampler): bad',
                                 error_json: { 'stage' => 'validate', 'node' => '3' })
    Agent::DownloadPlanner.manual!(@backend, [{ 'folder' => 'vae', 'filename' => 'ae.safetensors',
                                                'url' => 'https://huggingface.co/x/ae', 'bytes' => 300.megabytes }],
                                   user: @alice)
    SourceCredential.create!(host: 'huggingface.co', secret: 'hf_global_9999')
  end

  test 'owner pages' do
    sign_in_as @alice
    [servers_path, new_server_path, server_path(@backend), settings_server_path(@backend), setup_server_path(@backend),
     source_credentials_path, settings_path, generation_path(@queued), generation_path(@failed), queue_path,
     '/image'].each do |path|
      get path

      assert_response :success, path
    end
    get generation_path(@failed)

    assert_match 'Node 3 (KSampler): bad', response.body
  end

  test 'another user sees the public server without owner controls' do
    sign_in_as users(:bob)
    get server_path(@backend)

    assert_response :success
    assert_no_match 'queued one', response.body
    assert_select "form[action='#{pause_server_path(@backend)}']", count: 0
  end

  test 'admin pages' do
    sign_in_as users(:admin)
    [admin_backends_path, edit_admin_backend_path(backends(:gpu)), admin_workflows_path,
     edit_admin_workflow_path(@workflow), requirements_admin_workflow_path(@workflow), admin_server_overview_path,
     admin_server_accuracy_path, admin_source_credentials_path, servers_path, server_path(@backend)].each do |path|
      get path

      assert_response :success, path
    end
    get admin_source_credentials_path

    assert_match '9999', response.body
    assert_no_match 'hf_global_9999', response.body
  end
end
