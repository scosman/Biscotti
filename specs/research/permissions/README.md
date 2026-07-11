# Permissions Matrix Research

## Summary

Biscotti requires three distinct system permissions: **microphone** (for the user's voice), **system audio capture** (for meeting participants' audio), and **calendar full access** (for upcoming-event integration). The recommended approach uses Core Audio process taps for system audio rather than ScreenCaptureKit, because Core Audio taps trigger a narrowly scoped "System Audio Recording" TCC prompt instead of the alarming and friction-heavy "Screen & System Audio Recording" permission that ScreenCaptureKit requires. The app should ship as a **non-sandboxed, hardened-runtime, Developer ID-notarized** application, requesting permissions contextually (calendar at launch since it powers the home screen; microphone + system audio together when the user first hits "Record").

---

## Key Questions & Findings

### 1. What permissions does each capability require, and what is the user-facing UX?

#### Permissions Matrix

| Capability | Info.plist Usage-Description Key(s) | Entitlement(s) (Hardened Runtime, non-sandbox) | Entitlement(s) (App Sandbox) | TCC Service / Settings Pane | What Triggers the Prompt | Menu-Bar Indicator |
|---|---|---|---|---|---|---|
| **Microphone** (user's voice via AVCaptureDevice) | `NSMicrophoneUsageDescription` | `com.apple.security.device.audio-input` = `true` | `com.apple.security.device.microphone` = `true` | `kTCCServiceMicrophone` / Privacy & Security > Microphone | First call to `AVCaptureDevice.requestAccess(for: .audio)`, or first attempt to start an `AVCaptureSession` with an audio input | Orange dot |
| **System audio capture** (Core Audio process taps) | `NSAudioCaptureUsageDescription` | `com.apple.security.device.audio-input` = `true` (same entitlement as mic) | `com.apple.security.device.audio-input` = `true` | `kTCCServiceAudioCapture` / Privacy & Security > Screen & System Audio Recording (the pane offers per-app toggles that can grant screen-only, audio-only, or both) | First call to `AudioHardwareCreateProcessTap` (or the private `TCCAccessRequest("kTCCServiceAudioCapture", ...)` if pre-requesting) | Purple dot |
| **System audio capture** (ScreenCaptureKit -- alternative) | None officially documented (see note below) | None required (purely TCC-gated) | None required (purely TCC-gated) | `kTCCServiceScreenCapture` / Privacy & Security > Screen & System Audio Recording | First call to `SCShareableContent.current`, `SCStream.startCapture()`, or `CGRequestScreenCaptureAccess()` | Purple dot |
| **Calendar full access** (see also R2 -- EventKit research) | `NSCalendarsFullAccessUsageDescription` | **`com.apple.security.personal-information.calendars` = `true`** (see correction below) | `com.apple.security.personal-information.calendars` = `true` | `kTCCServiceCalendar` / Privacy & Security > Calendars | First call to `EKEventStore().requestFullAccessToEvents()` | None |

> **⚠️ Correction (validated on-hardware, macOS 15).** An earlier version of this doc claimed calendar access needs **no** entitlement for a non-sandboxed app ("TCC-only"). **That is wrong under hardened runtime.** With hardened runtime enabled (which we ship with — see R5/R6), `calaccessd` denies calendar access at runtime with: `Prompting policy for hardened runtime; service: kTCCServiceCalendar requires entitlement com.apple.security.personal-information.calendars but it is missing`. The `com.apple.security.personal-information.calendars` entitlement is **both** a sandbox entitlement **and** a hardened-runtime resource-access entitlement (Xcode surfaces it under the "Resource Access" list of *both* the App Sandbox and Hardened Runtime capabilities). Hardened runtime enforces it independently of the sandbox. **`Biscotti.entitlements` must include it.** The same is expected to apply to other `com.apple.security.personal-information.*` TCC resources (contacts, photos) if we ever use them under hardened runtime.

**Note on `NSScreenCaptureUsageDescription`:** There is no officially documented Apple Info.plist key for ScreenCaptureKit screen capture on macOS. The key `NSScreenCaptureUsageDescription` appears in some community references and in visionOS/ReplayKit contexts, but Apple's macOS developer documentation does not list it as a recognized macOS Info.plist key. ScreenCaptureKit access on macOS is purely TCC-gated, triggered by calling ScreenCaptureKit APIs or `CGRequestScreenCaptureAccess()`. See [CGRequestScreenCaptureAccess -- Apple Developer Documentation](https://developer.apple.com/documentation/coregraphics/cgrequestscreencaptureaccess()).

Sources:
- [NSMicrophoneUsageDescription -- Apple Developer Documentation](https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSMicrophoneUsageDescription)
- [NSAudioCaptureUsageDescription -- Apple Developer Documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription)
- [Capturing system audio with Core Audio taps -- Apple Developer Documentation](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
- [Requesting authorization to capture and save media -- Apple Developer Documentation](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media)
- [Calendars entitlement -- Apple Developer Documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.calendars)
- [requestFullAccessToEvents -- Apple Developer Documentation](https://developer.apple.com/documentation/eventkit/ekeventstore/4162272-requestfullaccesstoevents)

---

### 2. How to check status / pre-check each permission

| Permission | Pre-Check API | Notes |
|---|---|---|
| **Microphone** | `AVCaptureDevice.authorizationStatus(for: .audio)` returns `.authorized`, `.denied`, `.restricted`, or `.notDetermined`. | Fully public API. Can call `requestAccess(for: .audio)` to trigger the prompt at an arbitrary time before actually recording. |
| **System audio (Core Audio taps)** | **No public API.** The TCC service `kTCCServiceAudioCapture` has no public status-check equivalent. | AudioCap (insidegui) implements a probe using the *private* TCC framework: dynamically load `TCC.framework`, call `TCCAccessPreflight("kTCCServiceAudioCapture")` which returns 0=authorized, 1=denied, 2=not-determined. Call `TCCAccessRequest("kTCCServiceAudioCapture", ...)` to trigger the prompt. **Warning:** private API usage disqualifies App Store distribution and risks breakage across macOS versions. For non-App-Store distribution this is pragmatically useful but should be guarded behind a build flag. Without the private API, the permission is simply triggered on first `AudioHardwareCreateProcessTap` call -- if denied, you get silence (zero-filled buffers) with no explicit error. |
| **System audio (ScreenCaptureKit)** | `CGPreflightScreenCaptureAccess()` returns a Boolean indicating current status. `CGRequestScreenCaptureAccess()` triggers the prompt if not yet determined. `SCShareableContent.current` also implicitly checks (throws or returns empty if not granted). | On macOS 15, after granting permission the app must be relaunched for it to take effect. Known bug: once an entry is removed from System Settings, `CGRequestScreenCaptureAccess()` may not re-prompt until reboot. |
| **Calendar** | `EKEventStore.authorizationStatus(for: .event)` returns `.fullAccess`, `.writeOnly`, `.denied`, `.notDetermined`, etc. | Fully public API. Can call `requestFullAccessToEvents()` to trigger the prompt. |

Sources:
- [AudioCap -- AudioRecordingPermission.swift](https://github.com/insidegui/AudioCap/blob/main/AudioCap/ProcessTap/AudioRecordingPermission.swift)
- [Requesting Authorization for Media Capture on macOS -- Apple Developer Documentation](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos)
- [Accessing the event store -- Apple Developer Documentation](https://developer.apple.com/documentation/eventkit/accessing-the-event-store)

---

### 3. Handling denial & re-request

On macOS, TCC permission prompts typically only appear **once**. If the user denies, subsequent calls to the request API are no-ops (they immediately return "denied" without re-prompting). The user must manually re-enable the permission in **System Settings > Privacy & Security > [category]**.

**Strategy per permission:**

| Permission | On Denial |
|---|---|
| **Microphone** | Show an in-app banner/sheet: "Microphone access is required to record your voice. Open System Settings to enable it." Provide a button that opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` via `NSWorkspace.shared.open(url)`. |
| **System audio (Core Audio taps)** | If using the private TCC probe: detect denial and show a similar banner pointing to the "Screen & System Audio Recording" pane. Without the probe: detect silence (zero-filled buffers for N seconds after starting the tap) and show a warning: "System audio capture was denied. Please enable it in System Settings." Open `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`. |
| **Calendar** | Show a banner: "Calendar access lets Biscotti show your upcoming meetings. Open System Settings to enable it." Link to the Calendars pane. The app remains fully functional for manual recording without calendar access, so this is not a blocking denial. Also handle the `.writeOnly` status (see Risk #4 and R2 -- EventKit research for details on the Sonoma downgrade). |

**Important:** `tccutil reset <service> <bundle-id>` can clear a permission grant/denial for testing, e.g. `tccutil reset Microphone net.scosman.biscotti`. Useful during development.

---

### 4. Core Audio taps vs. ScreenCaptureKit: detailed comparison for system audio

This is the key architectural choice. Both APIs can capture system/meeting audio. The comparison:

| Dimension | Core Audio Process Taps | ScreenCaptureKit |
|---|---|---|
| **Availability** | macOS 14.2+ (introduced 14.2, formalized/stabilized 14.4; AudioCap targets 14.4+). Our floor is 15, so academic. | macOS 12.3+ (audio from 13.0+, mic from 15.0+) |
| **TCC category** | `kTCCServiceAudioCapture` ("System Audio Recording") | `kTCCServiceScreenCapture` ("Screen & System Audio Recording") |
| **User-facing permission prompt** | Narrowly scoped: "allow [App] to record audio from other applications?" | Broad: "allow [App] to record your screen and system audio?" Even for audio-only capture, the user sees a screen-recording prompt. |
| **Monthly re-authorization (Sequoia 15+)** | **No.** The "Audio Capture" TCC category is not subject to the periodic re-auth prompt. | **Yes, with caveats.** Sequoia 15.0 shipped with monthly re-auth (reduced from weekly in beta 6). macOS 15.1 relaxed this further: regularly-used apps that the user has already approved see fewer prompts ([9to5Mac](https://9to5mac.com/2024/10/07/macos-sequoia-screen-recording-popups/), [MacRumors](https://www.macrumors.com/2024/10/07/apple-screen-recording-popup-update/)). Enterprise MDM can suppress prompts entirely via the `forceBypassScreenCaptureAlert` key (`com.apple.applicationaccess` payload). The VNC-only Persistent Content Capture entitlement also exempts apps. But for a consumer app like Biscotti, periodic re-auth remains a real friction risk. |
| **App restart after granting** | **No.** Permission takes effect immediately. | **Yes.** The app must be fully quit and relaunched after the user toggles the permission in System Settings. |
| **Menu-bar indicator** | Purple dot (system audio recording). | Purple dot (same indicator). Some community reports suggest Control Center may also display a screen-recording preview, but this is not verified for audio-only ScreenCaptureKit sessions. |
| **Process targeting** | Excellent. `CATapDescription` can target specific process IDs, a list of processes, or all processes (with exclusions). Can isolate e.g. Zoom.app's audio. | Good. `SCContentFilter` can target specific apps/windows, but it is designed around screen content; audio is a sidecar. |
| **Independent mic + system streams** | Yes. Mic is a separate `AVCaptureDevice` input; system audio comes from the tap. Two fully independent streams by design. | Yes (macOS 15+). `SCStreamConfiguration` has `capturesAudio` (system) and `captureMicrophone` (mic input) as separate booleans. But both come through the same `SCStream` pipeline. |
| **Documentation & maturity** | Poorly documented; the community relies on AudioCap/AudioTee reference code. Known issues: zero-filled buffers on sample-rate renegotiation, level attenuation with multi-output devices. | Better documented (WWDC sessions, sample code). More mature, but the permission UX is worse for audio-only. |
| **Public permission-check API** | **None.** Must use private TCC framework or detect silence. | **None** (direct check), but `SCShareableContent.current` implicitly reveals status. |
| **Apple's recommendation for audio-only** | Apple recommends Core Audio taps for audio-only capture (confirmed in Developer Forums). | Apple designed ScreenCaptureKit primarily for screen + audio; audio-only is a secondary use case. |
| **Notarization impact** | Requires `com.apple.security.device.audio-input` entitlement + hardened runtime. No issues with notarization. | Purely TCC-gated; no entitlement needed. No notarization issues. |

**Verdict:** Core Audio process taps are strongly preferred for Biscotti. The permission scope is accurate (audio-only, not screen), there is no monthly re-auth prompt, no app restart is needed, and Apple explicitly recommends this API for audio-only capture. The downside is limited documentation and some known edge-case bugs, but AudioCap and AudioTee provide solid reference implementations.

Sources:
- [How to access system audio on macOS -- Recall.ai blog](https://www.recall.ai/blog/how-to-access-to-system-audio)
- [AudioTee: capture system audio output on macOS -- Strongly Typed](https://stronglytyped.uk/articles/audiotee-capture-system-audio-output-macos)
- [CoreAudio Taps for Dummies -- maven.de](https://www.maven.de/2025/04/coreaudio-taps-for-dummies/)
- [Sequoia Screen Recording Prompts and the Persistent Content Capture Entitlement -- Michael Tsai](https://mjtsai.com/blog/2024/08/08/sequoia-screen-recording-prompts-and-the-persistent-content-capture-entitlement/)
- [Control access to screen and system audio recording on Mac -- Apple Support](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac)
- [macOS Sequoia 15.1 has fewer screen recording privacy prompts -- iDownloadBlog](https://www.idownloadblog.com/2024/10/09/macos-sequoia-15-1-macos-screen-recording-prompts-frequency-reduced/)
- [Apple Tweaks Screen Recording App Permissions -- MacRumors](https://www.macrumors.com/2024/10/07/apple-screen-recording-popup-update/)

---

### 5. Sandboxing vs. non-sandbox implications

| Aspect | Non-Sandboxed (Hardened Runtime) | App Sandbox |
|---|---|---|
| **Distribution** | Developer ID + notarization (outside App Store). Our target. | Required for Mac App Store. |
| **Microphone entitlement** | `com.apple.security.device.audio-input` | `com.apple.security.device.microphone` (sandbox version) **plus** `com.apple.security.device.audio-input` (hardened runtime version) if both sandbox + hardened runtime are active |
| **System audio (Core Audio taps)** | `com.apple.security.device.audio-input` + `NSAudioCaptureUsageDescription` | Same, but Core Audio taps may have additional friction under sandbox (file-system restrictions on aggregate device creation). Not well-tested in sandbox. |
| **System audio (ScreenCaptureKit)** | No entitlement needed (TCC-only) | No entitlement needed (TCC-only) |
| **Calendar** | **`com.apple.security.personal-information.calendars` + `NSCalendarsFullAccessUsageDescription`** — hardened runtime requires the entitlement (see ⚠️ correction under R1). It is *not* TCC-only. | `com.apple.security.personal-information.calendars` + `NSCalendarsFullAccessUsageDescription` |
| **File system** | Full access. Can write audio files anywhere the user allows. | Restricted to app container + user-selected files via NSOpenPanel. Audio file storage must use the app's container or a user-granted directory. |
| **Notarization** | Requires hardened runtime (`--options runtime` on codesign). Can still use entitlements to opt out of specific hardened-runtime restrictions (e.g., `com.apple.security.cs.disable-library-validation` if loading unsigned dylibs). | Same codesign requirements, plus App Store review. |

**For Biscotti:** Non-sandboxed + hardened runtime + Developer ID notarization is the right choice. We are distributing outside the App Store, Core Audio taps are better tested without sandbox, and we avoid the sandbox's file-system restrictions which would complicate audio file storage.

Sources:
- [Audio Input Entitlement -- Apple Developer Documentation](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.device.audio-input)
- [Hardened Runtime -- Apple Developer Documentation](https://developer.apple.com/documentation/security/hardened_runtime_entitlements)
- [What are app entitlements, and what do they do? -- Eclectic Light](https://eclecticlight.co/2025/03/24/what-are-app-entitlements-and-what-do-they-do/)
- [Configuring the macOS App Sandbox -- Apple Developer Documentation](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)

---

### 6. Notarization & Gatekeeper implications

**Requirements for the shipping app:**

1. **Developer ID certificate.** Sign with `Developer ID Application: <Team Name>` certificate.
2. **Hardened runtime.** Codesign with `--options runtime --timestamp`. This is mandatory for notarization.
3. **Entitlements plist.** Must include:
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
   <plist version="1.0">
   <dict>
       <key>com.apple.security.device.audio-input</key>
       <true/>
       <key>com.apple.security.personal-information.calendars</key>
       <true/>
   </dict>
   </plist>
   ```
   `com.apple.security.device.audio-input` covers both microphone and system audio capture under hardened runtime. `com.apple.security.personal-information.calendars` is **required** for EventKit calendar access under hardened runtime (validated on-hardware — see ⚠️ correction under R1; the earlier "calendar needs no entitlement" claim was wrong).
4. **Info.plist usage descriptions.** Must include all three:
   ```xml
   <key>NSMicrophoneUsageDescription</key>
   <string>Biscotti needs microphone access to record your voice during meetings.</string>
   <key>NSAudioCaptureUsageDescription</key>
   <string>Biscotti needs system audio access to record other participants in your meetings.</string>
   <key>NSCalendarsFullAccessUsageDescription</key>
   <string>Biscotti reads your calendar to show upcoming meetings and enrich recordings with event details.</string>
   ```
5. **Submit for notarization** via `xcrun notarytool submit` (or Xcode's archive/distribute flow).
6. **Staple the ticket** to the app bundle: `xcrun stapler staple Biscotti.app`.

**Gatekeeper behavior:** On first launch, Gatekeeper checks the notarization ticket. If valid, the app opens normally. If the app is ad-hoc signed (experiments), macOS Sequoia 15+ blocks it by default; users must go to System Settings > Privacy & Security > "Open Anyway" (Control-click to open was removed in Sequoia).

**If ScreenCaptureKit were chosen instead:** No entitlement changes (ScreenCaptureKit is TCC-only), but the app would be subject to Sequoia's periodic re-authorization prompts for Screen & System Audio Recording (monthly in 15.0, relaxed in 15.1 for frequently-used apps but still present). This is a significant UX downside for a "set it and forget it" recording app.

Sources:
- [Notarizing macOS software before distribution -- Apple Developer Documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Notarization: the hardened runtime -- Eclectic Light](https://eclecticlight.co/2021/01/07/notarization-the-hardened-runtime/)
- [Notarisation: privacy controls -- Eclectic Light](https://eclecticlight.co/2021/01/08/notarisation-privacy-controls/)
- [macOS Apps: From Sandboxing to Notarization -- Xojo Blog](https://blog.xojo.com/2024/08/22/macos-apps-from-sandboxing-to-notarization-the-basics/)

---

### 7. Permission request ordering & strategy

**Principles:**
- Request permissions **contextually** (just-in-time), not all at once on first launch.
- Explain the "why" before triggering the system prompt (a pre-permission screen in our own UI).
- Critical permissions first; optional ones deferred.

**Recommended flow for Biscotti:**

| Step | When | Permission | Rationale |
|---|---|---|---|
| **1** | **First launch / onboarding** | Calendar (full access) | Calendar powers the home screen (upcoming meetings) and the tray icon. Without it, the app's primary value prop is invisible. Users expect a meeting app to ask for calendar access. Show a brief onboarding screen: "Biscotti shows your upcoming meetings and enriches recordings with event details. We need calendar access to do this." Then call `requestFullAccessToEvents()`. |
| **2** | **User taps "Start Recording" for the first time** | Microphone + System Audio (back-to-back) | These are both needed for recording and logically grouped. Show a pre-permission screen: "To record your meeting, Biscotti needs access to your microphone (your voice) and system audio (other participants). You'll see two permission prompts." Then trigger microphone first (`AVCaptureDevice.requestAccess(for: .audio)`), and system audio second (`AudioHardwareCreateProcessTap` or the TCC probe if using private API). Two prompts in sequence is acceptable because the user just explicitly asked to record. |
| **3** | **Never at cold launch** | Avoid requesting mic + audio at app startup. | Users who haven't tried to record yet don't need these permissions. Asking too early causes confusion and increases denial rates. |

**Handling the "second chance":** If a user denied a permission and later tries the feature again, show an in-app sheet explaining what's needed and a button to open the relevant System Settings pane. Do not attempt to re-trigger the system prompt (it won't show again).

Sources:
- [3 Design Considerations for Effective Mobile-App Permission Requests -- NNG](https://www.nngroup.com/articles/permission-requests/)
- [How to improve your permissions UX -- Adam Lynch](https://adamlynch.com/improve-permissions-ux/)

---

## Recommendation

### Chosen permission set for the shipping Biscotti app

**Distribution model:** Non-sandboxed, hardened runtime, Developer ID notarized (outside App Store).

**Entitlements file (`Biscotti.entitlements`):**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.personal-information.calendars</key>
    <true/>
</dict>
</plist>
```

> **⚠️ `com.apple.security.personal-information.calendars` is mandatory under hardened runtime** — see the correction under R1. The originally-recommended entitlements file omitted it and calendar access failed at runtime (`kTCCServiceCalendar requires entitlement ...`).

**Info.plist keys:**
```xml
<key>NSMicrophoneUsageDescription</key>
<string>Biscotti needs microphone access to record your voice during meetings.</string>

<key>NSAudioCaptureUsageDescription</key>
<string>Biscotti needs system audio access to record other meeting participants.</string>

<key>NSCalendarsFullAccessUsageDescription</key>
<string>Biscotti reads your calendar to show upcoming meetings and enrich recordings with event details.</string>
```

**Bundle identifier:** `net.scosman.biscotti` (locked production ID; stable across builds so TCC grants persist).

**Summary of what triggers each prompt:**

| # | Permission | Trigger | TCC Category |
|---|---|---|---|
| 1 | Calendar full access | `EKEventStore().requestFullAccessToEvents()` at onboarding | `kTCCServiceCalendar` |
| 2 | Microphone | `AVCaptureDevice.requestAccess(for: .audio)` on first record | `kTCCServiceMicrophone` |
| 3 | System audio | `AudioHardwareCreateProcessTap(...)` on first record (or private TCC probe) | `kTCCServiceAudioCapture` |

**If ScreenCaptureKit were chosen instead of Core Audio taps:**
- Remove `NSAudioCaptureUsageDescription`. There is no officially documented macOS Info.plist key for ScreenCaptureKit; the permission is triggered by calling `CGRequestScreenCaptureAccess()` or ScreenCaptureKit APIs directly.
- The `com.apple.security.device.audio-input` entitlement is still needed for microphone (unchanged).
- The TCC category changes from `kTCCServiceAudioCapture` to `kTCCServiceScreenCapture`.
- **Downsides:** periodic re-auth prompts on Sequoia 15+ (reduced in 15.1 for frequently-used apps, but still present), app-restart required after granting, misleading "screen recording" framing for an audio-only feature. Strongly discouraged.

---

## Risks & Gotchas

1. **No public API for system-audio permission status.** Unlike microphone (`AVCaptureDevice.authorizationStatus`) and calendar (`EKEventStore.authorizationStatus`), there is no public API to check whether `kTCCServiceAudioCapture` has been granted. The private TCC framework probe (AudioCap's approach) works today but could break in future macOS versions and is not App Store safe. The fallback is to detect silence after starting the tap.

2. **Private TCC API and notarization.** Using `TCCAccessPreflight` / `TCCAccessRequest` involves dynamically loading a private framework. This does not block notarization (notarization checks for malware, not private API usage), but it could break without warning in a macOS update. Guard behind a build flag and have a graceful fallback.

3. **Core Audio tap edge cases.** Known issues include zero-filled buffers during sample-rate renegotiation (e.g., Bluetooth device connects/disconnects) and level attenuation scaling with the number of stereo output pairs. These are recording-quality issues, not permission issues, but they affect the user experience. Mitigations are covered in R1 (Audio research).

4. **Calendar permission downgrade on macOS Sonoma+.** Apps previously granted calendar access are downgraded to write-only when the user upgrades to macOS Sonoma / iOS 17 ([Discover Calendar and EventKit -- WWDC23](https://developer.apple.com/videos/play/wwdc2023/10052/)). Calling `requestFullAccessToEvents()` does **not** automatically re-prompt the user -- the consent alert only appears the first time the app asks, and subsequent calls return the current (downgraded) status without showing a dialog. The app must detect `.writeOnly` or `.denied` from `EKEventStore.authorizationStatus(for: .event)` and deep-link the user to System Settings > Privacy & Security > Calendars so they can manually re-enable Full Access. See also R2 (EventKit research) for the full calendar permission handling strategy.

5. **Ad-hoc signed experiments won't persist TCC grants reliably.** During development with ad-hoc signing, TCC permission grants can be lost across rebuilds if the bundle ID or code signature changes. Use a stable `PRODUCT_BUNDLE_IDENTIFIER` (e.g., `net.scosman.biscotti.experiments.audiolab`) and keep `CODE_SIGN_IDENTITY = "-"` consistent.

6. **macOS Tahoe (26) note.** Plain (non-bundled) executables no longer appear in the Screen & System Audio Recording pane in System Settings. This does not affect Biscotti (it is a bundled .app), but it could affect CLI-based experiment harnesses like ArgMaxKit's CLI.

---

## Open Questions for the Team

1. **Private TCC API: use it or not?** The AudioCap-style TCC probe (`TCCAccessPreflight("kTCCServiceAudioCapture")`) lets us check system-audio permission status and show a pre-permission screen. But it uses private API. Options: (a) use it with a build flag and accept the maintenance risk, (b) skip it and detect silence as a fallback, (c) file a Feedback Assistant radar asking Apple for a public `kTCCServiceAudioCapture` status API. Recommend (a) + (c).

2. **App Store distribution ever?** If we ever want to ship on the Mac App Store, we need App Sandbox. Core Audio taps under sandbox are not well-tested in the community. This would need dedicated investigation. For now, the plan is Developer ID distribution only.

3. **Persistent bundle identity strategy.** For TCC grants to survive across app updates, the bundle ID and team ID must remain constant. The production bundle ID is locked: `net.scosman.biscotti`. The Apple Developer team ID should also be locked early.

4. **Custom usage-description strings.** The strings above are drafts. Product/design should review the wording for each `NS*UsageDescription` value, as they appear verbatim in the system permission dialog. Clear, honest, specific wording significantly improves grant rates.

5. **Enterprise/MDM distribution.** If Biscotti is ever distributed to managed fleets, PPPC (Privacy Preferences Policy Control) profiles can pre-grant all three permissions silently. Worth noting for future B2B sales, but not needed for V1.
