# Meeting App Catalog (Bundle IDs + Meeting-Link Formats)

A comprehensive catalog of video-conferencing and meeting platforms, their macOS bundle
identifiers, and meeting-link URL formats. This data feeds the production watchlists in
`BundledMeetingCatalog` (MeetingCatalog package) and `AudioProcess` (AudioCapture package).

## How this was built

Every entry was **web-researched with cited sources** (June 2026) -- not guessed from
convention. Primary sources: Homebrew Cask `uninstall`/`zap` stanzas, FleetDM software
catalog, MacUpdater DB, Jamf PPPC profiles, doesitarm.com Info.plist dumps, and the
iTunes Lookup API. Each entry carries an explicit confidence level (high/medium/low).
Only high- and medium-confidence entries are added to the production code; lower-confidence
and unverified entries are documented here for future hardware verification.

See also: [`research/audio/meeting_app_bundle_ids.md`](../audio/meeting_app_bundle_ids.md)
for audio-routing and helper-process specifics (which process actually produces audio
during a call).

## Watchlist drift risk

The bundle-ID watchlist currently lives in **three places**:

1. `Packages/BiscottiKit/Sources/MeetingCatalog/BundledMeetingCatalog.swift` -- canonical
   catalog (bundle IDs, display names, helper mappings, link regexes)
2. `Packages/AudioCapture/Sources/AudioCapture/AudioProcess.swift` -- second production
   copy used by audio stream monitors (bundle IDs + display names)
3. `experiments/AudioLab/Sources/AudioProcess.swift` -- disposable experiment copy (frozen,
   do not update)

Copies 1 and 2 must stay in sync manually until MeetingDetection (Project 5) unifies them
behind a shared `MeetingCatalog` protocol backed by `RemoteConfig`. The experiment copy is
intentionally stale. When editing bundle IDs or display names, always update both production
files together.

## Detection philosophy: recall over precision

Conference-link regexes are anchored on **distinctive host + join-path prefix**, then accept
any non-whitespace tail. This biases toward recall (never miss a real meeting link) over
precision (occasionally a stray marketing URL in event text might be misclassified as a
meeting link). A rare false-positive is an acceptable trade: the worst outcome is showing a
"Join" button on a non-meeting event, which is harmless. Missing a real meeting link means
the app fails to detect a meeting, which is a worse user experience.

## Which entries were applied to code

Entries below are marked **ADDED TO CODE** (bundle ID and/or link regex added to production
config dicts) or **DOC ONLY** (documented here but not in code) with the reason.

---

## Active Platforms

### 1. Zoom

- **Native macOS:** Yes (C++/Qt, arm64)
- **Bundle IDs:**
  - `us.zoom.xos` -- main app -- source: Homebrew cask `zoom.rb`, Jamf PPPC -- **high** -- ALREADY IN CODE
  - `us.zoom.ZoomDaemon` -- privileged helper daemon -- high -- doc only (not user-facing)
  - `us.zoom.airhost` -- audio/screen-share helper -- high (identity) / audio role UNVERIFIED -- doc only
  - `us.zoom.caphost`, `us.zoom.CptHost` -- capture helpers -- medium -- doc only
- **Meeting-link formats:**
  - `https://zoom.us/j/1234567890` (standard, 9-11 digit), `?pwd=...` (passcode) -- high
  - `https://company.zoom.us/j/...`, `https://us06web.zoom.us/j/...` (subdomains) -- high
  - `https://zoom.us/my/johndoe` (personal room) -- high
  - `https://zoom.us/w/123...` (webinar), `https://zoom.us/s/123...` (host start) -- high/medium
  - `https://zoomgov.com/j/...`, `/my/...`, `/w/...`, `/s/...` (Zoom for Government) -- high
  - **Regex (updated):** `https?://[\w.-]*\.?zoom\.us/(?:j|my|w|s|wc)/[^\s]+` and `zoomgov.com` equivalent. Join-path prefixes anchor the match; ID/slug is unconstrained -- matches numeric IDs, name-join links, and passcode query strings.
  - Previous regex: `https?://[\w.-]*zoom\.us/j/\d+[^\s]*` (only `/j/`, digits-only, no gov, no personal room)
- **ADDED TO CODE:** Updated link regex to cover `/j/`, `/my/`, `/w/`, `/s/`, `/wc/` paths + `zoomgov.com`. Bundle ID unchanged.

### 2. Microsoft Teams

