#!/usr/bin/env bats
# The two files that define the cage and need no sandbox to check:
# managed-settings.json stays policy-only with the inner sandbox on, and
# claude-home/ (OAuth tokens) stays out of git.

load helpers

setup() {
    cd "$REPO" || return 1
    M=managed-settings.json
}

# Managed keys silently override the same key in the user's settings, so a
# new one is a deliberate decision: extend these lists in the same change.
@test "managed settings: top-level keys are all policy" {
    allowed='["env","allowManagedHooksOnly","disableSideloadFlags","sandbox","companyAnnouncements"]'
    extra="$(jq -r --argjson a "$allowed" '(keys - $a)[]' "$M")"
    [ -z "$extra" ] || { echo "unexpected keys: $extra"; return 1; }
}
@test "managed settings: env keys are all policy" {
    allowed='["DO_NOT_TRACK","DISABLE_TELEMETRY","DISABLE_ERROR_REPORTING"]'
    extra="$(jq -r --argjson a "$allowed" '((.env // {} | keys) - $a)[]' "$M")"
    [ -z "$extra" ] || { echo "unexpected env keys: $extra"; return 1; }
}
@test "managed settings: managed hooks only" { [ "$(jq .allowManagedHooksOnly "$M")" = true ]; }
@test "managed settings: sideload flags disabled" { [ "$(jq .disableSideloadFlags "$M")" = true ]; }
@test "managed settings: inner sandbox enabled" { [ "$(jq .sandbox.enabled "$M")" = true ]; }
@test "managed settings: inner sandbox fails if unavailable" {
    [ "$(jq .sandbox.failIfUnavailable "$M")" = true ]
}
@test "managed settings: no unsandboxed commands" {
    [ "$(jq .sandbox.allowUnsandboxedCommands "$M")" = false ]
}
@test "managed settings: strict allowlist" { [ "$(jq .sandbox.network.strictAllowlist "$M")" = true ]; }
@test "managed settings: managed domains only" {
    [ "$(jq .sandbox.network.allowManagedDomainsOnly "$M")" = true ]
}
# "*" or "*.com" would reopen the whole network under a plausible-looking entry.
@test "managed settings: no overbroad wildcard" {
    bad="$(jq -r '.sandbox.network.allowedDomains[]
        | select(startswith("*") and (split(".") | length) < 3)' "$M")"
    [ -z "$bad" ] || { echo "overbroad: $bad"; return 1; }
}

@test "claude-home/ tracks only its README" {
    [ "$(git ls-files claude-home)" = claude-home/README.md ]
}
@test "claude-home/.claude.json is ignored" { git check-ignore -q claude-home/.claude.json; }
@test "claude-home credentials are ignored" {
    git check-ignore -q claude-home/.claude/.credentials.json
}
