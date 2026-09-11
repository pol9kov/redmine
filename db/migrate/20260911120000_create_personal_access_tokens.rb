class CreatePersonalAccessTokens < ActiveRecord::Migration[7.2]
  def change
    create_table :personal_access_tokens do |t|
      t.references :user, null: false
      t.string :name, null: false
      t.string :hashed_value, limit: 64, null: false
      t.datetime :expires_on, null: false
      t.datetime :last_used_on
      t.datetime :revoked_on
      t.timestamps null: false
    end
    add_index :personal_access_tokens, :hashed_value, unique: true
  end
end
