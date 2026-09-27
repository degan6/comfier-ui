require 'test_helper'

class AgentApiTest < ActionDispatch::IntegrationTest
  setup do
    @alice = users(:alice)
    @backend = create_agent_backend!(owner: @alice)
    @token = create_agent_key!(@backend)
    @generation = Generation.create!(user: @alice, workflow: workflows(:sd_image), prompt: 'x', kind: :image,
                                     status: :running, backend: @backend, agent_state: 'running', agent_attempt: 1,
                                     filled_workflow_json: {})
  end

  def auth(token = @token) = { 'Authorization' => "Bearer #{token}" }

  def upload(io, filename, content_type: 'application/octet-stream', job: @generation, token: @token)
    file = Rack::Test::UploadedFile.new(io, content_type, original_filename: filename)
    post api_agent_job_outputs_path("j_#{job.id}"), params: { file:, node: '9', filename: }, headers: auth(token)
  end

  def tempfile(bytes, name = 'upload')
    file = Tempfile.new(name)
    file.binmode
    file.write(bytes)
    file.rewind
    file
  end

  test 'a real PNG is accepted' do
    upload(file_fixture('pixel.png').open, 'ComfyUI_00001_.png')

    assert_response :success
    upload_id = response.parsed_body['upload_id']
    output = GenerationOutput.find_by!(upload_id:)

    assert_equal 'image/png', output.mime
    assert_equal @backend, output.backend
  end

  test 'the same upload twice returns the same id' do
    upload(file_fixture('pixel.png').open, 'a.png')
    first = response.parsed_body['upload_id']
    upload(file_fixture('pixel.png').open, 'a.png')

    assert_equal first, response.parsed_body['upload_id']
    assert_equal 1, GenerationOutput.where(upload_id: first).count
  end

  test 'HTML renamed to .png is refused' do
    upload(tempfile('<html><script>alert(1)</script></html>'), 'evil.png')

    assert_response :unsupported_media_type
  end

  test 'SVG and HTML are never accepted' do
    upload(tempfile('<svg xmlns="http://www.w3.org/2000/svg"></svg>'), 'image.svg')

    assert_response :unsupported_media_type
    upload(tempfile('<html></html>'), 'page.html')

    assert_response :unsupported_media_type
  end

  test 'a text 3D file with markup is refused, a real one accepted' do
    upload(tempfile('<script>x</script>'), 'mesh.obj')

    assert_response :unsupported_media_type
    upload(tempfile("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"), 'mesh.obj')

    assert_response :success
    upload(tempfile("glTF\x02\x00\x00\x00".b), 'mesh.glb')

    assert_response :success
  end

  test 'filenames are sanitized' do
    assert_equal 'evil.png', Agent::Outputs.sanitize_filename("../../etc/\u202Eevil.png")
    assert_equal 'hidden.png', Agent::Outputs.sanitize_filename('...hidden.png')
    assert_equal Agent::Outputs::MAX_FILENAME, Agent::Outputs.sanitize_filename("#{'a' * 300}.png").length
  end

  test 'files over the size limit are refused' do
    with_env('AGENT_MAX_OUTPUT_FILE_GB' => '0.00000001') do
      upload(file_fixture('pixel.png').open, 'big.png')
    end

    assert_response :content_too_large
  end

  test 'another server cannot upload to this job' do
    other = create_agent_backend!(owner: @alice, name: 'Other')
    upload(file_fixture('pixel.png').open, 'a.png', token: create_agent_key!(other))

    assert_response :not_found
  end

  test 'no key, no access' do
    post api_agent_job_outputs_path("j_#{@generation.id}")

    assert_response :unauthorized
  end

  test 'inputs stream with a length and only while the job is on the server' do
    blob = ActiveStorage::Blob.create_and_upload!(io: file_fixture('pixel.png').open, filename: 'in.png',
                                                  content_type: 'image/png')
    GenerationInput.create!(generation: @generation, input_id: 'in_0', storage_key: blob.key, filename: 'in.png',
                            mime: 'image/png', bytes: blob.byte_size)

    get api_agent_job_input_path("j_#{@generation.id}", 'in_0'), headers: auth

    assert_response :success
    assert_equal blob.byte_size.to_s, response.headers['Content-Length']
    assert_equal file_fixture('pixel.png').binread, response.body.b

    @generation.update!(agent_state: 'completed')
    get api_agent_job_input_path("j_#{@generation.id}", 'in_0'), headers: auth

    assert_response :not_found
  end

  test 'shared outputs are served with nosniff and a sandbox' do
    generation = generations(:alice_done)
    generation.update!(status: :succeeded)
    generation.outputs.attach(io: file_fixture('pixel.png').open, filename: 'out.png', content_type: 'image/png')
    generation.create_public_link!

    get public_share_output_path(generation.public_token, 0)

    assert_response :success
    assert_equal 'nosniff', response.headers['X-Content-Type-Options']
    assert_match 'sandbox', response.headers['Content-Security-Policy']
  end
end
