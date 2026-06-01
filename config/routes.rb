Rails.application.routes.draw do
  root "patients#index"

  # Patient management + triggering calls
  resources :patients, only: [ :index, :show, :new, :create ] do
    member do
      post :call  # POST /patients/:id/call — queues InitiateCallJob
    end
  end

  # ── Twilio webhook endpoints ───────────────────────────────────────────────
  # These are called by Twilio's servers, not by a browser.
  # They must be publicly accessible (use ngrok in development).

  # Twilio calls this when patient picks up → we return TwiML instructions
  post "/twilio/twiml",     to: "twilio#twiml",     as: :twilio_twiml

  # We serve Deepgram TTS audio from here — Twilio's <Play> fetches it
  get  "/twilio/tts/:id",   to: "twilio#tts",        as: :twilio_tts

  # Twilio calls this when the patient finishes recording their response
  post "/twilio/recording", to: "twilio#recording",  as: :twilio_recording

  # Twilio calls this when call status changes (ringing, failed, etc.)
  post "/twilio/status",    to: "twilio#status",     as: :twilio_status

  get "up" => "rails/health#show", as: :rails_health_check
end
