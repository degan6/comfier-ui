# Model-specific constraints for native music recipes. The agent validates again after placeholders are filled.
module MusicRecipe
  OPTIONS = %w[command model prompt lyrics duration steps seed planning min_memory_gb].freeze
  PLACEHOLDER = /\A\{\{\s*\w+\s*\}\}\z/

  module_function

  def problems(recipe)
    found = []
    found << '"model" must be yue2 or minimax-music3' unless %w[yue2 minimax-music3].include?(recipe['model'])
    unknown = recipe.keys - OPTIONS
    found << "unknown music options: #{unknown.join(', ')}" if unknown.any?
    found << 'needs "prompt"' unless recipe['prompt'].is_a?(String) && recipe['prompt'].strip.size >= 3
    found + numeric_problems(recipe) + planning_problems(recipe)
  end

  def numeric_problems(recipe)
    minimax = recipe['model'] == 'minimax-music3'
    ranges = { 'duration' => 1..(minimax ? 300 : 360), 'steps' => 1..(minimax ? 30 : 256),
               'seed' => 0..4_294_967_295 }
    ranges.filter_map do |key, range|
      value = recipe[key]
      next if unspecified_number?(value)
      next if music_number?(key, value) && range.cover?(value)

      "\"#{key}\" must be a valid number in #{range}"
    end
  end

  def unspecified_number?(value)
    value.nil? || (value.is_a?(String) && value.match?(PLACEHOLDER))
  end

  def music_number?(key, value)
    value.is_a?(Integer) || (key == 'duration' && value.is_a?(Float))
  end

  def planning_problems(recipe)
    planning = recipe.fetch('planning', 'off')
    return [] if %w[off melody full].include?(planning) && (recipe['model'] != 'minimax-music3' || planning == 'off')

    ['score planning is off, melody or full, and is YuE2-only']
  end
end
