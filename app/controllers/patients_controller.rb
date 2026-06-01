class PatientsController < ApplicationController
  def index
    @patients = Patient.includes(:call_records).order(created_at: :desc)
  end

  def show
    @patient     = Patient.find(params[:id])
    @call_records = @patient.call_records.recent
  end

  def new
    @patient = Patient.new
  end

  def create
    @patient = Patient.new(patient_params)

    if @patient.save
      redirect_to @patient, notice: "Patient added."
    else
      render :new, status: :unprocessable_entity
    end
  end

  # POST /patients/:id/call
  # Queues an outbound call for this patient.
  # Returns immediately — the actual Twilio API call happens in the background.
  def call
    patient = Patient.find(params[:id])
    InitiateCallJob.perform_later(patient.id)
    redirect_to patient, notice: "Call queued for #{patient.name}. Check back in a minute."
  end

  private

  def patient_params
    params.require(:patient).permit(:name, :phone_number, :procedure_name, :procedure_notes)
  end
end
