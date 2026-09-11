# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

require_relative '../../test_helper'

class Redmine::ApiTest::AuthenticationTest < Redmine::ApiTest::Base
  def teardown
    User.current = nil
  end

  def generate_personal_access_token(user=nil)
    PersonalAccessToken.create!(
      :user => user || User.generate!,
      :name => 'API test',
      :expires_at => 30.days.from_now
    )
  end

  def test_api_should_deny_without_credentials
    get '/users/current.xml'
    assert_response :unauthorized
    assert response.headers.has_key?('WWW-Authenticate')
  end

  def test_api_should_accept_http_basic_auth_using_username_and_password
    user = User.generate! do |user|
      user.password = 'my_password'
    end
    get '/users/current.xml', :headers => credentials(user.login, 'my_password')
    assert_response :ok
  end

  def test_api_should_deny_http_basic_auth_using_username_and_wrong_password
    user = User.generate! do |user|
      user.password = 'my_password'
    end
    get '/users/current.xml', :headers => credentials(user.login, 'wrong_password')
    assert_response :unauthorized
  end

  def test_api_should_deny_http_basic_auth_if_twofa_is_active
    user = User.generate! do |user|
      user.password = 'my_password'
      user.update(twofa_scheme: 'totp')
    end
    get '/users/current.xml', :headers => credentials(user.login, 'my_password')
    assert_response :unauthorized
  end

  def test_api_should_accept_http_basic_auth_using_api_key
    user = User.generate!
    token = Token.create!(:user => user, :action => 'api')
    get '/users/current.xml', :headers => credentials(token.value, 'X')
    assert_response :ok
  end

  def test_api_should_deny_http_basic_auth_using_wrong_api_key
    user = User.generate!
    token = Token.create!(:user => user, :action => 'feeds') # not the API key
    get '/users/current.xml', :headers => credentials(token.value, 'X')
    assert_response :unauthorized
  end

  def test_api_should_accept_auth_using_api_key_as_parameter
    user = User.generate!
    token = Token.create!(:user => user, :action => 'api')
    get "/users/current.xml?key=#{token.value}"
    assert_response :ok
  end

  def test_api_should_deny_auth_using_wrong_api_key_as_parameter
    user = User.generate!
    token = Token.create!(:user => user, :action => 'feeds') # not the API key
    get "/users/current.xml?key=#{token.value}"
    assert_response :unauthorized
  end

  def test_api_should_accept_auth_using_api_key_as_request_header
    user = User.generate!
    token = Token.create!(:user => user, :action => 'api')
    get "/users/current.xml", :headers => {'X-Redmine-API-Key' => token.value.to_s}
    assert_response :ok
  end

  def test_api_should_deny_auth_using_wrong_api_key_as_request_header
    user = User.generate!
    token = Token.create!(:user => user, :action => 'feeds') # not the API key
    get "/users/current.xml", :headers => {'X-Redmine-API-Key' => token.value.to_s}
    assert_response :unauthorized
  end

  def test_api_should_accept_auth_using_personal_access_token_as_request_header
    token = generate_personal_access_token
    get '/users/current.xml', :headers => {'X-Redmine-API-Key' => token.plain_value}
    assert_response :ok
  end

  def test_api_should_accept_auth_using_personal_access_token_as_parameter
    token = generate_personal_access_token
    get "/users/current.xml?key=#{token.plain_value}"
    assert_response :ok
  end

  def test_api_should_accept_http_basic_auth_using_personal_access_token
    token = generate_personal_access_token
    get '/users/current.xml', :headers => credentials(token.plain_value, 'X')
    assert_response :ok
  end

  def test_api_should_deny_auth_using_expired_personal_access_token
    token = generate_personal_access_token
    token.update_column(:expires_at, 1.minute.ago)
    get '/users/current.xml', :headers => {'X-Redmine-API-Key' => token.plain_value}
    assert_response :unauthorized
  end

  def test_api_should_deny_auth_using_revoked_personal_access_token
    token = generate_personal_access_token
    token.revoke!
    get '/users/current.xml', :headers => {'X-Redmine-API-Key' => token.plain_value}
    assert_response :unauthorized
  end

  # Redmine's `key` credential is accepted on any action that declares
  # accept_api_auth, whatever the requested format — find_current_user gates the
  # branch on accept_api_auth?, not on api_request?. A personal access token
  # therefore behaves on an HTML request exactly as the API key already does.
  # What it must NOT do, and this is the property worth pinning, is open a
  # session: the credential authenticates one request and leaves no cookie.
  def test_revoking_one_personal_access_token_should_leave_the_others_working
    user = User.generate!
    revoked = generate_personal_access_token(user)
    kept = generate_personal_access_token(user)

    revoked.revoke!

    get '/users/current.xml', :headers => {'X-Redmine-API-Key' => revoked.plain_value}
    assert_response :unauthorized

    get '/users/current.xml', :headers => {'X-Redmine-API-Key' => kept.plain_value}
    assert_response :ok
  end

  def test_personal_access_token_should_authenticate_like_an_api_key_without_opening_a_session
    with_settings :login_required => '1' do
      token = generate_personal_access_token
      api_key = Token.create!(:user => User.generate!, :action => 'api')

      get "/issues?key=#{api_key.value}"
      api_key_status = response.status

      get "/issues?key=#{token.plain_value}"
      assert_equal api_key_status, response.status
      assert_nil session[:user_id]
    end
  end

  def test_api_should_deny_auth_using_invalid_personal_access_token
    generate_personal_access_token
    ['rmpat_invalid', PersonalAccessToken.generate_value].each do |value|
      get '/users/current.xml', :headers => {'X-Redmine-API-Key' => value}
      assert_response :unauthorized
    end
  end

  def test_api_should_deny_auth_using_personal_access_token_of_a_locked_user
    token = generate_personal_access_token(User.find(5))
    assert User.find(5).locked?
    get '/users/current.xml', :headers => {'X-Redmine-API-Key' => token.plain_value}
    assert_response :unauthorized
  end

  def test_api_key_should_still_be_accepted_for_a_user_owning_personal_access_tokens
    user = User.generate!
    token = generate_personal_access_token(user)

    get '/users/current.xml', :headers => {'X-Redmine-API-Key' => user.api_key}
    assert_response :ok

    get '/users/current.xml', :headers => {'X-Redmine-API-Key' => token.plain_value}
    assert_response :ok
  end

  def test_api_should_record_the_usage_of_the_personal_access_token
    token = generate_personal_access_token
    assert_nil token.last_used_at

    get '/users/current.xml', :headers => {'X-Redmine-API-Key' => token.plain_value}
    assert_response :ok
    assert_not_nil token.reload.last_used_at
  end

  def test_api_should_trigger_basic_http_auth_with_basic_authorization_header
    ApplicationController.any_instance.expects(:authenticate_with_http_basic).once
    get '/users/current.xml', :headers => credentials('jsmith')
    assert_response :unauthorized
  end

  def test_api_should_not_trigger_basic_http_auth_with_non_basic_authorization_header
    ApplicationController.any_instance.expects(:authenticate_with_http_basic).never
    get '/users/current.xml', :headers => {'HTTP_AUTHORIZATION' => 'Digest foo bar'}
    assert_response :unauthorized
  end

  def test_invalid_utf8_credentials_should_not_trigger_an_error
    invalid_utf8 = "\x82"
    assert !invalid_utf8.valid_encoding?
    assert_nothing_raised do
      get '/users/current.xml', :headers => credentials(invalid_utf8, "foo")
    end
  end

  def test_api_request_should_not_use_user_session
    log_user('jsmith', 'jsmith')

    get '/users/current'
    assert_response :success

    get '/users/current.json'
    assert_response :unauthorized
  end

  # TODO: check why this test does not use the API endpoint
  def test_api_should_accept_switch_user_header_for_admin_user
    user = User.find(1)
    su = User.find(4)

    get '/users/current', :headers => {'X-Redmine-API-Key' => user.api_key, 'X-Redmine-Switch-User' => su.login}
    assert_response :success
    assert_select 'h2', :text => "#{su.initials} #{su.name}"
  end

  # TODO: check why this test does not use the API endpoint
  def test_api_should_respond_with_412_when_trying_to_switch_to_a_invalid_user
    get '/users/current', :headers => {'X-Redmine-API-Key' => User.find(1).api_key, 'X-Redmine-Switch-User' => 'foobar'}
    assert_response :precondition_failed
  end

  # TODO: check why this test does not use the API endpoint
  def test_api_should_respond_with_412_when_trying_to_switch_to_a_locked_user
    user = User.find(5)
    assert user.locked?

    get '/users/current', :headers => {'X-Redmine-API-Key' => User.find(1).api_key, 'X-Redmine-Switch-User' => user.login}
    assert_response :precondition_failed
  end

  # TODO: check why this test does not use the API endpoint
  def test_api_should_not_accept_switch_user_header_for_non_admin_user
    user = User.find(2)
    su = User.find(4)

    get '/users/current', :headers => {'X-Redmine-API-Key' => user.api_key, 'X-Redmine-Switch-User' => su.login}
    assert_response :success
    assert_select 'h2', :text => "#{user.initials} #{user.name}"
  end

  def test_successful_personal_access_token_auth_should_record_an_audit_event
    token = generate_personal_access_token
    assert_difference 'ApiAuthEvent.count', 1 do
      get '/users/current.xml', :headers => {'X-Redmine-API-Key' => token.plain_value}
      assert_response :ok
    end
    event = ApiAuthEvent.last
    assert_equal 'personal_access_token', event.credential_kind
    assert_equal token.user_id, event.user_id
    assert_equal token.id, event.personal_access_token_id
    assert_equal 'GET', event.http_method
    assert_equal '/users/current.xml', event.path
    assert event.remote_ip.present?
  end

  def test_successful_api_key_auth_should_record_an_audit_event
    user = User.generate!
    token = Token.create!(:user => user, :action => 'api')
    assert_difference 'ApiAuthEvent.count', 1 do
      get "/users/current.xml?key=#{token.value}"
      assert_response :ok
    end
    event = ApiAuthEvent.last
    assert_equal 'api_key', event.credential_kind
    assert_equal user.id, event.user_id
    assert_nil event.personal_access_token_id
    # the path is stored without the query string, so the key stays out of the trail
    assert_equal '/users/current.xml', event.path
  end

  def test_successful_http_basic_auth_using_personal_access_token_should_record_an_audit_event
    token = generate_personal_access_token
    assert_difference 'ApiAuthEvent.count', 1 do
      get '/users/current.xml', :headers => credentials(token.plain_value, 'X')
      assert_response :ok
    end
    assert_equal 'personal_access_token', ApiAuthEvent.last.credential_kind
  end

  def test_failed_api_credential_should_record_a_failed_audit_event
    assert_difference 'ApiAuthEvent.count', 1 do
      get '/users/current.xml', :headers => {'X-Redmine-API-Key' => 'invalid-key'}
      assert_response :unauthorized
    end
    event = ApiAuthEvent.last
    assert_equal 'failed', event.credential_kind
    assert_nil event.user_id
    assert_nil event.personal_access_token_id
  end

  def test_failed_auth_using_an_expired_personal_access_token_should_record_the_tried_token
    token = generate_personal_access_token
    token.update_column(:expires_at, 1.minute.ago)
    assert_difference 'ApiAuthEvent.count', 1 do
      get '/users/current.xml', :headers => {'X-Redmine-API-Key' => token.plain_value}
      assert_response :unauthorized
    end
    event = ApiAuthEvent.last
    assert_equal 'failed', event.credential_kind
    assert_nil event.user_id
    assert_equal token.id, event.personal_access_token_id
  end

  def test_http_basic_auth_using_username_and_password_should_not_record_an_audit_event
    user = User.generate! do |u|
      u.password = 'my_password'
    end
    assert_no_difference 'ApiAuthEvent.count' do
      get '/users/current.xml', :headers => credentials(user.login, 'my_password')
      assert_response :ok
    end
  end

  def test_audit_write_failure_should_not_break_authentication
    token = generate_personal_access_token
    ApiAuthEvent.stubs(:create!).raises(ActiveRecord::StatementInvalid.new('audit table gone'))
    get '/users/current.xml', :headers => {'X-Redmine-API-Key' => token.plain_value}
    assert_response :ok
  end
end
