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

  private

  def patient_params
    params.require(:patient).permit(:name, :phone_number, :procedure_name, :procedure_notes)
  end
end
