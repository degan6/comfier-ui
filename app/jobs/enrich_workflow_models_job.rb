# frozen_string_literal: true

# Fills in file sizes and sha256 hashes for a workflow's models with a HEAD request to each link.
# Hugging Face `resolve` links report the LFS hash and size in X-Linked-Etag / X-Linked-Size.
class EnrichWorkflowModelsJob < ApplicationJob
  queue_as :default

  def perform(workflow)
    workflow.workflow_models.where.not(url: [nil, '']).where(bytes: nil).find_each { enrich(it) }
  end

  private

  def enrich(model)
    response = head(model.url)
    return unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)

    attrs = attributes_from(response, model)
    model.update!(attrs.merge(source: model.source == 'admin' ? 'admin' : 'enriched')) if attrs.any?
  rescue StandardError => e
    Rails.logger.info("[Agent] couldn't enrich #{model.url}: #{e.class}: #{e.message}")
  end

  # A redirect's own Content-Length is the redirect body, not the file.
  def attributes_from(response, model)
    size = response['x-linked-size'] || (response['content-length'] unless response.is_a?(Net::HTTPRedirection))
    etag = response['x-linked-etag'].to_s.delete('"')
    attrs = { bytes: size&.to_i }.compact
    attrs[:sha256] = etag if etag.match?(/\A\h{64}\z/) && model.sha256.blank?
    attrs
  end

  def head(url)
    uri = URI.parse(url)
    return unless uri.is_a?(URI::HTTPS)

    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) do |http|
      http.head(uri.request_uri, 'User-Agent' => 'Comfier')
    end
  end
end
