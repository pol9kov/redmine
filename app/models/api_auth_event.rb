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

# One API authentication attempt, kept as an audit trail row.
#
# Events are written by ApplicationController#find_user_by_api_credential,
# the single seam every API credential passes through, so a legacy API key
# leaves the same trail as a personal access token. A row carries no secret
# material at all, not even a prefix of the credential, and deliberately
# outlives the user and token it points to: an audit trail that is erased
# together with the account it describes is not an audit trail.
class ApiAuthEvent < ApplicationRecord
  CREDENTIAL_KINDS = %w(personal_access_token api_key failed)

  belongs_to :user, :optional => true
  belongs_to :personal_access_token, :optional => true

  validates_presence_of :credential_kind, :http_method, :path
  validates_inclusion_of :credential_kind, :in => CREDENTIAL_KINDS

  # Writes the event for one authentication attempt and never raises: a
  # failed audit insert must fail loud in the log, not turn an otherwise
  # well-formed API request into a 500.
  def self.record(request, user: nil, personal_access_token: nil)
    credential_kind =
      if user.nil?
        'failed'
      elsif personal_access_token
        'personal_access_token'
      else
        'api_key'
      end
    create!(
      :credential_kind => credential_kind,
      :user => user,
      :personal_access_token => personal_access_token,
      :http_method => request.request_method,
      # request.path carries no query string, so a credential passed as
      # ?key=... can never end up in the audit table
      :path => request.path.to_s[0, 255],
      :remote_ip => request.remote_ip
    )
  rescue StandardError => e
    logger&.error("Could not record API auth event: #{e.class}: #{e.message}")
    nil
  end
end
