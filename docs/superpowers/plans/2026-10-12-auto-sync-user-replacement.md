# Hub automatic synchronization replacement

**Goal:** Add a Hub administrator checkbox deciding whether automatic Accounts synchronization replaces an existing Hub user. Disabled preserves the current user; explicit nonce-bound Hub login remains independent.

**Architecture:** Add the server-only boolean `discourse_arz_tools_sync_login_replace_existing_user`, default false. The existing no-store status response includes `replace_existing_user`. Accounts interprets confirmed guest status or confirmed enabled replacement as permission to request a ticket. Hub verifies the ticket and reevaluates its current setting before preserving an existing session or resolving/logging in the new user.

**Constraints:** No Git mutations, deployment, dependencies, or IDP changes. Preserve existing nonce, origin, ticket verification, suspension/approval checks and local work.

- [x] Add the setting and English/Persian descriptions in `config/settings.yml` and server locale files.
- [x] Update `app/controllers/discourse_arz_tools_browser_login_controller.rb` status and preservation guard; extend its request specs for enabled/disabled replacement, invalid/suspended users and explicit login.
- [x] Add `shouldSyncHubBrowserSession(options): Promise<boolean | null>` in Accounts; use it in Profile before ticket issuance. Confirm old status responses preserve existing sessions and unknown/malformed states never authorize replacement.
- [x] Run Accounts transport/Profile/Hub tests and build. Validate settings/locales and update README. Run Discourse request specs if a full runtime is available; otherwise report the limitation.

## Verification

71 focused Accounts tests passed, including real Hub policy transport before Profile ticket issuance; the Accounts production build passed. YAML parsing verified the boolean's disabled/server-only defaults and both locale descriptions. Discourse request specs were extended but could not run here: no Ruby/full Discourse runtime is available, WSL enumeration is inaccessible and Docker's Linux engine is not running. No deployment or live setting changes were made.