- **Native macOS:** Yes (WebView2 host shell, arm64; replaced Electron in "new Teams" 2023)
- **Bundle IDs:**
  - `com.microsoft.teams2` -- new Teams (current default since Mar 2024) -- source: Homebrew cask, MS Learn -- **high** -- ALREADY IN CODE
  - `com.microsoft.teams` -- classic Teams (Electron, EOL July 2025) -- high -- doc only (deprecated, low value in 2026)
- **Meeting-link formats:**
  - `https://teams.microsoft.com/l/meetup-join/...` (legacy long format) -- high
  - `https://teams.microsoft.com/meet/abc123def` (NEW short format, 2025+) -- high
  - `https://teams.live.com/meet/...` (consumer/personal) -- high
  - `https://gov.teams.microsoft.us/l/meetup-join/...`, `dod.teams.microsoft.us/...` (US Gov) -- high
  - **Regex (updated):** `https?://(?:teams\.microsoft\.com/(?:l/meetup-join|meet)/|teams\.live\.com/meet/|(?:gov|dod)\.teams\.microsoft\.us/l/meetup-join/)[^\s]+`
  - Previous regex: `https?://teams\.microsoft\.com/l/meetup-join/[^\s]+` (only legacy format)
- **ADDED TO CODE:** Updated link regex to cover `/meet/` short format, `teams.live.com`, and gov domains.

### 3. Google Meet

- **Native macOS:** Browser-only (no native app; Chrome PWA / Safari "Add to Dock" shim)
- **Bundle IDs:** N/A. Meetings run in `com.google.Chrome`, `com.apple.Safari`, `company.thebrowser.Browser` (all already in code as browser hosts).
- **Meeting-link formats:**
  - `https://meet.google.com/abc-mnop-xyz` -- 10 lowercase letters in 3-4-3 dash-separated groups -- high
  - `https://meet.google.com/lookup/<nickname>` -- named/personal room lookup -- high
  - **Regex (updated):** `https?://meet\.google\.com/(?:lookup/[^\s]+|[a-z]{3}-[a-z]{4}-[a-z]{3})` -- matches 3-4-3 codes or `/lookup/<nickname>`.
  - Previous regex: `https?://meet\.google\.com/[a-z-]+` (loose; matched non-meeting paths like `/new`, `/landing`)
- **ADDED TO CODE:** Tightened to 3-4-3 format + `/lookup/` path. No bundle ID change.

### 4. Cisco Webex

- **Native macOS:** Yes (Qt/C++ + web views, arm64)
- **Bundle IDs:**
  - `Cisco-Systems.Spark` -- **Webex unified app** (formerly Spark; the actively-developed client) -- source: Homebrew cask `webex.rb` -- **high** -- **ADDED TO CODE** (important gap -- was missing)
  - `com.cisco.webexmeetingsapp` -- Webex Meetings (classic standalone, being sunset) -- source: Homebrew cask `webex-meetings.rb` -- high -- ALREADY IN CODE
  - `com.webex.meetingmanager` -- meeting engine helper -- high (identity) / audio role UNVERIFIED -- doc only
  - `com.cisco.webex.webexmta` -- MTA helper -- high -- doc only
- **Meeting-link formats:**
  - `https://acme.webex.com/meet/jsmith` (personal room) -- high
  - `https://acme.webex.com/acme/j.php?MTID=m...` (scheduled) -- high
  - `https://acme.my.webex.com/...` (business scheduled) -- medium
  - **Regex (updated, recall-first):** `https?://(?:[\w.-]+\.)?webex\.com/[^\s]+` -- any `*.webex.com` path. Recall-first: the `webex.com` host is distinctive enough that false positives from marketing pages in event text are rare and harmless.
  - Previous regex: `https?://[\w.-]*webex\.com/[^\s]+` (original V1, then briefly tightened to specific paths, now reverted to broad/recall-first)
- **ADDED TO CODE:** Added `Cisco-Systems.Spark` bundle ID + display name. Recall-first link regex.

### 5. GoTo Meeting (GoTo)

- **Native macOS:** Yes (Electron; legacy app x86-only, requires Rosetta)
- **Bundle IDs:**
  - `com.logmein.GoToMeeting` -- legacy GoToMeeting app -- source: PPPC profile (team ID `GFNFVT632V`), doesitarm, cask zap -- **high** -- **ADDED TO CODE**
  - `com.logmein.goto` -- newer unified GoTo app -- source: GoTo official cleanup script -- **medium** -- **ADDED TO CODE**
- **Meeting-link formats:**
  - `https://global.gotomeeting.com/join/850393077` (standard, 9-digit) -- high
  - `https://gotomeet.me/JohnSmith` (personal room) -- high
  - `https://meet.goto.com/123456789` (current invite format) -- medium
  - **Regex:** `https?://(?:global\.gotomeeting\.com/join/[^\s]+|gotomeet\.me/[^\s]+|meet\.goto\.com/[^\s]+)` -- distinctive hosts, any join path
