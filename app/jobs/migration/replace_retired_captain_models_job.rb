class Migration::ReplaceRetiredCaptainModelsJob < ApplicationJob
  queue_as :async_database_migration

  def perform
    replace_installation_model
    replace_account_models
  end

  private

  def replace_installation_model
    # A custom endpoint may serve its own deployment under a retired model name, so leave that to the operator.
    return unless Llm::FeatureRouter.standard_openai_endpoint?

    config = InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')
    config.update!(value: Llm::Config::DEFAULT_MODEL) if Llm::Models.replacement_for_retired_model(config&.value)
  end

  def replace_account_models
    Account.find_each do |account|
      models = account.captain_models
      replacements = models&.transform_values { |model| Llm::Models.replacement_for_retired_model(model) || model }
      account.update!(captain_models: replacements) if replacements != models
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("[retired-captain-models] account_id=#{account.id} #{e.record.errors.full_messages.to_sentence}")
    end
  end
end
