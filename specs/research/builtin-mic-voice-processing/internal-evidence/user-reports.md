# Every user report of VPIO side effects (issues #66, #91, PRs #115, #118, #129)

Collected 2026-10-28 from:
- [#66](https://github.com/scosman/Biscotti/issues/66) and all 9 of its comments
- [#91](https://github.com/scosman/Biscotti/issues/91) and all 9 of its comments (closed 2026-10-28 as a duplicate of #66)
- the conversations on PRs [#115](https://github.com/scosman/Biscotti/pull/115), [#118](https://github.com/scosman/Biscotti/pull/118) and [#129](https://github.com/scosman/Biscotti/pull/129)
- related issues [#116](https://github.com/scosman/Biscotti/issues/116), [#124](https://github.com/scosman/Biscotti/issues/124), [#88](https://github.com/scosman/Biscotti/issues/88) and [#64](https://github.com/scosman/Biscotti/issues/64)

"Unspecified" means the reporter did not say. It never means a guess.

## The table

| # | Reporter (link) | Mic hardware | Output | Meeting app / browser | macOS | Biscotti | Symptom (reporter's words where load-bearing) |
|---|---|---|---|---|---|---|---|
| 1 | JulianUll, [#66 body](https://github.com/scosman/Biscotti/issues/66) (2026-08-27) | Unspecified | Unspecified | Microsoft Teams (desktop or web unspecified; reporter suspects "Teams' own WebRTC audio pipeline") | Unspecified | pre-1.0 (unspecified) | "the overall audio character shifts, and Teams' mic level indicator goes flat/idle"; "other participants stop hearing the user". Biscotti's own recording is fine. Mic Mode was "Standard" for both apps. Reproduced with no other audio apps open. |
| 2 | Hederanomics, [#66](https://github.com/scosman/Biscotti/issues/66#issuecomment-5522672608) | Unspecified | – | Unspecified | Unspecified | – | "noticed the same problem" |
| 3 | MOccam, [#66](https://github.com/scosman/Biscotti/issues/66#issuecomment-5523069181) | **Built-in Mac mic** (fails); **headset mic** (works; wired or Bluetooth not stated) | headset | Teams | Unspecified | – | Built-in mic "blocked in the Teams application". **Workaround:** setting a headset mic as input for both Teams and Biscotti lets them speak in Teams and record in Biscotti. |
| 4 | alserevs, [#66](https://github.com/scosman/Biscotti/issues/66#issuecomment-5583791101) | **Audient iD24 USB interface** (12 in / 16 out, 48 kHz; default input *and* output). Mic on input 2. **Not built-in.** | same iD24 | Chrome (WebRTC) + "an Electron chat app" | **macOS 15** | – | "Same symptoms… Confirmed on Chrome/WebRTC too, so it isn't Teams-specific." Logs show VPIO enabling tap streams on **every** device and `Disabling HAL Voice Isolation support due to app's use of existing chat flavors`. **Workaround:** a different Mic Mode per app (Voice Isolation for Chrome, Standard for Biscotti) restores the other app's mic. Separate bug: `mic.aac` is digitally silent on every recording because channel 0 = unconnected input 1. Rogue Amoeba SoundSource + Loopback (ACE/ARK) installed. |
| 5 | unknowndomain, [#66](https://github.com/scosman/Biscotti/issues/66#issuecomment-5751264297) | Unspecified | – | Unspecified ("most applications") | Unspecified | – | "Same issue" |
| 6 | hendrik77, [#66](https://github.com/scosman/Biscotti/issues/66#issuecomment-5891252354) | Unspecified | – | MS Teams | "since upgrade to MacOs 26.7" | – | Same as #66. Also "automatic start and stop doesn't work anymore". |
| 7 | timbowicz, [#66](https://github.com/scosman/Biscotti/issues/66#issuecomment-6361278695) | **Built-in MacBook Pro mic** ("no external interface") | Unspecified | Teams in Chrome; also reproduced on webcammictest.com in Chrome | **27.0.1** | 1.0.0 | **Degraded, not muted:** "sounded very hollow and hard to understand"; "clearly hollow/tinny" when Biscotti is recording. Asks for a no-VPIO option or device pick (#116). |
| 8 | DLR-Group, [#91 body](https://github.com/scosman/Biscotti/issues/91) (2026-09-25) | Unspecified ("my physical mic gain and system input levels are maxed out") | – | Zoom or Microsoft Teams | "Tahoe" (26.x) | – | "input volume drops significantly. Participants on the call can suddenly barely hear me or can't hear me at all" |
| 9 | ziftech, [#91](https://github.com/scosman/Biscotti/issues/91#issuecomment-5885130696) | Unspecified | – | Unspecified | Tahoe **26.7** | – | "Can confirm same issue" |
| 10 | mmiller8878, [#91](https://github.com/scosman/Biscotti/issues/91#issuecomment-6126175708) | Unspecified | – | Unspecified | Tahoe **26.6.2** | – | "same issue" |
| 11 | wenjia-knight, [#91](https://github.com/scosman/Biscotti/issues/91#issuecomment-6164908021) | Unspecified (MacBook Pro M5) | – | Unspecified | Tahoe **26.6.2** | – | "same issue" |
| 12 | pookee, [#91](https://github.com/scosman/Biscotti/issues/91#issuecomment-6291130512) | Unspecified | – | **Teams web in Chrome** | **27.0.1** | 1.0.0 | "Teams stops picking up my mic and other participants can no longer hear me" |
| 13 | dennis3484, [#91](https://github.com/scosman/Biscotti/issues/91#issuecomment-6292037442) | Unspecified | – | Unspecified | Tahoe **26.7.1** | – | "Same" |
| 14 | liamdawson, [#91](https://github.com/scosman/Biscotti/issues/91#issuecomment-6329839118) | Unspecified | Unspecified | Unspecified | Unspecified | – | **Output side:** "my *output* volume also reduces when I start recording — it seems to revert the output volume to 50%" |
| 15 | julienbordet, [#91](https://github.com/scosman/Biscotti/issues/91#issuecomment-6416437912) | Unspecified | – | Teams | "Golden Gate 27.0.1" (as written) | 1.0.0 | "Same issue" |
| 16 | gphr74, [#91](https://github.com/scosman/Biscotti/issues/91#issuecomment-6422678193) | **iMac (M4) built-in mic**, 48 kHz | **FiiO K13 R2R USB DAC, 44.1 kHz** (so Biscotti reclocks it to 48 kHz) | **Zoom desktop** | Tahoe **26.6.2** | 1.0.0 | **Full mute:** "people on the call couldn't hear me at all… could hear me again once I stopped". Also "output volume dip while recording". MacWhisper was also recording the same meeting with the mic open. Would accept "slightly noisier recordings" for a #115-style opt-out. |
| 17 | thomasvvugt, [#115 body](https://github.com/scosman/Biscotti/pull/115) + [comment](https://github.com/scosman/Biscotti/pull/115#issuecomment-6359122965) | **MacBook Pro built-in mic** + internal speakers, **both 48 kHz** | built-in speakers | **Slack Huddle** (also mentions Teams) | **26.7.1** | 1.0.0-based branch | **Full mute:** "the Huddle mic indicator goes dead while Biscotti records". "I have no issues with Bluetooth headset." With VPIO off (#115) the Huddle keeps the mic. |
| 18 | scosman (owner), [#115](https://github.com/scosman/Biscotti/pull/115#issuecomment-6343172790) + [#66](https://github.com/scosman/Biscotti/issues/66#issuecomment-6470640519) | **MacBook built-in** fails; **USB mic** and AirPods fine | Unspecified | Slack Huddle | Unspecified | dev | "Slack huddle + MacBook internal Mic hits it, Slack huddle with usb Mic does not… in my cases it's messing with levels, but never completely capturing the mic". Also: "Worse case is using the built-in microphone (AirPods, USB mic are all fine)". |
| 19 | javimoya, [#118](https://github.com/scosman/Biscotti/pull/118#issuecomment-6446547910) | **MacBook Pro M2 Pro built-in mic** | built-in speakers (echo bot "playing through the MacBook speakers") | **New Teams desktop**, "Make a test call" | **26.4** | main vs #118 | **Full mute on main:** "the Echo bot gets nothing: no playback, nothing in Teams' transcript. Stopping the recording mid-call brings the mic back." Fixed with #118, but the mic track is quieter and full of echo (see [pull-requests.md](./pull-requests.md)). |
| 20 | alxleo, [#118 body](https://github.com/scosman/Biscotti/pull/118) | Unspecified | – | Teams ("Physical Teams voice/camera acceptance is in progress. Camera causality is not established by this change.") | Unspecified | – | Cites #66/#91. No separate symptom detail. |

Related reports that are **not** the other-app-mic bug but share the VPIO code path:

| Reporter | Hardware | macOS | What happened | Link |
|---|---|---|---|---|
| brainstencil | MacBook Pro M1 Max, built-in mic and speakers + AirPods | 26.6.2 | Measured VPIO ducking of other audio: −15 dB for 0.6–1.3 s on each new VP unit, then −4 dB for the whole recording at `.min`. VP teardown crashed or deadlocked on Bluetooth loss. Each route change left 3–8 s mic gaps. | [#124](https://github.com/scosman/Biscotti/issues/124), [#129](https://github.com/scosman/Biscotti/pull/129), [#127](https://github.com/scosman/Biscotti/pull/127) |
| brainstencil (in #127) | M1 Max, built-in speakers | 26.6.2 | Evidence that VPIO's AEC works on the mic track: "the mic's echo cancellation removes the Mac's own playback, so I clapped along to beeps instead". One "slow motion" AirPods recording coincided with a failed AirPods output-rate change request. | [#127](https://github.com/scosman/Biscotti/pull/127) |
| sebastianhuus | AirPods | 26.6.2 | Wants to pick the built-in mic to avoid AirPods dropping to HFP. Feature request, not a VPIO report. | [#116](https://github.com/scosman/Biscotti/issues/116) |

## Is it only the built-in mic?

**Short answer: mostly, but not only.** The data cannot support a strict "built-in only" claim.

1. **Every report that names the failing mic names a built-in mic, with one exception.** That is 5 independent reporters plus the owner:
   - MOccam (#3)
   - timbowicz (#7)
   - gphr74 (#16, an **iMac**, not a MacBook)
   - thomasvvugt (#17)
   - javimoya (#19)
   - the owner (#18)
2. **Three sources say a non-built-in mic did *not* trigger it:** MOccam's headset (#3), thomasvvugt's Bluetooth headset (#17), and the owner's USB mic and AirPods (#18).
3. **The exception is a strong report.** alserevs (#4) reproduced the other-app breakage on an **Audient iD24 USB interface** on **macOS 15**, with Chrome/WebRTC and an Electron app, and posted HAL logs. The setup is unusual: 12-in/16-out multichannel device, VPIO "well outside what it's tuned for" (`will not apply additional config in vp`), and Rogue Amoeba ACE/ARK drivers installed. Its log shows VPIO touching **every** device in the system ("enabled tap stream on dev-126 / dev-141 / dev-92 / dev-118"). If that is the general mechanism, it would not be limited to the built-in mic. *Inference:* the mechanism may be general, but the severity seems to depend on whether the other app also runs Apple voice processing on the **same** device. That would explain why AirPods and USB mics look "fine" in most setups. This is a hypothesis for the VPIO subtopic to test, not an established fact.
4. **13 of 20 reports don't specify the mic** (#1, 2, 5, 6, 8–15, 20). Most are "same issue" comments on a thread about the built-in mic.

**Implication for a clean rule.** "Input transport is built-in → don't use VPIO" covers every report that names a built-in mic: MacBook and iMac, macOS 26.4 to 27.0.1, Teams desktop and web, Zoom, Slack, and Chrome. It does **not** cover the iD24 case. A second clause such as "input has more than 2 channels, or is an aggregate or multichannel interface → don't use VPIO" (alserevs's suggestion) would. There is **no** report of the other-app mic breaking with AirPods or a single-channel USB mic as Biscotti's input. That absence is reported in the threads, but nobody has tested it systematically.

## Which apps are affected?

- **Teams** (native and in Chrome): 9+ reports.
- **Zoom desktop**: gphr74, and possibly DLR-Group.
- **Slack Huddle**: thomasvvugt and the owner.
- **Chrome/WebRTC in general**: alserevs, and timbowicz with webcammictest.com.
- **An Electron chat app**: alserevs.

So it is not Teams-specific. Teams is simply the most reported. No report names FaceTime, Safari/WebKit or Google Meet as broken. Meet runs in Chrome, so it would presumably be covered by the Chrome reports, but nobody says so explicitly. AudioLab's earlier validation ran Biscotti-style capture next to FaceTime and Meet, but it checked Biscotti's own track, not whether the other side could still hear the user.

## Symptom spectrum

The reports describe several related effects. They may have different mechanisms (for the VPIO subtopic to separate):

| Symptom | Reports |
|---|---|
| Other app's mic **fully muted** (other side hears nothing; indicator dead) | #1, 3, 12, 16, 17, 19; also "can't hear me at all" in #8 |
| Other app's mic **much quieter** | #8 ("barely hear me"); owner #18 ("messing with levels, but never completely capturing the mic") |
| Other app's mic **quality degraded** ("hollow", "tinny", "audio character shifts") | #1, #7 |
| **Output (playback) volume ducked** while recording | #14 ("50%"), #16 ("output volume dip"), and measured at −4 dB steady / −15 dB transient in #129 |
| **Biscotti's own mic track silent** on a multichannel interface (channel-0 assumption) | #4 |

## Recurring data points that narrow the mechanism

- **Output reclock is not needed to trigger it.** thomasvvugt (#17) had input and output both at 48 kHz, so `ensureOutputRateMatchesInput()` did nothing, and the Huddle mic still went dead. gphr74 (#16) *did* have a mismatch (built-in 48 kHz in, USB DAC 44.1 kHz out). The reclock may add disruption, but it is not the root cause.
- **The Mic Mode interaction is suggestive.** JulianUll had both apps on "Standard" and saw the failure. alserevs found that setting **different** Mic Modes per app (Voice Isolation for the other app, Standard for Biscotti) restored the other app's mic, and logged `Disabling HAL Voice Isolation support due to app's use of existing chat flavors`. That is one reporter's workaround, not independently confirmed.
- **Disabling VPIO fixes it.** Confirmed by thomasvvugt (#115, Slack Huddle) and javimoya (#118, Teams test call), both on built-in mics.
- **Not version-specific.** Reports span macOS 15, 26.4, 26.6.2, 26.7, 26.7.1 and 27.0.1.
- **A second recorder may make it worse.** gphr74 had MacWhisper recording at the same time. No other report mentions a concurrent recorder.