- **ADDED TO CODE:** Bundle IDs, display names, and link regex.

### 6. RingCentral

- **Native macOS:** Yes (Electron, Chromium/WebRTC)
- **Bundle IDs:**
  - `com.ringcentral.glip` -- main current app (rebranded Glip) -- source: Homebrew cask `ringcentral.json` -- **high** -- **ADDED TO CODE**
- **Meeting-link formats:**
  - `https://v.ringcentral.com/join/469909326` (RingEX, 9-12 digit) -- high
  - `https://video.ringcentral.com/join/...` -- high
  - `https://meetings.ringcentral.com/j/1234567890` (legacy, 10-digit) -- high
  - **Regex:** `https?://(?:v|video|meetings)\.ringcentral\.com/(?:join|j)/[^\s]+` -- /join or /j path, any tail
- **ADDED TO CODE:** Bundle ID, display name, and link regex.

### 7. Slack

- **Native macOS:** Yes (Electron)
- **Bundle IDs:**
  - `com.tinyspeck.slackmacgap` -- main app -- source: Homebrew cask, Jamf TCC -- **high** -- ALREADY IN CODE
  - `com.tinyspeck.slackmacgap.helper` -- audio-producing process during huddles (verified on hardware) -- **high** -- ALREADY IN CODE
- **Meeting-link formats:**
  - `https://app.slack.com/huddle/T0123ABCD/C0123ABCD` (`/huddle/TEAM/CHANNEL`) -- medium
  - **Regex (existing):** `https?://app\.slack\.com/huddle/[^\s]+`
  - **NOTE: UNVERIFIED.** Slack's official deep-linking docs list only `slack://` schemes; the `app.slack.com/huddle/` pattern is plausible and widely repeated in third-party guides but no authoritative source confirms a real pasted huddle URL. Huddles require workspace auth (no anonymous join). Kept in code but treat as unverified.
- **ALREADY IN CODE:** No changes.

### 8. Discord

- **Native macOS:** Yes (Electron)
- **Bundle IDs:**
  - `com.hnc.Discord` -- main (stable) -- source: Homebrew cask `discord.rb` -- **high** -- ALREADY IN CODE
  - `com.hnc.DiscordPTB` (Public Test Build), `com.hnc.DiscordCanary` -- side-by-side builds -- high -- doc only (niche)
- **Meeting-link formats:** Discord has **no per-call/meeting URL**. Server invites (`discord.gg/<code>`) go to a server, not a call. Detection relies on bundle-ID/process audio activity.
- **ALREADY IN CODE:** No changes. No link regex (none applicable).

### 9. FaceTime

- **Native macOS:** Yes (built-in `/System/Applications/FaceTime.app`)
- **Bundle IDs:**
  - `com.apple.FaceTime` -- app -- source: doesitarm Info.plist -- **high** -- ALREADY IN CODE
  - `com.apple.avconferenced` -- daemon, audio-producing process (verified on hardware) -- **high** -- ALREADY IN CODE
- **Meeting-link formats:**
  - `https://facetime.apple.com/join#v=1&p=BASE64&k=BASE64` -- high
  - **Regex (new):** `https?://facetime\.apple\.com/join#[^\s]+`
  - Hash fragment keeps key material client-side. Web guests join via browser (Monterey+).
- **ADDED TO CODE:** New link regex. Bundle IDs unchanged.

### 10. Whereby

- **Native macOS:** Browser-only (no native macOS app; iOS app is iPhone/iPad only)
- **Bundle IDs:** N/A -- browser-only.
- **Meeting-link formats:**
  - `https://whereby.com/my-room` (personal/free) -- high
  - `https://mycompany.whereby.com/<room>` (business subdomain) -- high
  - **Regex:** `https?://(?:[a-zA-Z0-9-]+\.)?whereby\.com/(?!information|blog|user|sitemap|pricing|signin|download)[a-zA-Z0-9][^\s]*` -- negative lookahead excludes known marketing/auth paths; tail is `[^\s]*` (recall-first)
- **ADDED TO CODE:** Link regex only (no bundle ID -- browser-only).

### 11. Jitsi Meet

- **Native macOS:** Yes (Electron, `jitsi/jitsi-meet-electron`)
- **Bundle IDs:**
  - `org.jitsi.jitsi-meet` -- Electron desktop app -- source: `build.appId` in package.json -- **high** -- **ADDED TO CODE**
