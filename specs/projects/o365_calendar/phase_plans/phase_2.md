---
status: built; real sign-in verified 2026-10-26
---

# Phase 2: `GraphAuth` — sign-in, token provider, Settings row

## Overview

A new BiscottiKit module, `GraphAuth`, that signs the user in to Microsoft
365 and supplies `GraphClient` with access tokens. It also adds the
Settings → Calendars "Microsoft 365" row and the Home "sign-in has expired"
banner. Nothing reads calendars yet: that wiring is Phase 3. Without an app
registration, the row reads "Not configured" and nothing else changes.

## Steps

1. **`Package.swift`:** the `GraphAuth` product and target (deps
   `GraphCalendar`) and `GraphAuthTests`. `GraphAuth` is added to `AppCore`,
   `HomeUI`, `SettingsUI`, `BiscottiTestSupport` and their test targets.
2. **`GraphAuthConfiguration`:** the client and tenant IDs from user
   defaults (including MDM managed preferences), then `Info.plist`, under
   `MicrosoftGraphClientID` and `MicrosoftGraphTenantID`. The tenant must be
   a GUID or a domain; `common`, `organizations` and `consumers` are
   rejected because the registration is single-tenant. Also sets the
   endpoints, the redirect `msauth.com.synderys.biscotti://auth`, and the
   scopes `openid profile offline_access User.Read Calendars.Read
   Calendars.Read.Shared`.
3. **`PKCE`, `AuthorizationRequest`:** S256 PKCE with a 32-byte verifier.
   The authorize URL carries `state` and `nonce`. It adds `login_hint` on
   reconnect and `prompt=select_account` otherwise. Redirect parsing is
   form-decoded and checks `error`, then `state`, then `code`.
4. **`TokenEndpoint`:** code redemption and refresh as a public client.
   Responses fall into four kinds:
   - reauthentication (`invalid_grant`, `interaction_required`,
     `login_required`, `consent_required`);
   - transient (5xx, 429, `temporarily_unavailable`, `server_error`);
   - other OAuth errors;
   - malformed 2xx.
5. **`Microsoft365Account`, `GraphAccountState`, `GraphStoredSession`,
   `IDTokenClaims`:** the account comes from the ID token. Its signature
   isn't checked: the token comes straight from the token endpoint over
   TLS, which OIDC Core §3.1.3.7 allows. `aud`, `tid` (when the tenant is a
   GUID) and `nonce` are checked.
6. **`GraphTokenStore`:** `KeychainGraphTokenStore` and
   `InMemoryGraphTokenStore`.
7. **`GraphTokenProvider` (actor):**
   - caches the access token and refreshes 5 min before expiry;
   - shares one refresh among concurrent callers;
   - saves a rotated refresh token;
   - uses a generation counter so a refresh that finishes after a sign-out
     or a new sign-in doesn't write back.
   A refresh token refused with an OAuth error is cleared and reported, and
   later calls throw `GraphError.unauthorized` without a request. Anything
   else throws `GraphError.transport` and keeps the session.
8. **`WebAuthenticationSessionRunning` / `SystemWebAuthenticationSession`:**
   `ASWebAuthenticationSession` with a custom-scheme callback. It is not
   ephemeral, so Safari's Microsoft session and the Enterprise SSO plug-in
   still work.
9. **`GraphAccountController` (`@MainActor @Observable`):**
   - `restore()`, which runs once and validates with one refresh;
   - `signIn()` (on reconnect, the username is pre-filled), `cancelSignIn()`
     and `signOut()`;
   - `.needsReconnect` when the provider reports a refused token;
   - `live()` builds it from the configuration, or `.notConfigured`.
10. **AppCore:** owns `microsoft365` (default `.notConfigured` for tests;
    `AppCore+Live` passes `.live()`) and restores it in `onLaunch()`.
11. **SettingsUI:** `Microsoft365AccountRow` at the top of the Calendars
    section, with the view model forwarders in
    `SettingsViewModel+Microsoft365.swift`. The Apple calendar list was
    then removed, leaving the row as the whole section (see Deviations).
12. **HomeUI:** the reconnect banner above the upcoming list.
13. **Tests:**
    - `GraphAuthTests`: configuration, PKCE (the RFC 7636 appendix B vector),
      the authorize URL and redirect, the token endpoint, the ID token, the
      provider and the controller. All run against a fake transport, an
      in-memory store and a fake browser.
    - `SettingsMicrosoft365Tests` and `HomeMicrosoft365Tests`, through
      `BiscottiTestSupport`'s `Microsoft365Fixture`.
