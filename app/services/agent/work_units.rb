# frozen_string_literal: true

module Agent
  class WorkUnits
    def self.compute(generation)
      p = generation.parameters
      steps = (p['steps'] || 1).to_f
      width = (p['width'] || 1024).to_f
      height = (p['height'] || 1024).to_f
      frames = (p['frames'] || p['duration'] || 1).to_f
      batch = (p['batch_size'] || 1).to_f
      megapixels = width * height / 1_000_000.0
      steps * megapixels * frames * batch
    end
  end
end
