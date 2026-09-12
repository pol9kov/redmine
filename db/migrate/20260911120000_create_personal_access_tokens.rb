class CreatePersonalAccessTokens < ActiveRecord::Migration[7.2]
  def change
    create_table :personal_access_tokens do |t|
      t.references :user, null: false
      t.string :name, limit: 255, null: false
      t.string :hashed_value, limit: 64, null: false
      t.datetime :expires_on, null: false
      t.datetime :revoked_on
      t.timestamps null: false
    end
    add_index :personal_access_tokens, :hashed_value, unique: true
    add_index :personal_access_tokens, [:user_id, :name], unique: true
  end
end