14. **Docs:**
    - `docs/entra_app_registration.md`.
    - Updates to `architecture.md` §1/§4, `functional_spec.md` §1/§2/§7 and
      `implementation_plan.md`.
    - This plan.

## Deviations and decisions

- **No MSAL.** MSAL for macOS keeps its token cache in the data-protection
  keychain under a keychain access group. That needs a
  `keychain-access-groups` entitlement backed by a provisioning profile,
  and current builds are ad-hoc signed (Developer ID is Project 9), so
  MSAL fails with `errSecMissingEntitlement` (-34018). The OAuth flow it
  would run is small, so `GraphAuth` implements it directly. The
  refresh-token handling MSAL would have provided is covered by the
  provider tests. Revisit MSAL if the Enterprise SSO plug-in's brokered
  sign-in becomes a requirement; `ASWebAuthenticationSession` gets SSO
  through browser cookies only.
- **Login keychain, not the data-protection keychain.** It needs no
  entitlement. The cost: every ad-hoc rebuild has a new code signature, so
  macOS asks once per build whether Biscotti may read the item. Developer ID
  builds won't ask again.
- **No URL scheme in `App/project.yml`.** `ASWebAuthenticationSession`
  catches its own `.customScheme` callback, so registering the scheme would
  only let other apps' links open Biscotti.
- **IDs from user defaults or `Info.plist` keys; `Info.plist` not edited.**
  IT can supply the IDs with `defaults write` or MDM without a rebuild.
  `App/Resources/Info.plist` was open in a diff session during this phase,
  so no placeholder keys were added to it. Adding the two keys there is
  optional; a blank value is treated as missing.
- **`GraphAccount` → `Microsoft365Account`.** `GraphCalendar` already has a
  public `GraphAccount` (the mapper's "me"). Phase 3 imports both modules
  into AppCore, so GraphAuth's type was renamed to avoid the ambiguity.
- **Refresh failures that keep the session.** Only an OAuth error body
  from Entra ends the session. A status code with no OAuth body (a proxy,
  a captive portal) or a malformed 200 is treated as a network problem.
  This keeps a hotel Wi-Fi login page from signing the user out.
- **Apple calendar list removed from Settings** (2026-10-26). With the
  Microsoft 365 row below the Apple include/exclude list, the user couldn't
  find it, and two calendar sources were confusing. Decision: Microsoft 365
  replaces Apple Calendar (functional spec §1, §7). Phase 2 removes only the
  list (`calendarRow`, `calendarBinding` and `showConnectCalendar` in
  `SettingsView`). `SettingsViewModel` keeps its calendar selection state,
  marked with a `// TODO(o365_calendar Phase 3)`, because the saved
  selection still filters EventKit until Phase 3 switches the source.
- **Apple Calendar prompts hidden when Microsoft 365 is configured**
  (2026-10-26). Home still showed "Allow Calendar Access". With a
  registration (`GraphAccountState.isConfigured`):
  - Home shows "Connect Microsoft 365" instead of the Apple Calendar card,
    and "No meetings coming up" once signed in. Microsoft 365 events don't
    appear until Phase 3.
  - Settings → Permissions drops the Calendar row.
  - The calendar-notification picker needs a signed-in account instead of
    Apple Calendar access.
  Without a registration, Home and Settings behave as upstream does. Phase 3
  removes that fallback (`// TODO(o365_calendar Phase 3)` in
  `HomeViewModel` and `SettingsViewModel+Microsoft365`). Onboarding keeps
  its Apple Calendar step until Phase 3.
- **Deferred to Phase 3** (all done there; see `phase_3.md`):
  - the last-sync time in the Settings row;
  - clearing Graph's calendar snapshot when the account changes;
  - the ManualTestApp "M365 Calendar" tab (real sign-in, SSO, keychain).
  Phase 3 also kept the no-registration fallback described above, instead
  of removing it.
- **Real-tenant check.** IT registered the app with
  `docs/entra_app_registration.md`, and the IDs were set with
  `defaults write`. On 2026-10-26:
  - [x] the browser opened and the account picker showed;
  - [x] the redirect returned to Biscotti ("Signed in to Microsoft 365" in
    the `GraphAuth` log);
  - [x] the refresh token was saved to the login keychain
    (`com.synderys.biscotti.microsoft365`);
  - [ ] a relaunch restores the account without signing in again (macOS
    asks once per ad-hoc build whether Biscotti may read the keychain item);
  - [ ] Disconnect clears it.
