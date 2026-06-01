class CreatePatients < ActiveRecord::Migration[8.1]
  def change
    create_table :patients do |t|
      # Basic patient info — who we're calling and about what
      t.string :name,           null: false
      t.string :phone_number,   null: false  # Must be in E.164 format, e.g. +12125551234
      t.string :procedure_name, null: false  # e.g. "Root Canal"
      t.text   :procedure_notes             # Aftercare instructions the bot will read aloud

      t.timestamps
    end
  end
end
