module ApiDocumentationHelper
  def api_documentation_html(markdown)
    renderer = Redcarpet::Render::HTML.new(filter_html: true, safe_links_only: true, with_toc_data: true)
    html = Redcarpet::Markdown.new(renderer, tables: true, fenced_code_blocks: true).render(markdown)
    sanitize(html, tags: %w[h1 h2 h3 h4 p a ul ol li pre code blockquote table thead tbody tr th td strong em hr br],
                   attributes: %w[href id title class])
  end
end
