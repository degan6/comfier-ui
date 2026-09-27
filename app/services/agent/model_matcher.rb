# frozen_string_literal: true

module Agent
  # Answers "does this server have this model file?" against its reported inventory, allowing for
  # the folders ComfyUI treats as the same (unet/diffusion_models, clip/text_encoders).
  class ModelMatcher
    FOLDER_ALIASES = {
      'unet' => %w[diffusion_models], 'diffusion_models' => %w[unet],
      'clip' => %w[text_encoders], 'text_encoders' => %w[clip]
    }.freeze

    def self.folders_for(folder) = [folder, *FOLDER_ALIASES[folder]]

    # pairs: [[folder, filename], ...]
    def initialize(pairs)
      @by_folder = Hash.new { |h, k| h[k] = Set.new }
      pairs.each { |folder, filename| @by_folder[folder] << filename }
    end

    def present?(folder, filename)
      if folder == 'unknown'
        return @by_folder.values.any? do |names|
          names.include?(filename) || basenames(names).include?(File.basename(filename))
        end
      end

      self.class.folders_for(folder).any? { @by_folder[it].include?(filename) }
    end

    # The path of a file with the same basename in another subdirectory of the same folder, which
    # ComfyUI won't find under the name the workflow uses.
    def elsewhere(folder, filename)
      base = File.basename(filename)
      self.class.folders_for(folder).each do |f|
        found = @by_folder[f].find { File.basename(it) == base && it != filename }
        return "#{f}/#{found}" if found
      end
      nil
    end

    private

    def basenames(set) = set.map { File.basename(it) }
  end
end
