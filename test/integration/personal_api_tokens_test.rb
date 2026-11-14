require 'test_helper'

class PersonalApiTokensTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:alice) }

  test 'settings links to token management' do
    get settings_path

    assert_select 'a[href=?]', personal_api_tokens_path, text: /API tokens/
  end

  test 'creates a token and shows its secret only on creation' do
    assert_difference('PersonalApiToken.count') do
      post personal_api_tokens_path, params: { personal_api_token: { name: 'Laptop' } }
    end

    assert_response :created
    assert_equal 'no-store', response.headers['Cache-Control']
    secret = css_select('#new-api-token').first.text
    token = PersonalApiToken.authenticate(secret)

    assert_equal users(:alice), token.user
    assert_equal 'Laptop', token.name

    get personal_api_tokens_path

    assert_select '#new-api-token', count: 0
    assert_not_includes response.body, secret
  end

  test 'rejects a blank name without creating a token' do
    assert_no_difference('PersonalApiToken.count') do
      post personal_api_tokens_path, params: { personal_api_token: { name: '' } }
    end

    assert_response :unprocessable_content
    assert_select '.alert-danger', text: /Name can't be blank/
  end

  test 'lists only the current users tokens and rejects deleting another users token' do
    PersonalApiToken.issue!(user: users(:alice), name: 'Own laptop')
    other, = PersonalApiToken.issue!(user: users(:bob), name: 'Other laptop')
    get personal_api_tokens_path

    assert_select 'td', text: 'Own laptop'
    assert_select 'td', text: 'Other laptop', count: 0

    delete personal_api_token_path(other)

    assert_response :not_found
    assert PersonalApiToken.exists?(other.id)
  end

  test 'deletes a token and removes it from the list' do
    own, secret = PersonalApiToken.issue!(user: users(:alice), name: 'Own laptop')

    assert_difference('PersonalApiToken.count', -1) do
      delete personal_api_token_path(own)
    end

    assert_redirected_to personal_api_tokens_path
    assert_not PersonalApiToken.exists?(own.id)
    assert_nil PersonalApiToken.authenticate(secret)

    follow_redirect!

    assert_select 'td', text: 'Own laptop', count: 0
    assert_select 'p', text: 'You have no API tokens.'
  end

  test 'requires login to create a token' do
    delete logout_path
    assert_no_difference('PersonalApiToken.count') do
      post personal_api_tokens_path, params: { personal_api_token: { name: 'Unauthenticated' } }
    end

    assert_redirected_to login_path
  end
end
