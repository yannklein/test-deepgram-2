# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_06_01_000002) do
  create_table "call_records", force: :cascade do |t|
    t.string "call_sid"
    t.datetime "created_at", null: false
    t.integer "patient_id", null: false
    t.text "problem_description"
    t.boolean "problem_reported", default: false, null: false
    t.string "recording_url"
    t.string "status", default: "pending", null: false
    t.text "summary"
    t.text "transcript"
    t.datetime "updated_at", null: false
    t.index ["patient_id"], name: "index_call_records_on_patient_id"
  end

  create_table "patients", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "phone_number", null: false
    t.string "procedure_name", null: false
    t.text "procedure_notes"
    t.datetime "updated_at", null: false
  end

  add_foreign_key "call_records", "patients"
end
