require 'test_helper'

class ApiDocumentationHelperTest < ActionView::TestCase
  test 'does not render raw HTML or unsafe links from Markdown' do
    html = api_documentation_html("<script>alert('x')</script>\n\n[Unsafe](javascript:alert)\n\n**Safe**")

    assert_no_match(/<script|href="javascript:/, html)
    assert_includes html, '<strong>Safe</strong>'
  end
end