- **Meeting-link formats:**
  - `https://meet.jit.si/MyTeamStandup` -- high
  - `https://8x8.vc/<AppID>/MyRoom` (JaaS / 8x8 hosted Jitsi) -- high
  - Self-hosted Jitsi instances use infinite custom domains -- only `meet.jit.si` and `8x8.vc` are host-detectable.
  - **Regex:** `https?://meet\.jit\.si/[^\s/?#]+(?:/[^\s/?#]+)?` (with optional namespace segment) and `https?://(?:[a-z]+\.)?8x8\.vc/[^\s/?#]+/[^\s/?#]+`
  - The `8x8.vc` regex is shared between Jitsi and 8x8 Work (labeled "8x8 / Jitsi").
- **ADDED TO CODE:** Bundle ID, display name, and `meet.jit.si` link regex. `8x8.vc` regex shared with 8x8 entry.

### 12. 8x8 Work

- **Native macOS:** Yes (Electron, formerly "8x8 Virtual Office")
- **Bundle IDs:**
  - `com.electron.8x8---virtual-office` -- 8x8 Work desktop app -- source: FleetDM software catalog, iboostup -- **high** -- **ADDED TO CODE**
- **Meeting-link formats:**
  - `https://8x8.vc/acmejets/mel.black` (personal space) -- high
  - `https://8x8.vc/vpaas-magic-cookie-<guid>/Room` (JaaS/developer) -- high
  - **Regex (shared with Jitsi):** `https?://(?:[a-z]+\.)?8x8\.vc/[^\s/?#]+/[^\s/?#]+`
- **ADDED TO CODE:** Bundle ID, display name. Link regex shared with Jitsi (labeled "8x8 / Jitsi").

### 13. Zoho Meeting

- **Native macOS:** Yes (framework unconfirmed)
- **Bundle IDs:**
  - `com.zoho.meeting` -- extrapolated from iOS (iTunes Lookup API, id1277602149) and Zoho `com.zoho.*` convention -- **medium** -- **ADDED TO CODE** with `// medium-confidence` comment
- **Meeting-link formats:**
  - `https://meeting.zoho.com/join?key=123456789` (10-digit key) -- high
  - Regional variants: `.eu`, `.in`, `.com.au`, `.jp`
  - **Regex:** `https?://(?:meeting|meet)\.zoho\.(?:com|eu|in|com\.au|jp)/[^\s]+` -- covers `meeting.zoho.*` and `meet.zoho.*`, any path
- **ADDED TO CODE:** Bundle ID (with medium-confidence comment), display name, and link regex.

### 14. Dialpad

- **Native macOS:** Yes (Electron)
- **Bundle IDs:**
  - `com.electron.dialpad` -- main Dialpad app (includes Meetings) -- source: Homebrew cask `dialpad.rb`, MacUpdater -- **high** -- **ADDED TO CODE**
  - Standalone "Dialpad Meetings" app bundle ID -- **UNVERIFIED** -- doc only
- **Meeting-link formats:**
  - `https://meetings.dialpad.com/janedoe` (personal room) -- high
  - `https://meetings.dialpad.com/room/budgetreview` (team room) -- high
  - `https://www.uberconference.com/strategicearth` (legacy redirect) -- high
  - `https://dialpad.com/meetings/janedoe` (alt path on main domain) -- medium
  - **Regex:** `https?://meetings\.dialpad\.com/(?:room/)?[^\s]+`, `https?://(?:www\.)?uberconference\.com/[^\s]+`, and `https?://(?:www\.)?dialpad\.com/meetings/[^\s]+`
- **ADDED TO CODE:** Bundle ID, display name, and link regexes.

### 15. Vonage

- **Native macOS:** Yes (Electron, likely)
- **Bundle IDs:**
  - `com.vonage.vbc` -- Vonage Business Communications -- source: MacUpdater tracking DB -- **high (single-source) / medium overall** -- **ADDED TO CODE**
- **Meeting-link formats:**
  - `https://meetings.vonage.com/982515622` (9-digit meeting code) -- high
  - `https://meetings.vonage.com/?room_token=...` (host URL with token) -- high
  - `https://freeconferencing.vonage.com/<room>` (free conferencing product) -- medium
  - **Regex:** `https?://(?:meetings|freeconferencing)\.vonage\.com/[^\s]+` -- covers both subdomains
- **ADDED TO CODE:** Bundle ID, display name, and link regex.

### 16. BigBlueButton

- **Native macOS:** Browser-only (HTML5, "no app to install")
- **Bundle IDs:** N/A -- browser-only.
- **Meeting-link formats:** **Self-hosted with no fixed host domain.** Detection would require path-based matching (e.g. `/bigbluebutton/api/join?...`, `/rooms/<slug>/join`), which is false-positive-prone.
  - `https://<server>/bigbluebutton/api/join?...` (API join -- distinctive but host varies) -- high
  - `https://<server>/b/<slug>` (Greenlight v2 room) -- high
  - `https://<server>/rooms/<slug>/join` (Greenlight v3 room) -- high
