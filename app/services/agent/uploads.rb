# frozen_string_literal: true

module Agent
  # The user's uploaded inputs, for users who chose "Don't keep my uploads".
  module Uploads
    module_function

    def cleanup_after_run(generation)
      generation.generation_inputs.delete_all
      generation.input_image.purge_later if generation.input_image.attached?
    end
  end
end
