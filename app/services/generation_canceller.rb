# Cancels a generation on whichever kind of server it's on.
class GenerationCanceller
  Outcome = Data.define(:cancelled)

  def self.call(generation) = new(generation).call

  def initialize(generation)
    @generation = generation
  end

  def call
    return Outcome.new(cancelled: false) unless @generation.in_progress?

    runner = @generation.agent_job? ? Backends::AgentRunner.new : Backends::LegacyRunner.new
    Outcome.new(cancelled: runner.cancel(@generation) != false)
  end
end
