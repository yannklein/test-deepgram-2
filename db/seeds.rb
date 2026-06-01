# Sample patients for testing the tutorial.
# Replace phone numbers with your own Twilio test numbers or a verified number.
# Run with: bin/rails db:seed

Patient.find_or_create_by!(phone_number: "+15551234567") do |p|
  p.name           = "Sarah Johnson"
  p.procedure_name = "Root Canal"
  p.procedure_notes = "Avoid hard foods for 24 hours. Take ibuprofen 400mg every 6 hours " \
    "if needed for pain. The temporary crown may feel slightly different — that is normal. " \
    "Call us immediately if pain worsens significantly or if you notice swelling."
end

Patient.find_or_create_by!(phone_number: "+15559876543") do |p|
  p.name           = "Mike Chen"
  p.procedure_name = "Tooth Extraction"
  p.procedure_notes = "Keep gauze in place for 30 minutes with firm pressure. " \
    "Avoid rinsing, spitting, or using a straw for 24 hours. Eat soft foods only today. " \
    "Do not smoke. Call us if bleeding does not slow after 2 hours or if you develop a fever."
end

puts "Seeded #{Patient.count} patients."
