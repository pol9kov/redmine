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

# A named, expiring credential that a user can create to access the REST API.
#
# Unlike Token, a user may own several of them and the value is never stored:
# only its SHA256 digest is, the same way Doorkeeper stores OAuth tokens
# (see hash_token_secrets in config/initializers/30-redmine.rb). The value is
# therefore readable once, right after creation, through #plain_value.
class PersonalAccessToken < ApplicationRecord
  # Values are handed out as "<PREFIX><40 hex chars>". The prefix makes the
  # credential recognizable when it leaks and lets the API tell a personal
  # access token from an API key without querying the database.
  PREFIX = 'rmpat_'
  VALUE_FORMAT = /\A#{PREFIX}[0-9a-f]{40}\z/

  belongs_to :user

  # When the token was last used is not a column here: the same fact is kept
  # for the legacy API key too, in one narrow table (see ApiCredentialUsage)
  has_one :usage,
          lambda {where(:credential_kind => ApiCredentialUsage::PERSONAL_ACCESS_TOKEN)},
          :class_name => 'ApiCredentialUsage', :foreign_key => :credential_id,
          :inverse_of => false

  # The value, available only on the instance that generated it
  attr_reader :plain_value

  before_validation :generate_new_value, :on => :create

  validates_presence_of :name, :hashed_value, :expires_on
  validates_length_of :name, :maximum => 60
  validates_uniqueness_of :hashed_value, :case_sensitive => true
  validate :validate_expiration, :on => :create

  scope :active, lambda {where(:revoked_on => nil).where("#{table_name}.expires_on > ?", Time.now)}

  # Returns the active user owning the given value, or nil
  def self.find_active_user(value)
    token = find_by_value(value)
    return nil unless token&.active?

    user = token.user
    return nil unless user&.active?

    token.record_usage
    user
  end

  # Returns the token matching the given value, expired or revoked ones included
  def self.find_by_value(value)
    value = value.to_s
    return nil unless VALUE_FORMAT.match?(value)

    hashed_value = digest(value)
    token = find_by(:hashed_value => hashed_value)
    return nil unless token
    return nil unless ActiveSupport::SecurityUtils.secure_compare(token.hashed_value.to_s, hashed_value)

    token
  end

  def self.digest(value)
    Digest::SHA256.hexdigest(value.to_s)
  end

  def self.generate_value
    "#{PREFIX}#{Redmine::Utils.random_hex(20)}"
  end

  def expired?
    expires_on.nil? || expires_on <= Time.now
  end

  def revoked?
    revoked_on.present?
  end

  def active?
    !revoked? && !expired?
  end

  def revoke!
    update!(:revoked_on => Time.now) unless revoked?
    self
  end

  # When the token was last used, or nil if it never was
  def last_used_on
    usage&.last_used_on
  end

  # Records that the token was used, at most once per
  # ApiCredentialUsage::LAST_USED_UPDATE_INTERVAL
  def record_usage(time=Time.now)
    ApiCredentialUsage.record(ApiCredentialUsage::PERSONAL_ACCESS_TOKEN, id, time)
    association(:usage).reset
    self
  end

  def to_s
    name.to_s
  end

  private

  def generate_new_value
    @plain_value = self.class.generate_value
    self.hashed_value = self.class.digest(@plain_value)
  end

  # An expiration date is mandatory and can only be set in the future
  def validate_expiration
    if expires_on.present? && expires_on <= Time.now
      errors.add(:expires_on, :invalid)
    end
  end
end