- **DOC ONLY.** No fixed host; path-only patterns like `/rooms/<id>` are too generic. Not added to code.

### 17. ClickMeeting

- **Native macOS:** Electron (probable; not bundle-inspected)
- **Bundle IDs:** **UNVERIFIED** -- no Homebrew cask, no MDM source. Plausible `com.clickmeeting.desktop` / `com.electron.clickmeeting-desktop` but unconfirmed. -- doc only
- **Meeting-link formats:**
  - `https://<account>.clickmeeting.com/<room>` -- high
  - `https://<account>.clickwebinar.com/<room>` -- high
  - **Regex:** `https?://[A-Za-z0-9-]+\.click(?:meeting|webinar)\.com/[^\s]+` -- `[^\s]+` tail (recall-first; subdomain anchoring provides sufficient precision)
- **ADDED TO CODE:** Link regex only (bundle ID unverified). Webinar-first platform.

### 18. Livestorm

- **Native macOS:** Browser-only (WebRTC, no downloads)
- **Bundle IDs:** N/A -- browser-only.
- **Meeting-link formats:**
  - `https://app.livestorm.co/<org>/<event>` (registration page) -- high
  - `https://app.livestorm.co/p/<uuid>/live` (live room) -- high
- **DOC ONLY.** Webinar/virtual-events platform (mostly one-to-many); borderline for a meetings recorder. Not added to code.

---

## Dropped / Discontinued Platforms

These platforms were in the initial top-18 candidate list but are discontinued or shut down
as of 2026. Documented for completeness; **not added to code**.

| Platform | Status | Notes |
|----------|--------|-------|
| **Skype** (consumer) | Retired May 2025, migrated to Teams | `com.skype.skype` bundle ID is dead |
| **BlueJeans** | Shut down Mar 2024 | Verizon discontinued the service |
| **Around** | Shut down Mar 2025, assets to Miro | No macOS app remains |
| **Lifesize** | Bankrupt 2023 | Assets acquired by Enghouse |
| **Amazon Chime** | Full shutdown Feb 20 2026 | Chime SDK remains for developers, but the user-facing product is gone |

---

## Summary of code changes

### Bundle IDs applied to code (9):
- `Cisco-Systems.Spark` (Webex unified) -- high
- `com.logmein.GoToMeeting` -- high
- `com.logmein.goto` (GoTo unified) -- medium
- `com.ringcentral.glip` -- high
- `org.jitsi.jitsi-meet` -- high
- `com.electron.8x8---virtual-office` -- high
- `com.electron.dialpad` -- high
- `com.vonage.vbc` -- medium
- `com.zoho.meeting` -- medium (with comment)

### Link regexes applied or changed:

**Detection philosophy: recall over precision.** A false positive (flagging a non-meeting URL) only adds a low-cost UI hint; a false negative (missing a real meeting link) silently degrades the experience. Regexes therefore use `[^\s]+` tails and minimal path constraints, anchored by distinctive hostnames. The negative-lookahead on Whereby (`/information`, `/blog`, `/pricing`, etc.) is the one exception where precision is worth the complexity.

- **Zoom:** broadened to `/j/`, `/my/`, `/w/`, `/s/`, `/wc/` with `[^\s]+` tails + `zoomgov.com`
- **Google Meet:** `[a-z]{3}-[a-z]{4}-[a-z]{3}` code format + `/lookup/<nickname>`
- **Microsoft Teams:** covers `/l/meetup-join/`, `/meet/`, `teams.live.com`, and gov/dod domains
- **Cisco Webex:** recall-first -- any `*.webex.com/` path
- **Additional platforms:** GoTo Meeting, RingCentral, Jitsi Meet, 8x8 / Jitsi (`8x8.vc`), Zoho Meeting, Dialpad, Vonage, FaceTime, Whereby, ClickMeeting

### Not applied to code (and why):
- **Bundle IDs:** ClickMeeting (unverified), standalone Dialpad Meetings (unverified), Zoom helpers (audio role unverified), Webex helpers (audio role unverified), classic Teams `com.microsoft.teams` (EOL), Discord PTB/Canary (niche)
- **Link regexes:** BigBlueButton (no fixed host -- false-positive-prone), Livestorm (webinar platform, not meetings), Discord (no meeting URLs)
- **helperToParent:** No additions (helpers' audio roles are unverified)
