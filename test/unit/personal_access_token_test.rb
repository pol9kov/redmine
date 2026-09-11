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

class PersonalAccessTokenTest < ActiveSupport::TestCase
  def setup
    User.current = nil
    @user = User.find(2)
  end

  def generate_token(attributes={})
    PersonalAccessToken.create!(
      {:user => @user, :name => 'Test token', :expires_on => 30.days.from_now}.merge(attributes)
    )
  end

  def test_create_should_return_the_value_once_and_store_its_digest_only
    token = generate_token
    assert_match PersonalAccessToken::VALUE_FORMAT, token.plain_value
    assert token.plain_value.start_with?(PersonalAccessToken::PREFIX)
    assert_equal Digest::SHA256.hexdigest(token.plain_value), token.hashed_value
    assert_not_includes token.attributes.values.map(&:to_s), token.plain_value
    assert_nil PersonalAccessToken.find(token.id).plain_value
  end

  def test_create_should_generate_a_different_value_for_each_token
    t1 = generate_token
    t2 = generate_token
    assert_not_equal t1.plain_value, t2.plain_value
    assert_not_equal t1.hashed_value, t2.hashed_value
  end

  def test_user_may_own_several_tokens
    assert_difference 'PersonalAccessToken.count', 2 do
      generate_token(:name => 'CI')
      generate_token(:name => 'Laptop')
    end
    assert_equal 2, @user.personal_access_tokens.count
  end

  def test_should_validate_presence_of_name
    token = PersonalAccessToken.new(:user => @user, :expires_on => 1.day.from_now)
    assert !token.save
    assert_includes token.errors.attribute_names, :name
  end

  def test_should_validate_uniqueness_of_hashed_value
    existing = generate_token
    PersonalAccessToken.stubs(:generate_value).returns(existing.plain_value)
    token = PersonalAccessToken.new(:user => @user, :name => 'Dup', :expires_on => 1.day.from_now)
    assert !token.save
    assert_includes token.errors.attribute_names, :hashed_value
  end

  def test_should_require_an_expiration_date
    token = PersonalAccessToken.new(:user => @user, :name => 'No expiry')
    assert !token.save
    assert_includes token.errors.attribute_names, :expires_on
  end

  def test_should_not_accept_an_expiration_date_in_the_past
    token = PersonalAccessToken.new(:user => @user, :name => 'Stale', :expires_on => 1.minute.ago)
    assert !token.save
    assert_includes token.errors.attribute_names, :expires_on
  end

  def test_expired_should_return_true_after_the_expiration_date
    token = generate_token(:expires_on => 1.hour.from_now)
    assert !token.expired?
    assert token.active?

    travel_to(2.hours.from_now) do
      assert token.expired?
      assert !token.active?
    end
  end

  def test_revoke_should_deactivate_the_token
    token = generate_token
    assert !token.revoked?

    token.revoke!
    assert token.revoked?
    assert !token.active?
    assert token.reload.revoked?
  end

  def test_active_scope_should_exclude_expired_and_revoked_tokens
    active = generate_token
    revoked = generate_token.revoke!
    expired = generate_token
    expired.update_column(:expires_on, 1.hour.ago)

    assert_equal [active.id], PersonalAccessToken.active.ids & [active.id, revoked.id, expired.id]
  end

  def test_find_by_value_should_return_the_token
    token = generate_token
    assert_equal token, PersonalAccessToken.find_by_value(token.plain_value)
  end

  def test_find_by_value_should_return_nil_for_an_unknown_or_malformed_value
    generate_token
    assert_nil PersonalAccessToken.find_by_value(PersonalAccessToken.generate_value)
    assert_nil PersonalAccessToken.find_by_value('foo')
    assert_nil PersonalAccessToken.find_by_value('')
    assert_nil PersonalAccessToken.find_by_value(nil)
  end

  def test_find_active_user_should_return_the_owner
    token = generate_token
    assert_equal @user, PersonalAccessToken.find_active_user(token.plain_value)
  end

  def test_find_active_user_should_return_nil_for_an_expired_token
    token = generate_token
    token.update_column(:expires_on, 1.minute.ago)
    assert_nil PersonalAccessToken.find_active_user(token.plain_value)
  end

  def test_find_active_user_should_return_nil_for_a_revoked_token
    token = generate_token
    token.revoke!
    assert_nil PersonalAccessToken.find_active_user(token.plain_value)
  end

  def test_find_active_user_should_return_nil_if_the_user_is_not_active
    token = generate_token(:user => User.find(5))
    assert !User.find(5).active?
    assert_nil PersonalAccessToken.find_active_user(token.plain_value)
  end

  def test_find_active_user_should_record_the_usage
    token = generate_token
    assert_nil token.last_used_on

    PersonalAccessToken.find_active_user(token.plain_value)
    assert_not_nil token.reload.last_used_on
  end

  def test_record_usage_should_not_write_more_than_once_per_interval
    token = generate_token
    token.record_usage
    first_use = token.reload.last_used_on
    assert_not_nil first_use

    token.record_usage
    assert_equal first_use.to_i, token.reload.last_used_on.to_i

    travel_to(PersonalAccessToken::LAST_USED_UPDATE_INTERVAL.from_now + 1.minute) do
      token.record_usage
      assert token.reload.last_used_on > first_use
    end
  end

  def test_destroying_the_user_should_destroy_its_tokens
    generate_token
    assert_difference 'PersonalAccessToken.count', -1 do
      @user.destroy
    end
  end
end
