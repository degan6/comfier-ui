namespace :agent do
  desc 'Extract agent-server requirements for every workflow and list those that need admin review'
  task extract_requirements: :environment do
    review = []
    Workflow.find_each do |workflow|
      Agent::Requirements.extract!(workflow)
      workflow.reload
      puts "#{workflow.name}: #{workflow.workflow_models.size} models, " \
           "#{Array(workflow.requirements_json&.dig('node_types')).size} node types"
      review << workflow if workflow.requirements_need_review?
    end
    Backend.agent.kept.find_each { Agent::Availability.recompute_for_backend!(it) }
    next puts('Every workflow has folders and download links.') if review.empty?

    puts "\nNeed review (unknown folder or no download link):"
    review.each do |workflow|
      problems = workflow.workflow_models.select { it.unknown_folder? || it.url.blank? }
      puts "  #{workflow.name}: #{problems.map { "#{it.folder}/#{it.filename}" }.join(', ')}"
    end
  end
end
