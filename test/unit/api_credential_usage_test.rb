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

class ApiCredentialUsageTest < ActiveSupport::TestCase
  PAT = ApiCredentialUsage::PERSONAL_ACCESS_TOKEN
  API_KEY = ApiCredentialUsage::API_KEY

  def test_record_should_create_the_row_of_an_unmarked_credential
    assert_difference 'ApiCredentialUsage.count', 1 do
      ApiCredentialUsage.record(API_KEY, 42)
    end
    usage = ApiCredentialUsage.last
    assert_equal API_KEY, usage.credential_kind
    assert_equal 42, usage.credential_id
    assert_not_nil usage.last_used_on
  end

  def test_record_should_refresh_the_mark_on_every_use
    ApiCredentialUsage.record(API_KEY, 42)
    first_use = ApiCredentialUsage.last.last_used_on

    assert_no_difference 'ApiCredentialUsage.count' do
      travel_to(1.minute.from_now) do
        assert_not_nil ApiCredentialUsage.record(API_KEY, 42)
      end
    end
    assert ApiCredentialUsage.last.last_used_on > first_use
  end

  def test_record_should_keep_the_kinds_apart
    ApiCredentialUsage.record(API_KEY, 42)
    assert_difference 'ApiCredentialUsage.count', 1 do
      ApiCredentialUsage.record(PAT, 42)
    end
    assert_equal 2, ApiCredentialUsage.where(:credential_id => 42).count
  end

  def test_should_reject_a_second_row_for_the_same_credential
    ApiCredentialUsage.record(API_KEY, 42)
    duplicate = ApiCredentialUsage.new(
      :credential_kind => API_KEY, :credential_id => 42, :last_used_on => Time.now
    )
    assert !duplicate.save
    assert_includes duplicate.errors.attribute_names, :credential_id
  end

  def test_the_database_should_reject_a_second_row_for_the_same_credential
    ApiCredentialUsage.record(API_KEY, 42)
    duplicate = ApiCredentialUsage.new(
      :credential_kind => API_KEY, :credential_id => 42, :last_used_on => Time.now
    )
    assert_raise ActiveRecord::RecordNotUnique do
      duplicate.save(:validate => false)
    end
  end

  def test_record_should_not_raise_when_two_first_uses_race
    ApiCredentialUsage.stubs(:create!).raises(ActiveRecord::RecordNotUnique.new('duplicate key'))
    usage = nil
    assert_nothing_raised do
      usage = ApiCredentialUsage.record(API_KEY, 42)
    end
    assert_nil usage
  end

  def test_should_reject_an_unknown_credential_kind
    usage = ApiCredentialUsage.new(
      :credential_kind => 'failed', :credential_id => 42, :last_used_on => Time.now
    )
    assert !usage.save
    assert_includes usage.errors.attribute_names, :credential_kind
  end

  def test_kinds_should_be_the_words_the_audit_trail_uses
    assert_equal [], ApiCredentialUsage::KINDS - ApiAuthEvent::CREDENTIAL_KINDS
  end
end
