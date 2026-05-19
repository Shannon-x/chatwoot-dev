#!/usr/bin/env bash
# =============================================================================
# Enterprise Feature Unlock Patch Script
# =============================================================================
# This script patches Chatwoot source files to unlock all enterprise features
# for self-hosted deployments. It is designed to be run AFTER merging upstream
# changes, to re-apply the enterprise unlock patches if they were overwritten.
#
# Usage:
#   ./scripts/patch_enterprise.sh
#
# Files modified:
#   - lib/chatwoot_app.rb   (enterprise?, chatwoot_cloud?, etc.)
#   - lib/chatwoot_hub.rb   (pricing_plan, pricing_plan_quantity)
#   - config/features.yml   (all premium features enabled)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🔓 Applying Enterprise Unlock Patches..."
echo "   Project root: $PROJECT_ROOT"
echo "================================================"

# ---------------------------------------------------------------------------
# 1. Patch lib/chatwoot_app.rb
# ---------------------------------------------------------------------------
CHATWOOT_APP="$PROJECT_ROOT/lib/chatwoot_app.rb"
if [ ! -f "$CHATWOOT_APP" ]; then
  echo "❌ ERROR: $CHATWOOT_APP not found"
  exit 1
fi

echo ""
echo "1️⃣  Patching chatwoot_app.rb ..."

# Use Ruby to patch the file in-place for reliability
ruby -i -E UTF-8 -e '
  content = File.read(ARGV[0])

  # Patch enterprise? method
  content.gsub!(
    /def self\.enterprise\?\n.*?(?=\n  def self\.|^end)/m,
    "def self.enterprise?\n    # Always return true to enable all enterprise features\n    true\n  end\n\n  "
  )

  # Patch chatwoot_cloud? method
  content.gsub!(
    /def self\.chatwoot_cloud\?\n.*?(?=\n  def self\.|^end)/m,
    "def self.chatwoot_cloud?\n    # Always return true to enable all cloud-only features in self-hosted enterprise\n    true\n  end\n\n  "
  )

  # Patch self_hosted_enterprise? method
  content.gsub!(
    /def self\.self_hosted_enterprise\?\n.*?(?=\n  def self\.|^end)/m,
    "def self.self_hosted_enterprise?\n    # Always return true for self-hosted enterprise\n    true\n  end\n\n  "
  )

  # Patch advanced_search_allowed? method
  content.gsub!(
    /def self\.advanced_search_allowed\?\n.*?(?=\n  def self\.|^end)/m,
    "def self.advanced_search_allowed?\n    # Always allow advanced search\n    ENV.fetch(\"OPENSEARCH_URL\", nil).present? || true\n  end\n\n  "
  )

  File.write(ARGV[0], content)
' "$CHATWOOT_APP"

echo "   ✅ chatwoot_app.rb patched"

# ---------------------------------------------------------------------------
# 2. Patch lib/chatwoot_hub.rb
# ---------------------------------------------------------------------------
CHATWOOT_HUB="$PROJECT_ROOT/lib/chatwoot_hub.rb"
if [ ! -f "$CHATWOOT_HUB" ]; then
  echo "❌ ERROR: $CHATWOOT_HUB not found"
  exit 1
fi

echo ""
echo "2️⃣  Patching chatwoot_hub.rb ..."

ruby -i -E UTF-8 -e '
  content = File.read(ARGV[0])

  # Patch pricing_plan method
  content.gsub!(
    /def self\.pricing_plan\n.*?(?=\n  def self\.)/m,
    "def self.pricing_plan\n    # Always return enterprise plan\n    '\''enterprise'\''\n  end\n\n  "
  )

  # Patch pricing_plan_quantity method
  content.gsub!(
    /def self\.pricing_plan_quantity\n.*?(?=\n  def self\.)/m,
    "def self.pricing_plan_quantity\n    # Return unlimited quantity\n    100_000\n  end\n\n  "
  )

  File.write(ARGV[0], content)
' "$CHATWOOT_HUB"

echo "   ✅ chatwoot_hub.rb patched"

# ---------------------------------------------------------------------------
# 3. Patch config/features.yml — enable all premium features
# ---------------------------------------------------------------------------
FEATURES_YML="$PROJECT_ROOT/config/features.yml"
if [ ! -f "$FEATURES_YML" ]; then
  echo "❌ ERROR: $FEATURES_YML not found"
  exit 1
fi

echo ""
echo "3️⃣  Patching features.yml (enabling all premium features) ..."

# Use Ruby/YAML-aware approach: for every feature with premium: true,
# set enabled: true
ruby -E UTF-8 -e '# encoding: UTF-8' -e '
  lines = File.readlines(ARGV[0])
  i = 0
  changed = 0
  while i < lines.length
    # Look for "enabled: false" that is followed (within next 3 lines) by "premium: true"
    if lines[i] =~ /^(\s*)enabled:\s*false\s*$/
      indent = $1
      # Check if any of the next 3 lines has "premium: true"
      has_premium = (1..3).any? { |j| i + j < lines.length && lines[i + j] =~ /premium:\s*true/ }
      if has_premium
        lines[i] = "#{indent}enabled: true\n"
        changed += 1
      end
    end
    i += 1
  end
  File.write(ARGV[0], lines.join)
  puts "   [OK] features.yml patched (#{changed} premium features enabled)"
' "$FEATURES_YML"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "================================================"
echo "✨ Enterprise unlock patches applied successfully!"
echo "================================================"
echo ""
echo "📝 Patched files:"
echo "   - lib/chatwoot_app.rb     (enterprise?, chatwoot_cloud?, etc. → true)"
echo "   - lib/chatwoot_hub.rb     (pricing_plan → 'enterprise')"
echo "   - config/features.yml     (all premium features → enabled)"
echo ""
echo "💡 To also update the database, run:"
echo "   bundle exec rails runner unlock_enterprise.rb"
