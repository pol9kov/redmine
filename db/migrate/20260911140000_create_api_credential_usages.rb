class CreateApiCredentialUsages < ActiveRecord::Migration[7.2]
  def change
    create_table :api_credential_usages do |t|
      t.string :credential_kind, limit: 30, null: false
      t.integer :credential_id, null: false
      t.datetime :last_used_on, null: false
    end
    add_index :api_credential_usages, [:credential_kind, :credential_id], unique: true
  end
end
