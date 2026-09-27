# A server's cached /object_info, gzipped, keyed by the hash the agent reports.
class BackendObjectInfo < ApplicationRecord
  belongs_to :backend

  def data
    @data ||= JSON.parse(ActiveSupport::Gzip.decompress(blob_gz))
  rescue Zlib::Error, JSON::ParserError
    {}
  end
end
