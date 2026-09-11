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

require_relative '../test_helper'

class ApiAuthEventTest < ActiveSupport::TestCase
  def setup
    User.current = nil
    @user = User.find(2)
  end

  def generate_token
    PersonalAccessToken.create!(
      :user => @user, :name => 'Audit test', :expires_on => 30.days.from_now
    )
  end

  def request_stub(env={})
    ActionDispatch::TestRequest.create(
      {
        'REQUEST_METHOD' => 'GET',
        'PATH_INFO' => '/issues.json',
        'REMOTE_ADDR' => '10.0.0.3'
      }.merge(env)
    )
  end

  def test_record_with_a_personal_access_token_should_store_kind_owner_and_request_context
    token = generate_token
    event = ApiAuthEvent.record(request_stub, :user => @user, :personal_access_token => token)
    assert event.persisted?
    assert_equal 'personal_access_token', event.credential_kind
    assert_equal @user.id, event.user_id
    assert_equal token.id, event.personal_access_token_id
    assert_equal 'GET', event.http_method
    assert_equal '/issues.json', event.path
    assert_equal '10.0.0.3', event.remote_ip
    assert_not_nil event.created_at
  end

  def test_record_with_a_user_only_should_store_an_api_key_event
    event = ApiAuthEvent.record(request_stub, :user => @user)
    assert event.persisted?
    assert_equal 'api_key', event.credential_kind
    assert_equal @user.id, event.user_id
    assert_nil event.personal_access_token_id
  end

  def test_record_without_a_user_should_store_a_failed_attempt
    event = ApiAuthEvent.record(request_stub)
    assert event.persisted?
    assert_equal 'failed', event.credential_kind
    assert_nil event.user_id
    assert_nil event.personal_access_token_id
  end

  def test_record_of_a_failed_attempt_should_keep_the_tried_token_when_known
    token = generate_token
    token.revoke!
    event = ApiAuthEvent.record(request_stub, :personal_access_token => token)
    assert_equal 'failed', event.credential_kind
    assert_nil event.user_id
    assert_equal token.id, event.personal_access_token_id
  end

  def test_record_should_not_store_the_query_string
    token = generate_token
    request = request_stub('QUERY_STRING' => "key=#{token.plain_value}")
    event = ApiAuthEvent.record(request, :user => @user, :personal_access_token => token)
    assert_equal '/issues.json', event.path
    assert_not_includes event.attributes.values.map(&:to_s).join(' '), token.plain_value
  end

  def test_record_should_truncate_an_overlong_path
    event = ApiAuthEvent.record(request_stub('PATH_INFO' => "/#{'a' * 300}"))
    assert_equal 255, event.path.length
  end

  def test_record_should_never_raise_when_the_insert_fails
    ApiAuthEvent.stubs(:create!).raises(ActiveRecord::StatementInvalid.new('audit table gone'))
    event = nil
    assert_nothing_raised do
      event = ApiAuthEvent.record(request_stub, :user => @user)
    end
    assert_nil event
  end

  def test_should_reject_an_unknown_credential_kind
    event = ApiAuthEvent.new(
      :credential_kind => 'password', :http_method => 'GET', :path => '/issues.json'
    )
    assert !event.save
    assert_includes event.errors.attribute_names, :credential_kind
  end
end
