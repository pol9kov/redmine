class CreateApiAuthEvents < ActiveRecord::Migration[7.2]
  def change
    create_table :api_auth_events do |t|
      t.references :user
      t.references :personal_access_token
      t.string :credential_kind, limit: 30, null: false
      t.string :http_method, limit: 10, null: false
      t.string :path, limit: 255, null: false
      t.string :remote_ip, limit: 45
      t.datetime :created_at, null: false
    end
  end
end
