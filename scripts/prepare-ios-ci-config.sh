#!/usr/bin/env bash
set -euo pipefail

# Simulator journey tests inject offline fixtures. This key cannot authenticate
# with Supabase; CI artifacts must never be signed or uploaded for distribution.
# Keep the real project's pinned URLs so configuration and plist checks still run.
if [[ "${GITHUB_ACTIONS:-}" != "true" || -z "${RUNNER_TEMP:-}" || -z "${GITHUB_ENV:-}" ]]; then
  echo "This configuration is only for GitHub Actions simulator jobs." >&2
  exit 1
fi
config_path="$RUNNER_TEMP/SignalWord-CI.xcconfig"
cat > "$config_path" <<'CONFIG'
SIGNALWORD_SUPABASE_URL = https:/$()/voepalyamwgenceawdvl.supabase.co
SIGNALWORD_USER_API_URL = https:/$()/voepalyamwgenceawdvl.supabase.co/functions/v1/user-api
SIGNALWORD_SUPABASE_PUBLISHABLE_KEY = sb_publishable_CI_SIMULATOR_NOT_A_LIVE_KEY
// Sign-in UI needs these settings even when its lifecycle uses offline fixtures.
SIGNALWORD_VERIFICATION_URL = https:/$()/www.signalword.app/onboarding/verify.html
SIGNALWORD_TURNSTILE_SITE_KEY = CI_SIMULATOR_NOT_A_LIVE_SITE_KEY
CONFIG
printf 'SIGNALWORD_XCCONFIG=%s\n' "$config_path" >> "$GITHUB_ENV"
