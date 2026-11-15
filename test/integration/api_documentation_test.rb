require 'test_helper'

class ApiDocumentationTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:alice) }

  test 'documentation is discoverable from settings and token management' do
    get settings_path

    assert_select 'a[href=?]', api_documentation_path, text: /API documentation/

    get personal_api_tokens_path

    assert_select 'a[href=?]', api_documentation_path, text: 'API documentation and examples'
  end

  test 'renders the API specification with formatted tables and code examples' do
    get api_documentation_path

    assert_response :success
    assert_select 'h1', text: 'API documentation'
    assert_select 'article h2', text: 'Authentication'
    assert_select 'article table td code', text: '/api/v1/workflows'
    assert_select 'article pre code', text: %r{export COMFIER_URL='http://www.example.com'}
    assert_select '.settings-nav-item.active', text: /API documentation/
  end

  test 'LLM copy and plain text contain the complete spec with this installations URL and no token secrets' do
    _, secret = PersonalApiToken.issue!(user: users(:alice), name: 'Private token')
    expected = Rails.root.join('docs/USER_API.md').read.gsub('https://comfier.example.com', 'http://www.example.com')
    get api_documentation_path

    assert_select 'button[data-action="clipboard#copy"]', text: /Copy for LLM/
    assert_select 'textarea[data-clipboard-target="source"]', text: expected
    assert_select 'a[href=?]', api_documentation_path(format: :text)

    get api_documentation_path(format: :text)

    assert_response :success
    assert_equal 'text/plain', response.media_type
    assert_equal expected, response.body
    assert_not_includes response.body, secret
  end

  test 'requires login for both HTML and plain text' do
    delete logout_path

    get api_documentation_path

    assert_redirected_to login_path

    get api_documentation_path(format: :text)

    assert_redirected_to login_path
  end
end
