#!/usr/bin/env ruby
# frozen_string_literal: true

# This script unlocks all enterprise features for Chatwoot
# Run with: bundle exec rails runner unlock_enterprise.rb

puts "🔓 Starting Enterprise Feature Unlock..."
puts "=" * 50

# 1. Set Installation Config for pricing plan
puts "\n1️⃣ Setting Installation Config..."
installation_configs = {
  'INSTALLATION_PRICING_PLAN' => 'enterprise',
  'INSTALLATION_PRICING_PLAN_QUANTITY' => 100_000
}

installation_configs.each do |key, value|
  config = InstallationConfig.find_or_initialize_by(name: key)
  config.value = value
  config.save!
  puts "✅ Set #{key} = #{value}"
end

# 2. Update all accounts to enterprise plan
puts "\n2️⃣ Updating all Accounts to Enterprise plan..."
Account.find_each do |account|
  account.custom_attributes ||= {}
  account.custom_attributes['plan_name'] = 'enterprise'
  account.custom_attributes['subscribed_quantity'] = 100_000
  account.save!
  puts "✅ Updated Account ##{account.id} (#{account.name})"
end

# 3. Enable all premium features for all accounts
puts "\n3️⃣ Enabling all premium features..."
premium_features = %w[
  disable_branding
  audit_logs
  sla
  help_center_embedding_search
  captain_integration
  captain_integration_v2
  custom_roles
  saml
  advanced_search
  advanced_search_indexing
  companies
  channel_voice
  csat_review_notes
  conversation_required_attributes
  advanced_assignment
]

Account.find_each do |account|
  account.enable_features(*premium_features)
  puts "✅ Enabled premium features for Account ##{account.id} (#{account.name})"
end

puts "\n" + "=" * 50
puts "✨ Enterprise features unlocked successfully!"
puts "=" * 50
puts "\n📝 Summary:"
puts "- Installation pricing plan: enterprise"
puts "- Total accounts updated: #{Account.count}"
puts "- Premium features enabled: #{premium_features.count}"
puts "\n🔄 Please restart your Chatwoot services for changes to take effect."
