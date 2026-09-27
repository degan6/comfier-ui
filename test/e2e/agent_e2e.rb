# frozen_string_literal: true

# The Rails half of script/agent_e2e, run with `bin/rails runner test/e2e/agent_e2e.rb <command> ...`.
#   seed                     user, agent server, key, and a one-image workflow; prints the key
#   submit                   a generation with an input image, through SubmitGenerationJob; prints its id
#   wait ID STATE [SECONDS]  until the generation's agent_state is STATE (fails on another terminal state)
#   check ID [--recovered]   the generation succeeded exactly once, with an output, attempts and predictions
require 'json'

module AgentE2e
  STATE = Rails.root.join('tmp/e2e/state.json')
  TERMINAL = %w[completed failed cancelled].freeze

  module_function

  def seed
    user = User.create!(provider: 'e2e', uid: 'e2e-user', email: 'e2e@example.com', name: 'E2E', username: 'e2e',
                        default_aspect_ratio: '1:1', privacy_accepted_version: 1, privacy_accepted_at: Time.current)
    backend = Backend.create!(name: 'E2E box', connection_kind: 'agent', owner_user: user, visibility: 'private',
                              enabled: true)
    workflow = Workflow.create!(name: 'E2E style', kind: 'image', enabled: true, graph: {
                                  '1' => { 'class_type' => 'LoadImage', 'inputs' => { 'image' => '{{image}}' } },
                                  '2' => { 'class_type' => 'SaveImage', 'inputs' => { 'images' => ['1', 0] } }
                                })
    key = backend.issue_agent_key!
    FileUtils.mkdir_p(STATE.dirname)
    File.write(STATE, JSON.generate(user_id: user.id, backend_id: backend.id, workflow_id: workflow.id))
    puts key
  end

  def submit
    state = JSON.parse(File.read(STATE))
    generation = Generation.new(user_id: state['user_id'], workflow_id: state['workflow_id'], kind: 'image',
                                prompt: 'e2e')
    generation.input_image.attach(io: StringIO.new(png), filename: 'input.png', content_type: 'image/png')
    generation.save!
    SubmitGenerationJob.perform_later(generation)
    puts generation.id
  end

  def wait(id, state, seconds = 60)
    deadline = seconds.to_f.seconds.from_now
    loop do
      # runner scripts run inside the executor, whose query cache would hide other processes' writes
      generation = ActiveRecord::Base.uncached { Generation.find(id) }
      return puts("generation #{id} is #{state}") if generation.agent_state == state

      if TERMINAL.include?(generation.agent_state)
        abort("generation #{id} ended #{generation.agent_state}: #{generation.error_message}")
      end
      abort("generation #{id} still #{generation.agent_state.inspect} after #{seconds}s") if Time.current > deadline

      sleep 0.25
    end
  end

  def check(id, recovered: false)
    generation = Generation.find(id)
    attempts = generation.job_attempts.order(:id).pluck(:outcome)
    outputs = generation.generation_outputs.to_a
    problems = {
      "status is #{generation.status}" => !generation.succeeded?,
      "#{outputs.size} outputs, expected 1" => !outputs.one?,
      'no output file attached' => outputs.first&.storage_key.blank?,
      "attempts #{attempts}, expected one completed" => attempts.count('completed') != 1,
      'no prediction log' => !PredictionLog.exists?(generation_id: id),
      'no perf sample' => !PerfSample.joins(:job_attempt).exists?(job_attempts: { generation_id: id }),
      "attempts #{attempts}, expected a lost attempt first" => recovered && attempts.first != 'lost'
    }.select { |_, failed| failed }.keys
    abort("generation #{id}: #{problems.join('; ')}") if problems.any?

    puts "generation #{id} succeeded once (attempts: #{attempts.join(', ')})"
  end

  def png
    rows = ([0] + ([208, 96, 48] * 8)).pack('C*') * 8
    chunk = ->(kind, data) { [data.bytesize].pack('N') + kind + data + [Zlib.crc32(kind + data)].pack('N') }
    "\x89PNG\r\n\x1a\n".b + chunk.call('IHDR', [8, 8, 8, 2, 0, 0, 0].pack('NNCCCCC')) +
      chunk.call('IDAT', Zlib::Deflate.deflate(rows)) + chunk.call('IEND', '')
  end
end

command, *args = ARGV
case command
when 'seed' then AgentE2e.seed
when 'submit' then AgentE2e.submit
when 'wait' then AgentE2e.wait(*args)
when 'check' then AgentE2e.check(args[0], recovered: args.include?('--recovered'))
else abort("unknown command #{command.inspect}")
end
