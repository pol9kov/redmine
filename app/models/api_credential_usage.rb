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
#
# When an API credential was last used, kept as one row per credential.
#
# The fact lives in its own table rather than as a column on the credential
# because it is the same fact for two different credentials: a personal access
# token, and the legacy API key, which is a row in the shared +tokens+ table
# and cannot get a column of its own without also giving one to sessions,
# autologin and password recovery. A row is identified by the pair
# (credential_kind, credential_id), unique by index, and the kinds are the same
# words ApiAuthEvent uses for the same thing.
class ApiCredentialUsage < ApplicationRecord
  PERSONAL_ACCESS_TOKEN = 'personal_access_token'
  API_KEY = 'api_key'
  KINDS = [PERSONAL_ACCESS_TOKEN, API_KEY].freeze

  # The mark is refreshed at most once per interval, so that a burst of API
  # requests does not turn every authenticated read into a write. It is the
  # single home of that interval: PersonalAccessToken asks this class.
  LAST_USED_UPDATE_INTERVAL = 1.hour

  validates_presence_of :credential_kind, :credential_id, :last_used_on
  validates_inclusion_of :credential_kind, :in => KINDS
  validates_uniqueness_of :credential_id, :scope => :credential_kind

  # Records that the credential was used, at most once per
  # LAST_USED_UPDATE_INTERVAL, and returns the row when it was written
  def self.record(kind, id, time=Time.now)
    usage = find_by(:credential_kind => kind, :credential_id => id)
    if usage.nil?
      create!(:credential_kind => kind, :credential_id => id, :last_used_on => time)
    elsif usage.last_used_on <= time - LAST_USED_UPDATE_INTERVAL
      usage.update_column(:last_used_on, time)
      usage
    end
  rescue ActiveRecord::RecordNotUnique
    # Two first-ever uses of the same credential raced; the other one wrote the
    # mark, which is all this method was after
    nil
  end
end
