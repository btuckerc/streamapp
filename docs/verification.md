# Verification — 2026-09-20

## Native 4:2:0 encoder input, session activity — 2026-10-24

- `EncoderColorTests` renders seven sRGB colours into a 420v buffer with `VideoEncoder.colorAttachments`: every Y/Cb/Cr sample is within 1 of the BT.709 video-range formula (white 235/128/128, red 63/102/240). After adding the BT.709 transfer tag VideoToolbox puts on encoded buffers, `PreviewFrames.image(_:program:)` reads every colour back within 3 of the source.
- A packaged ad-hoc `--smoke` recording (not installed) was compared with the same smoke built from the unchanged sources. The decoded frames at 0.3 s matched (median per-channel difference 0, mean 0.39; the moving synthetic marker accounts for the tail). Program-preview PNGs matched too (median 0, mean 0.6). Before the explicit-sRGB preview fix, the preview was brighter than the output (mean 4.0, e.g. 47/82 vs 42/72). ffprobe: H.264 High, yuv420p, tv range, bt709 primaries/transfer/matrix, 620 frames. `scripts/verify-media.py` reported no decode errors or duplicate timestamps.
- During a packaged `--smoke` session, `pmset -g assertions` listed StreamApp's `PreventUserIdleSystemSleep` and `PreventUserIdleDisplaySleep` named "Recording or streaming"; after the smoke stopped, neither remained. Real sleep and thermal pressure were not exercised. `swift test` passed 73 tests.

## Webcam placement — 2026-10-24

- In the isolated `~/src/streamapp-work/webcam` Mac clone, `swift build` and `swift test` passed: 80 Swift Testing tests in 15 suites (the XCTest runner reports 0; these suites use Swift Testing). Eight new camera-placement tests cover legacy decode/anchor precedence, clamping, exact legacy corner rectangles across all frames, normal/punch sizes and chat arrangements, inverse round trips, independent 24 px snapping and Option bypass, cropped/letterboxed/global-display mapping, unconditional handle exclusion, cursor hysteresis/overlap/bypass, and stale-configuration drag acknowledgment with immediate transition cuts.
- `python3 scripts/build-app.py --identity -` built an isolated ad-hoc bundle without installing. Packaged `--ui-smoke` and `--settings-smoke` each printed the ready marker and remained alive for three seconds. The harness then terminated and reaped only its exact child PID; these UI modes do not exit automatically. The user's installed/running StreamApp was not stopped or replaced.
- Unverified interactively: pointer tracking/cursor feel, preview hit regions and snap guides, floating-panel placement on physical displays, Spaces/full-screen behavior, and actual capture exclusion. Unit tests exercise the mapping and fail-closed visibility policy, not ScreenCaptureKit's live WindowServer behavior. No new polling/timers were added for arrangement or cursor avoidance.

## Voice ducking — 2026-09-24

- `AudioMixerTests.duckingLowersAppAudioOnlyWhileSpeakingThenRecovers` runs every preset through the real mixer: 200 ms of −20 dBFS speech over constant app audio. It checks the depth 180 ms into speech, the hold 190 ms after speech, and one release time constant of recovery. Off leaves app audio at unity. Research and parameter sources are in `docs/architecture.md#voice-ducking-research--2026-09-24`.
- Packaged `--settings-smoke` (not installed): Audio showed a Ducking section below Processing. Selecting Medium enabled its reset button and changed the caption to the −12 dB text. `swift test` passed 72 tests.

## Native Settings window — 2026-09-24

- Settings used a SwiftUI `TabView` inside an `NSWindow` whose `.preference` toolbar style had no toolbar. The segmented tab control was drawn into the titlebar beside the traffic lights, adding vertical space and offsetting them, and it switched to Liquid Glass when clicked. `StudioSettingsController` (`NSTabViewController`, `.toolbar` tab style, `.preference` window) now provides the system preference toolbar, glass selection and per-pane window title. Pane switches have no crossfade, each pane's SwiftUI view loads when first selected, and all panes are 680 × 580 pt, so switching does not resize the window.
- The Layout preview's on/off state moved from a view `.task` to a Combine subscription on `settingsVisible`, `settingsTab` and `videoPreviewMode`. The Layout pane's hand-drawn gradient shadow became a `Divider`, and the footer sits below a `Divider`.
- A packaged `--settings-smoke` run was checked with Computer Use. The toolbar showed seven icon panes, with traffic lights on the title row. Selecting Layout then Output changed the pane and the window title ("Output"). Choosing Layout in the Preview picker started the synthetic preview in the Layout pane. `swift test` passed 71 tests.

## Echo cancellation performance and accuracy — 2026-09-24

- The shipped WebRTC build ran AEC3 without SIMD: upstream Meson `neon=auto` never defines `WEBRTC_HAS_NEON` (0 of 409 compile commands had it), and release builds also left DCHECKs enabled. `scripts/build-aec.py` now forces NEON on arm64 and `NDEBUG`; 251 of 409 units compile with NEON, all 409 with `NDEBUG`.
- The bridge now drives AEC3, the high-pass filter and noise suppression directly instead of through two AudioProcessing instances. The delay estimator decimates to 2 kHz, the high-pass filter runs whenever processing is on, playback beyond ±1 is clamped instead of rejected, and the unused `sa_aec_reset` was removed. The same replay harness linked against the old and new bridges shrank from 1,144,696 to 672,232 bytes (`__text` 665,884 → 374,520). AudioProcessingImpl and GainController2 symbols are no longer linked.
- Isolated DSP CPU per 10 ms block (mean µs, old → new), replaying the same captures through the exact bridges: the two 30 s physical captures (mono-content playback) went from 246 / 251 to 47 / 49 with AEC only, and from 259 / 264 to 54 / 57 with AEC+NS. A fresh 40 s capture of a YouTube Tiny Desk concert (genuinely stereo; 69% volume, built-in speakers and microphone) went from 308 to 61 (AEC) and 320 to 67 (both). NS alone went from 12.7 to 11.1, with bit-identical output. The contributions were: NEON+NDEBUG ≈3×; no AudioProcessing, 3–7 µs; 2 kHz delay decimation, ≈35 µs.
- Echo attenuation, AEC only, total / above 150 Hz: physical captures 18.83 / 20.71 → 20.81 / 21.20 dB and 23.56 / 34.45 → 35.64 / 38.90 dB; YouTube capture 22.81 / 23.08 → 22.95 / 23.15 dB. Below 150 Hz the microphone's residual matched its silent-room noise floor (−57.6 vs −55.8 dBFS), so most low-band gain is rumble removal. With AEC+NS: 22.28 / 32.24 → 22.42 / 38.76 dB; YouTube 29.40 → 28.90 dB.
- Digitally overlaid double-talk speech gain, scored against a ground truth passed through the same 100 Hz filter (its phase shift otherwise reads as ~2 dB loss): −1.32 / −1.79 / −1.81 / −4.73 → −1.40 / −1.77 / −1.76 / −4.92 dB on the physical captures; YouTube −2.20 / −7.37 → −2.23 / −7.53 dB (normal / quiet speech).
- Delay coverage: 100–400 ms of extra echo delay still converged (21.2–22.1 and 35.7–40.6 dB). Three matched filters would have lost the 300 ms case, so all five remain. Starting the delay search at zero is required: without it, residual delays under 5 ms never converged. With 2 kHz decimation, synthetic white-noise echo converged at residual delays of 2 ms or more (19.9 dB) but not at 0–1 ms (<1.2 dB). The old path converged at 0 ms too. The physical captures had ≈48 ms residual; advancing them by 40 ms kept 20.8 / 35.7 dB.
- Before this change, one playback sample beyond ±1 bypassed the whole block: 1.4× full-scale noise was rejected in 1000 of 1000 blocks. The new regression cancels clipped over-range playback by more than 20 dB (measured 32 dB). The NS-toggle regression now uses a 10 ms echo path. It permits one differing transition block, block 1200, because that block still carries the last NS block's band-synthesis tail. `swift test` passed all 71 tests in 14 suites.
- Comparison fixtures, captures and throwaway harnesses remain under ignored `.local/aec-perf/` and `.local/aec-trial/`. These are offline DSP measurements, not whole-app CPU or human listening qualification.

## Runtime benchmark harness vs OBS — 2026-09-24

- Added `bench/`, a repeatable StreamApp-vs-OBS benchmark (`docs/benchmarks.md`), and StreamApp `--bench` mode, which self-timed sessions on the non-persisting demo model. `swift test` passed all 70 tests in 14 suites.
- `bench/stimulus` produced 5 alternating flips with tones and exited 0. Screenshots confirmed that the display cover hides all other windows, the menu bar and the Dock. They also confirmed that `--motion` fills the display with noise. WindowServer GPU in the pre-launch baseline was ≈41 ms/s with motion versus ≈1.3 ms/s with the static cover, which shows the motion pattern animates continuously. A recording from a covered trial showed only the cover, the flip square and the cursor.
- Receiver calibration with a synthetic x264 publisher gave a median floor of 2.17 ms and a max of 4.57 ms.
- A 24-trial run (3 reps; battery, Low Power Mode) completed. It was discarded because screen content was uncontrolled: a browser video raised capture load in both apps mid-run. In a later 6 s check, that video's audio produced 197–210 false tone detections per recording. Content is now controlled, and the A/V gate withholds offsets in that case (checked on those recordings). The precheck refuses to start while audio plays. The discarded run's resource and latency medians are recorded as provisional in `docs/benchmarks.md`.
- Interrupting the harness (SIGTERM or SIGHUP) now runs its abort path: it stops the app session and the stimulus. Cancelling a run during receiver calibration left no StreamApp, OBS, stimulus or probe processes. Not exercised: cancelling mid-session, and the stimulus exiting on parent death. Another agent's StreamApp AEC trial was using the screen and audio at the time.

## Bundle, runtime and dependency reduction — 2026-09-23

- Replaced bundled Homebrew FFmpeg (GPL, 30+ dylibs, `disable-library-validation`) with `scripts/build-ffmpeg.py`: pinned FFmpeg 9.0.2 (sha256-verified), static, LGPLv3, only the components `MediaOutput` uses, OpenSSL linked statically (rebuilds whenever the `libssl.a`/`libcrypto.a` hashes change). The binary links only `libSystem`. The app entitlements are now camera + audio input only.
- `EncodedMuxer` is now a native C FLV writer (one `writev` per packet, 2 s no-progress deadline). A differential harness against the previous libavformat path matched return codes in all 7 cases. Bytes matched in 6 once libavformat's `encoder` metadata entry was excluded; the 7th differed only for a packet at the FLV 24-bit size limit, which 6 Mbps video cannot reach.
- The FFmpeg acceptance script against Homebrew FFmpeg: bitexact MP4 (`+hybrid_fragmented`) and MKV recordings were byte-identical; without bitexact, packet lists matched; the finalized MP4 box order was `ftyp, free, mdat, moov`; SIGINT/SIGKILL behavior was identical; local RTMP tee+fifo delivered both streams. With a correct CA, RTMPS delivered; with a wrong CA it was rejected, as with Homebrew. For a 20 s recording mux, the FFmpeg child used a max RSS of 16 MB vs 26 MB and 5.45 B vs 6.52 B instructions. 20× `-version` took 0.09 s vs 0.78 s.
- Also: the keyframe flag is read without per-frame bridging, the bundled binary is stripped (dSYM in `.build/`), and camera/microphone enumeration runs lazily (Settings/onboarding appear, camera start, saved-microphone start).
- Bundle size went from 45 MB to 10 MB (`StreamApp` 2.75 MB, `ffmpeg` 7.6 MB); strict deep signature verification passed. `swift test` passed all 70 tests in 14 suites. Demo smoke (`--smoke`) passed and its recordings decoded with no backwards DTS; the smoke run used 25.5 B vs 26.6 B instructions, 113 vs 111 MB max RSS and 282 vs 285 MB peak footprint. Median launch-to-ready went from 424 to 209 ms. Idle `--demo` footprint went from 22.0 to 20.0 MB and RSS from 70.1 to 65.4 MB. Settings smoke listed all cameras (including OBS/Continuity-style devices) and microphones.
- Not qualified: a public provider broadcast or physical camera recording.

## Independent voice cleanup and capture-timing investigation — 2026-09-23

- Separated saved default-off Noise reduction from AEC. AEC retains the full-band adaptive filter and speech-preserving residual suppression; NS works independently without playback reference. Separate APM instances prevent upstream's NS reconfiguration from resetting the learned echo controller. A 15-second C-bridge comparison and a retained regression proved output immediately matches uninterrupted AEC bit-for-bit after NS is switched off.
- All 66 tests in 14 suites passed, including five AEC pipeline tests covering NS-only without reference, exact raw-stereo restoration and learned-AEC preservation across NS toggles. An earlier run encountered a camera-geometry assertion during concurrent camera work; the final run passed after that work updated its assertion.
- Production bridge replay of the physical captures with AEC only reduced total microphone energy by 18.83 / 23.56 dB. Speech-only projected gain remained −0.59 dB with a 430-sample shift (~9 ms); separate NS alone shifted 334 samples (~7 ms), both stages 764 samples (~16 ms). Full-band output was finite and duplicated mono. Wall-time means ranged approximately 0.15–0.22 ms for AEC and 0.19 ms for both; scheduler outliers reached 13.7 ms, so these runs are not a real-time worst-case guarantee.
- A deterministic 40-second known-path experiment changed echo gain by +4.1 dB, then changed delay/reflections, then added simultaneous speech. AEC adapted without noise reduction: attenuation was 14.47 dB after the gain step, fell to 2.37 dB during the first second of the path change, and recovered to 9.96 dB in seconds 25–30. Simultaneous synthetic speech projection was −1.35 dB. This does not certify physical screen movement, clipping or long-term clock drift; no fixed acoustic-delay calibration was substituted for adaptive estimation.
- A fresh signed 60-second built-in-microphone/ScreenCaptureKit probe kept Standard mic mode and wrote private local evidence only. Reference callback readiness reached 76 ms relative to its first sample. Replaying complete 20 ms output deadlines over the middle 58 seconds required up to 91.58 ms: an 80 ms allowance missed 190 of 2900 reference blocks, 90 ms missed one, and 100 ms missed none. The 100 ms capture allowance was therefore intentionally retained. This is separate from processor signal shift and is not a guarantee for every device/load.
- Evidence and temporary probe code remain ignored under `.local/aec-trial/path-check/`; production has no diagnostic capture hooks or upstream dependency patches.
- Built, persistently signed, installed and launched `~/Applications/StreamApp.app`. Native Audio settings exposed separate controls and accepted AEC-only → both → NS-only → both → AEC-only transitions. Final accessibility readback confirmed AEC on, NS off, compression on, microphone on and all-app audio on. No recording or broadcast was started for this UI check; the fresh 60-second capture above used the private timing probe.

## Residual hiss reduction — 2026-09-23

- User reported effective speaker cancellation with audible residual white noise. Isolated experiments attenuating only AEC3-generated comfort noise reduced captured residual energy by only 0.5–1.4 dB. Those dependency modifications were not shipped.
- Enabled WebRTC's lowest noise-suppression setting inside the existing AEC path, leaving echo-filter/suppression tuning, gain and compression unchanged. On the same two physical captures, steady residual RMS changed from −69.32 to −72.70 dBFS and −64.81 to −78.90 dBFS (3.38 / 14.09 dB reduction). These are total residual-energy measurements, not a guarantee of equivalent perceptual hiss reduction.
- Speech-only RMS incurred an additional 0.63 dB loss. Very quiet synthetic double-talk remains a tradeoff: aligned speech-component gain changed from −1.79 / −4.45 dB to −6.57 / −11.13 dB. Noise suppression also changes waveform phase; these projection gains are not pure loudness measurements. Measured signal shift increased from approximately 9 to 15 ms. No human listening qualification is claimed.
- The exact modified production bridge reproduced the low-noise candidate output bit-for-bit over 1,440,000 frames; output remained finite and stereo-duplicated. Three AEC pipeline regressions passed. Candidate mean DSP time was approximately 0.18 ms per 10 ms block, not whole-app CPU. Private comparison reports remain under ignored `.local/aec-trial/noise-check/`.
- Packaged, persistently signed, installed and relaunched the updated app. Native Settings exposed the new gentle-noise-reduction caption, retained AEC enabled, and reported Active during real microphone/system-audio level preview. No new recording or broadcast was started for this update.

## Integrated WebRTC echo cancellation — 2026-09-23

- `swift test` passed all 64 tests in 14 suites. Mixer regressions exercise private-reference isolation, raw-stereo bypass, arbitrary pull boundaries, stale-reference fallback and off/on reference invalidation.
- Built the pinned WebRTC audio-processing 2.1 source and Abseil dependency as native arm64 release static libraries. The production C bridge processed two 30-second physical speaker/microphone captures with finite output and exact stereo duplication. Mean processing cost was 175.8 / 173.6 microseconds per 10 ms block; maxima were 530.4 / 286.3 microseconds. These are isolated DSP timings, not total application CPU.
- The selected speech-preserving suppression tuning reduced captured microphone energy by 19.14 / 26.21 dB. Quiet digitally overlaid speech lost 1.79 / 4.45 dB, versus 7.60 / 11.91 dB with upstream defaults; normal overlays lost 1.34 / 1.74 dB. Speech-only loss was 0.59 dB. These are synthetic double-talk comparisons over real acoustic captures, not human listening qualification or isolated echo-return-loss measurements. Residual suppression can still attenuate quiet speech and instruments.
- The second physical capture used the built-in microphone in Standard mode: 99.98% microphone and 99.94% reference coverage, initial gaps only, no timestamp overlaps/discontinuities. No macOS Voice Isolation, speaker monitoring or audio upload was used. Private fixtures and numerical reports remain in ignored `.local/aec-trial/`.
- Built, persistently signed and installed `~/Applications/StreamApp.app`; strict deep signature verification passed. A second dependency build hit the cache without downloading or compiling. The installed bundle contains pinned dependency provenance and third-party notices.
- Native Settings showed the default-off toggle beside compression. During actual recording it reported Active; off/on changes worked with shared all-app capture and with program app-audio capture disabled (independent private reference). Both recordings fully decoded: 67.9 seconds / 3182 audio packets and 58.1 seconds / 2726 audio packets, no backwards DTS or duplicate PTS, maximum audio packet gap 22 ms. Webcam was disabled for these trials, then restored along with app-audio capture. No public broadcast was made.
- Quit and relaunched the installed app; the AEC toggle remained enabled, with microphone, compression, all-app audio and webcam preferences restored. Both owned trial recordings were moved from Movies into private ignored `.local/aec-trial/`.
- This qualifies the installed recording/mixer path and live toggle transitions, not a provider broadcast, long-duration clock drift, music transparency or acoustic listening quality.

## Audio mixer and compression audit — 2026-09-23

- Compared the existing compressor with a below-knee logarithm shortcut using the actual old/new compressor source in a standalone optimized Swift executable. All 528,000 stereo frames were bit-identical, including lower-knee neighbors, threshold, upper knee, loud/quiet transitions and silence.
- Seven alternating baseline/candidate timing runs over 9.6 million frames each: below-knee sine median 31.414 / 31.448 ms; above-knee sine median 32.213 / 32.123 ms. Differences were below 0.3%, not evidence of an improvement. The shortcut was reverted. This measures the isolated compressor, not total application CPU or device capture.
- Reviewed the soft-knee curve and smooth branching detector against Giannoulis/Massberg/Reiss (JAES 2012). No DSP redesign was warranted. LUFS normalization, oversampled true-peak limiting and hardware listening qualification are not claimed.
- Four targeted suites passed 14 tests covering audio-taper round trips, 1 dB fine adjustments, silence/boost limits, existing stereo/compression/mute behavior, and menu-bar/Dock crop intersections.
- Native demo UI: the − button changed microphone gain from 0.0 to −1.0 dB; double-clicking the fader track restored 0.0 dB. Reset while muted preserved mute. The installed final channel layout removes the Audio heading and both Off/Muted labels and uses a gear.
- Built and persistently signed the release configuration, installed into `~/Applications/StreamApp.app`, and launched that exact bundle. Real ScreenCaptureKit Layout preview showed the menu strip disappear and the remaining desktop widen within the same canvas when Include menu bar was turned off. Restored the original inclusion preference and stopped preview after the check; no recording or broadcast was started.

## Certificate-free local builds and release-download investigation

- A clean source copy without `.local/macos-signing-identity` or `APPLE_SIGNING_IDENTITY` built successfully with plain `python3 scripts/build-app.py`. Its 17 bundled libraries and app passed strict deep signing verification; the app reports an ad-hoc signature.
- `--install` also completed into an isolated `HOME/Applications`. Only the running-process check was simulated as “no StreamApp running” to avoid disturbing the actual installed app; compilation, signing, bundle copying and installation were real. The actual installed executable and local signing pin remained unchanged.
- The installed ad-hoc bundle passed the packaged synthetic smoke: scenes, chat/camera toggles, audio controls, clean stop and restart. Both recordings fully decoded without errors, backwards DTS or duplicate PTS: 488 video / 763 audio packets, then 91 video / 143 audio packets. Evidence remains in ignored `.build/local-signing-smoke/`.
- Release mode rejected missing, ad-hoc and unavailable Developer ID identities. An explicitly unavailable local identity also failed rather than silently falling back to ad-hoc signing.
- A fresh download of `streamapp-1.2.0-7-macos-arm64.zip` from GitHub matched SHA-256 `e6fbf9951cd18a834171c38d048e436417999130a766d0bd7f17314310736cb0`. After extraction, strict deep signature verification, stapled-ticket validation, uncached Gatekeeper assessment (`Notarized Developer ID`) and `syspolicy_check distribution` passed on this development Mac.
- Dependency inspection covered all 19 Mach-O files in the downloaded ZIP. Every non-system load dependency resolved inside the bundle; no missing dependency, broken symlink or escaping symlink was found.
- The user retried the release ZIP and still encountered a download/open error, while building and installing locally worked. The original dialog is no longer available. The release failure's cause remains unidentified; development-Mac checks do not establish clean-machine launch success. No Gatekeeper bypass, quarantine removal, permission grant, public release replacement or change to the user's installed app was performed.

## Physical-notch teleprompter

- `swift test` passed 54 tests in 11 suites. Seven teleprompter regressions cover lossless three-line wrapping (multilingual and unbroken text), Markdown cue/emphasis rendering, page retention, reload/error replacement, six-message moderation/late events, independent body/handle privacy and older-settings migration.
- Native save/open dialogs exported a Markdown template and loaded a three-cue script. Actual panels showed three transcript lines and six chat fixture rows on pure RGB-black backing, flush with the screen top and without filename/page chrome.
- After user feedback, the chevron moved into a separate stable panel; eight timed observations confirmed no movement through collapse/expand. The final contour adds concave 8-point top shoulders outside the unchanged text/button layout. The backing bridges only the left half of the notch, ending beneath the camera instead of squaring off its native right corner. Native desktop screenshots showed inverse top curves and rounded lower corners on both expanded and collapsed surfaces. Final handle bounds stayed `(627, 0, 129, 32)` points in both modes; the expanded body is 536 × 134 points including shoulders. Foreground body clicks collapse it, accessible Expand restores it, and the imported second page remained intact in the production app check before the contour-only adjustment.
- A signed native HID-event probe delivered both unmodified Right and Left through the production Carbon shortcut handler (`NEXT`, `PREVIOUS`). Per-process Computer Use key injection does not exercise global Carbon delivery and was not treated as a hardware-key failure.
- Real ScreenCaptureKit plus the production encoder exercised private/public/private transitions with Show StreamApp windows both off and on. Both window IDs stayed stable. Body/handle pixel-region black fractions were 0/0 when private, about 0.857/0.925 when public, and 0/0 after returning private or Off. Encoded frames independently showed 0/0 → 0.848/0.925 → 0/0. This ran before the final contour-only adjustment and qualifies the shared two-window display-capture policy, not third-party screen recorders.
- The final 21.4-second recording fully decoded: 644 video packets, no backwards DTS or duplicate PTS, maximum video gap 34 ms. Camera, microphone, system audio and network broadcasting were disabled; the output audio track was silent. Aggregate evidence stays in ignored `.build/teleprompter-evidence/`; private desktop frames/recordings and throwaway probe sources were removed after verification.
- Production packaging and persistent signing passed with 17 bundled libraries. The new bundle is repository-root `StreamApp.app`; the previously running installed app was not replaced. Chat layout/moderation used fixture events: no new live Twitch subscription, provider reconnect, public broadcast or physical-keyboard qualification is claimed.
- Settings-only placement: removed the menu mode/paging block and its compact view implementation. The signed native app's quick-menu view had no teleprompter controls; its Settings button opened the real Settings window. Prompter retained all three modes, Markdown/template/paging controls and the independent privacy toggle, labeled **Visible in stream and recording** in both the native UI and accessibility. Selecting Transcript showed both notch windows; selecting Off hid both. Production packaging/signing passed. No recording or broadcast was started for this UI check.

## Webcam punch-in and tablet defaults

- Before the configurable-size addition, `swift test` passed all 47 tests in nine suites; production packaging and persistent signing passed with 17 bundled libraries. New regressions cover corner anchoring with chat on either side, unchanged desktop/chat geometry, exact normal-size restoration, transient state clearing/relaunch, eased reversal and Reduce Motion.
- The initial 1.5× / 350 ms implementation was superseded after user feedback. The revised native synthetic Layout preview showed the webcam grow from 22% to 52% of the desktop region's width and return to 22%, while the base size slider stayed at 0.22 and the scene remained Desktop. Ctrl–Option–Command–V also toggled the initial check app while Ghostty was foreground. The final renderer uses the tested 600 ms Bézier curve, not a second capture path.
- Native screenshots and timed samples of the revised composed preview are indexed by `.build/punch-motion-frames.json`. Computer Use screenshot overhead limits these samples; this is not a frame-rate or physical-tablet-latency benchmark. No recording or broadcast was started.
- Tablet Companion was built, persistently signed, installed and relaunched. The driver import changed only ExpressKey 2 from Color to Webcam punch-in. Fresh-app readback confirmed **Annotate / Webcam punch-in / Stroke width / Clear**; pen buttons remained Middle / Secondary and the Wacom overlay Hidden. The suggested defaults match in code and both app guides. Physical ExpressKey activation remains a hands-on check.
- After user approval, the idle installed StreamApp was quit gracefully, replaced with the persistently signed build and relaunched. All seven scene-transition tests passed again after cleanup. In the installed normal app, Ctrl–Option–Command–V enlarged the live camera to 52% and a second press restored 22%; native screenshots and accessibility confirmed Desktop and the unchanged 0.22 base size. The app was left running at normal webcam size. No recording or broadcast was started or stopped.
- The subsequent configurable-size addition exposes independently saved normal and punched-in sizes in the menu and Layout settings. A throwaway compiled smoke check using the actual configuration/geometry source passed legacy migration to 52%, a custom 70% target, Codable round-trip with emphasis cleared, exact normal restoration and 40–90% bounds. Existing regressions now cover custom size persistence and 90% containment. Shared builds stopped at concurrent teleprompter compile errors; the user explicitly deferred the integrated build/native UI check until the other agents finish. This addition is source-only, not in the running installed app. Temporary smoke sources/binary were removed, and no other feature's edits were retained.

## Terminal chat and public emotes

- Native Settings verified Terminal (24 px), Compact (20 px), Large text (32 px), Monochrome (24 px) and Custom after an individual adjustment. Live read-only `xqc` chat continued receiving messages through appearance changes without resetting its count. Test chat's native Text view exposed selectable messages.
- A browser contrast sweep checked 8192 name/background combinations across solid and translucent modes: minimum 4.50005:1. Already-readable Twitch colors remained unchanged. Body, metadata and accents met 4.5:1. This qualifies rendered colors, not full WCAG conformance of video output.
- The signed native probe fetched 413 global and 1030 channel codes for `xqc`, with no unavailable providers; a cached repeat took about 0.27 ms. Actual WebKit loaded `SAJ`, `Kappa`, `SourPls`, `WideHard`, a `Flower0` overlay and FFZ `CatBag` with a static flip modifier. An official Twitch fragment remained a single image; lowercase, punctuation-wrapped and substring variants stayed literal.
- ImageIO decoded exactly one frame for six real CDN assets: `SAJ`, `GAMBA`, `SourPls`, `WideHard`, `Kappa` and `CatBag`. The BTTV `.webp` route was found to return a 492-frame animation for `SourPls`; the shipped `.png` variant decoded as one frame.
- Browser execution checked emotes off, plain-text fallback, case/token boundaries, zero-width stack boundaries, moderation deletion/clear and style changes without resurrecting deleted messages. A 5120-message emote-rich insertion burst took about 85 ms, retained 100 messages and 200 image nodes, and reported zero animations. This is a local DOM/layout microbenchmark, not a sustained CPU or long-duration streaming qualification.
- Native screenshot evidence is local at `.build/emote-webkit-smoke.png`; catalog and image reports are beside it. The temporary signed-app probe was removed after qualification. No message was posted and no recording or broadcast was started.
- After removing the probe, all eight targeted Twitch session/test-mode tests passed and production packaging/persistent signing succeeded with 17 bundled libraries. The final normal app's Test chat loaded the same 413 global / 1030 channel catalog and visibly rendered real incoming `xqc` emotes; reception advanced from 22 to 149 messages. Terminal 24 px and Emotes on were verified through native accessibility. The temporary `xqc` selection was restored to the original blank/default channel, Render chat remained off, and only the owned check instance was stopped. The updated bundle is repository-root `StreamApp.app`; the installed app and pre-existing process were not replaced.

## Simplified Twitch settings

- Native Settings visually confirmed a single baseline-aligned checkmark, account name and info tooltip row, with Disconnect at the right. Removed the redundant chat, capture-preview and app-window instructions.
- Apply was absent for the saved channel, appeared after editing, and disappeared after a real Twitch channel link was validated and normalized to `shroud`. Invalid typed input showed a short inline error; restoring the saved value cleared it.
- All four Twitch session/input tests passed, including channel-link normalization and rejection of deceptive hosts, video URLs and invalid usernames. Signed production packaging passed. The updated local app was opened for inspection; the installed app was not replaced.
- Exclude from display capture now has its own **Refresh apps and windows** button. In the native Settings check, clicking it populated the app exclusion list through the existing refresh action. No exclusion rules or capture settings were changed; signed packaging passed.
- Both collapsible headings now use a full-width button. Native pointer checks expanded Individual windows by clicking its text and collapsed it by clicking the empty heading space; onboarding's Twitch heading also expanded and exposed its controls. Accessibility reports Expanded/Collapsed. Signed packaging passed; no capture or preference changes were made.
- Streaming setup: the signed app's existing Custom RTMP selection showed the missing-key validation error. Selecting Twitch removed the error and manual fields immediately, with checkmark, `Connected as @itux`, and info icon aligned on one row. Twitch was left selected. Four targeted output tests passed, including missing-service migration and clearing validation errors in both switch directions. No output was started.

## Direct Twitch integration

- User approved the registered public application **StreamApp by btuckerc** for **itux**, with chat-read and stream-key-read scopes only.
- The signed native app connected as `@itux`. Settings → Sources → Chat accepted `shroud`; the read-only test subscribed through production EventSub and visibly rendered two real messages with `LISTENING · #shroud · 2 RECEIVED`. No message was posted, recording started, or broadcast initiated.
- A temporary signed-app qualification restored the account from Keychain, validated it, and successfully retrieved the account's stream key. It printed only a success boolean, never the key. The qualification entry point was removed afterward.
- Regression coverage exercises wrong-client rejection, cancellation without later account resurrection, and concurrent unauthorized requests using one refresh rotation. No live-provider reconnect, revocation, or long-duration qualification is claimed.
- Final source passed all 31 tests in nine suites after removing obsolete SSE tests. Production packaging and persistent signing passed; the local bundle is `StreamApp.app` (not notarized).
- A throwaway browser execution of the shipped renderer confirmed HTML-like chat text stays inert, individual deletion, user clearing, the 100-message limit, and full clearing. This exercises DOM behavior, not live Twitch moderation delivery.

## Active wallpaper capture and native control rendering

- A real ScreenCaptureKit probe found the display-sized WallpaperAgent window and captured the current blue mountain wallpaper without app windows, desktop icons or menu text. The production snapshot source produced `.build/actual-wallpaper-source.png` at 2048×1330. This supersedes the earlier file-URL qualification below.
- Temporary production-service checks verified one refresh after a simulated Space-change notification, no recapture after unrelated configuration edits, retained image identity through a RenderInputs camera-size edit, and clearing the snapshot when leaving Mirror. All 31 tests in ten suites passed with those two temporary checks present; the machine-dependent checks were removed afterward.
- Native Layout preview showed the mountain wallpaper around the synthetic foreground. After switching from the active preview to Outputs, Record / Stream / Both labels remained upright; a long RTMPS URL and the Twitch-test switch rendered without the reported magenta rectangle or displaced knob. No broadcast, recording, permission grant or custom-image import was performed. This verifies the exercised UI scenarios, not a proven root cause for the original corruption.
- After removing the temporary checks, the final source passed all 29 permanent tests in nine suites. Release packaging, persistent signing and installation into `~/Applications/StreamApp.app` succeeded; the installed app was relaunched.

## Wallpaper reflection and Settings resets

- The earlier `NSWorkspace.desktopImageURL(for:)` loader decoded a 2048×1080 image, and `.build/wallpaper-qualification.png` showed its reflection around a green foreground. The user's report and subsequent live capture established that this was the default beach asset, **not the active wallpaper**. That lookup and its claimed active-wallpaper qualification are superseded above. Permanent pixel tests still cover different wallpaper/capture colors and safe fallback when wallpaper is absent.
- Native Settings smoke showed Mirrored wallpaper in the live preview and the shadow beneath the pinned preview. Include menu bar reset immediately restored its default without a dialog. Restore All Defaults opened confirmation; Cancel retained the wallpaper choice, while confirming reset restored Black and immediately updated the live preview.
- Full suite passed 30 tests in ten suites, including the temporary wallpaper qualification (removed afterward). The CLT toolchain required explicit Testing framework and runtime search paths; the newly selected Xcode was awaiting license acceptance. No legal terms were accepted by automation.
- Final source passed 29 tests in nine suites after removing the temporary qualification. Release packaging, persistent signing, and installation into `~/Applications/StreamApp.app` succeeded. With user approval, only the obsolete duplicate `otherMouseUp(with:)` override was removed from a concurrent annotation edit; its configurable pen dispatch and tests were retained.

## Desktop backgrounds and Layout preview

- `swift test` passed 26 tests in eight suites; the subsequently added preview-ownership regression also passed its targeted run. Release packaging, signing and installation into `~/Applications/StreamApp.app` passed.
- Real FrameRenderer qualification produced portrait and ultra-wide examples for all five fill modes under `.build/background-qualification/`. Pixel regressions preserve the sharp foreground and catch reflected-tile scaling across wide bars.
- Native Settings smoke verified the shared Off / Layout / Webcam control and a rendered synthetic Layout preview. Changing Black to Blurred desktop replaced the letterbox bars live. Fit 16:9 and its Dock restoration hover help were confirmed through accessibility. The redundant background hint is absent.
- Image import UI testing was deliberately left to the user. No actual camera or new macOS permission approval was exercised by this synthetic check.

## Simplified footer and streaming setup

- Native screenshots verified a label-free Record / Stream / Both selector and one Start button, without the redundant local-only caption. Active output retains health/progress and Stop; bandwidth-test mode retains its non-live indicator.
- Missing Stream and Both configuration opened Connect streaming. Done with missing details stayed in setup. Entering a loopback RTMP URL and dummy key completed setup without starting output; subsequent Start showed the existing broadcast confirmation for 127.0.0.1, which was cancelled.
- The final installed build reopened setup when Start was pressed after cancelling incomplete setup. Returning to Record cleared the stale streaming-validation message. Configured Both did not reopen setup; Record started and stopped a synthetic local recording.
- `swift test` passed all 20 tests. Final release packaging/signing and installation passed. UI fixtures used demo mode, with no normal preference or Keychain writes and no public broadcast.

## Prepare controls, audio defaults, and menu-bar inclusion

- Native onboarding smoke showed Fit 16:9 alongside Render chat in Prepare; invoking Fit opened the existing confirmation, and Cancel left the Dock unchanged.
- Fresh demo configuration showed System audio enabled and Audio from set to all other apps. Turning audio off removed the source picker. Prepare and Settings share the same app selector, including unavailable-target handling and explicit refresh. Existing saved off/isolated choices and the legacy privacy migration remain intact.
- A native ScreenCaptureKit screenshot probe on the main display exercised `SCContentFilter.includeMenuBar` both ways. With it off, menu text/status icons disappeared; with it on, they were visible. Both images and filter content rectangles retained 1512×982 dimensions. Evidence: `.build/menu-bar-true.png` and `.build/menu-bar-false.png`. No system menu-bar preference or permission was changed.
- Final Settings smoke visually confirmed Include menu bar directly beneath the Dock-fit control in Layout, enabled by default. `swift test` passed 20 tests in seven suites; release packaging and signing passed. The temporary screenshot probe was removed after verification.

## Unified permission recovery

- `swift test`: 20 tests in seven suites passed. Final release packaging and persistent signing passed.
- Native menu inspection with a temporary missing-permission fixture showed one **Finish permissions setup…** button above the meters, with screen/system-audio, camera and microphone listed beneath it. Clicking it opened the existing onboarding Connect step. Separate menu permission buttons were absent.
- The host already had capture permissions; this verified missing-state presentation and navigation, not a real macOS denial/grant transition. No permissions were reset or granted. The temporary fixture was removed before the final build.
- Final packaged `--ui-smoke` launched successfully; accessibility inspection confirmed no permission banner or legacy Grant Camera/Microphone buttons in the normal synthetic demo. Demo does not require capture permissions or save normal preferences. Test instances were stopped; the installed app was not replaced for this change.

## Explicit recording / streaming modes and camera permissions

- `swift test`: 17 tests in six suites passed. Release packaging/signature verification passed.
- Actual native menu showed Record / Stream / Both and matching Start labels. Mode selection disappeared during capture; local-only, stream-only and combined summaries remained visible. Sources settings had no camera-permission button with camera access already available; onboarding's existing ready state remains a noninteractive checkmark.
- Exercised the real UI with synthetic media and an explicit loopback RTMP destination, not a public provider. Stream-only reached the local receiver and created no local recording. Both produced a received stream and local recording. Returning to Record retained the working stream setup and recorded locally without confirmation or any network socket in its FFmpeg child (`lsof -nP -a -p PID -i` returned no sockets).
- The retained Twitch-test setting was also exercised with Record selected: local recording started and displayed local-only status, not a misleading bandwidth-test status.
- Three local recordings and two loopback receiver recordings fully decoded with FFmpeg. Receiver evidence remains in `.build/output-mode-receiver/`; synthetic local recordings are in the existing temporary `StreamApp-Demo` directory. Demo mode did not save normal preferences or credentials. Both test processes were stopped.

## Dock reservation rollback — 2026-09-21

- Traced the original `e7f8f63` implementation: `CFPreferences` tile-size write followed by direct Dock `SIGTERM`. The later System Events implementation changed that mechanism. Earlier application-quit restart experiments did not exercise the exact original path.
- With explicit approval, a throwaway native application performed exactly two direct Dock restarts: size 128 / auto-hide off, then size 29 / auto-hide on. The usable bottom boundary changed from 0 to 121 points and returned to 0 after asynchronous publication. A separate fresh process confirmed the released boundary, original size/hiding, and unchanged zero animation/delay preferences.
- The ordinary test window did not automatically move when Dock grew. Attempts to drag that fixture through Computer Use produced no frame change; manual resize-back is not claimed as verified. No window-management implementation was added.
- Restored the preference-write/SIGTERM mechanism in `DockCanvasFit`, batching size with visibility and retaining recovery state until hidden-Dock space returns. Removed normalized-slider restoration and obsolete Automation packaging requirements. The two focused Dock geometry tests passed; signed release packaging passed.
- The user elected to perform the rebuilt app’s final Fit on/off test. The mechanism experiment above is not end-to-end verification of that new app-level cycle. No further live Dock tests were performed after that choice.
- Release review caught disconnected-display recovery waiting forever across retries. An isolated compiled fixture using the production `restoreSaved` method failed before the fix with the retained-journal error, then passed after treating an absent display as having no remaining work-area reservation. It verified restored size and cleared journal/state without changing the real Dock or disconnecting hardware. All 54 tests passed afterward; temporary fixture source/binary were removed.

## Earlier System Events Dock auto-hide restoration (superseded)

- Fit now journals the original auto-hide setting before showing the Dock, restores it on disable or failed enable, and preserves a newer manually hidden state. Visibility recovery is attempted even if size recovery fails; an incomplete recovery retains the journal.
- `swift test` passed all 17 tests in six suites. System Events auto-hide get/show/restore scripts compiled against the installed scripting dictionary without execution or permission grants.
- Release packaging and signature verification passed. Subsequently rebuilt, installed at `~/Applications/StreamApp.app`, and relaunched after the user reported the older unhide-first message. Native UI shows the new confirmation explaining temporary visibility and saved auto-hide restoration; Cancel was exercised without granting Automation or changing Dock settings.
- Hidden → Fit on → Fit off and failed-enable rollback are left for the user's physical check; no claim of live Dock visibility testing.

### Dock settling and normalized-size readback

- Fit now waits for stable visible geometry after unhiding and records the size macOS actually accepts after each intentional write; clamped/quantized readback no longer triggers the false external-change warning. Original recovery values remain unchanged.
- Native on/off smoke enabled Fit without the reported warning and exposed a normalized-float restoration rounding issue. Restoration now uses the existing bounded size search only when direct restoration misses the exact saved tile size; pending writes tolerate one tile's normalized quantization.
- Rebuilt and installed the signed app. The two Dock geometry tests passed. Native recovery then successfully switched Fit off without the restoration error. Hidden-Dock end-to-end verification remains unclaimed: another StreamApp UI-check instance appeared during that check, so further UI interaction was stopped and pre-check visible Dock state restored.

## Ableton audio isolation and routing research

- Reviewed installed Ableton Live 12.4.3 / OBS 31.0.1 version metadata and only the relevant saved audio/scene settings. Researched Apple Bluetooth/mic-mode/SCK behavior, Ableton latency/aggregate/routing guidance, OBS's native audio source implementation and BlackHole/Loopback alternatives. Detailed sources, risk matrix, recommended settings and unimplemented advanced requirements are in the architecture document.
- Native signed-app probe exercised real ScreenCaptureKit audio with two independently launched fixture apps: 440 Hz selected app and 880 Hz unrelated app, no microphone/camera/chat/network broadcast. Full Camera → fixture-window Desktop → Full Camera retained music; absent target rejected startup; isolated menu preview produced signal; quitting the selected app stopped/finalized capture.
- Decoded isolated recording: 440 Hz amplitude ≈0.1131; 880 Hz ≈0.00000012 at second 1, ≈0.0000668 at second 4, ≈0.00000036 at second 7. All-app mode contained both tones at ≈0.1131. Minimum 100 ms audio RMS through the middle of the scene-transition recording was 0.079898 (excluding startup/end 0.5 s). This measures app exclusion and continuity rather than trusting moving meters.
- The native probe reproduced an existing single-window startup failure: assigning a window's global content rectangle to `sourceRect` returned “invalid parameter.” Leaving `sourceRect` zero for full-window capture fixed the same scenario. Display/Dock cropping remains on the display path.
- Initial CLI-child tone fixtures shared process-responsibility attribution: selecting one captured both; self-excluded all-app capture excluded both. Re-running with independently LaunchServices-launched bundles established the actual isolation result above. This reinforces that app attribution is not a sandbox between arbitrary child/helper processes.
- Isolated native recording fully decoded: 276 video packets, 433 audio packets, no backwards DTS or duplicate PTS, maximum video/audio timestamp gaps 34/22 ms. Evidence remains local under `.build/audio-qualification-4/` (`media.json`, `spectral-results.json`, recordings). The temporary probe and fixture programs were removed from shipped sources.
- Native Computer Use verified the new Audio tab, explanatory text, refreshed app picker, and selecting the controlled AudioTone app. Demo settings were used; no normal saved audio settings, OBS scenes, Live preferences, permissions, credentials, or hardware routes were changed.
- `swift test`: 17 tests in 6 suites passed, including a privacy regression that legacy visual-scoped audio cannot silently migrate to all-app capture; explicit chosen app/all-app scopes round-trip.
- Final packaged synthetic smoke passed scene/chat/camera/audio controls and clean stop/restart. Both finalized recordings fully decoded with no backwards DTS or duplicate PTS: 487 video / 761 audio packets, then 91 video / 143 audio packets. Evidence: `.build/audio-final-smoke/media-0.json` and `media-1.json`.
- Final release packaging and signature verification passed with 17 bundled libraries. Installation safely refused because the installed app and a separate annotation UI check were running; neither was interrupted. Updated bundle remains at repository-root `StreamApp.app`. Quit other instances before `python3 scripts/build-app.py --install`.
- Not qualified: actual AirPods/Bluetooth behavior, hardware input-channel mapping, actual Live set/main/cue/plugin routing, physical camera lip-sync, real OBS capture, device hotplug/sleep, multi-hour endurance, or authenticated provider delivery. No “every setup is fixed” claim.

## Annotation smoothing, styles and shapes

- Color-wheel/defaults update: 20 focused annotation tests passed. The signed local bundle built successfully. Computer Use verified the Drawing settings show independent Stroke/Highlighter/Fill controls, 6 pt width, enabled Hold to straighten, and Off/Strong beside the smoothing track. The color wheel rendered its eight labeled swatches and switching to Fill exposed No fill. The user confirmed the radial interaction works; further radial testing stopped.

- Integrated `swift build` passed using an isolated scratch directory so the concurrent agent's normal build directory was untouched.
- Native AppKit smoke exercised the actual annotation source with synthetic pointer events and bitmap comparisons: visible dots, smoothing changing a jittered stroke, settings not restyling completed ink, undo restoring exact prior pixels, erasing/undoing the eraser, clear, reverse-drag Shift squares/circles, and completed shape geometry remaining unchanged after Shift release.
- Before the pen-button swap, Computer Use visually verified raw/balanced/strong stroke examples, circle/rectangle outlines, freehand curved arrows with terminal heads, and a foreground right-click enabling the visible Straight toggle. A curved input gesture then produced a straight arrow.
- The integrated app's `--settings-smoke` Drawing tab displayed smoothing, width, color and shape/pen-button instructions. Dragging smoothing changed Balanced to Strong; the native width increment changed 4 pt to 5 pt. The native color panel opened.
- Rebuilt and launched the integrated `--ui-smoke` after the icon-toolbar update. All ten native SF Symbols rendered, accessible names remained intact, and selecting Arrow plus Straight produced independent visible selection outlines. Toolbar width was 411 pt, down from the text toolbar's 699 pt.
- A throwaway settings executable verified smoothing/width/sRGB round trips and that non-persisting demo settings do not overwrite saved values. `swift test --filter AnnotationSettingsTests` passed the normalization regression: changing a published style cannot recurse indefinitely, invalid numeric values normalize, and color remains opaque.
- Subsequent minimal-toolbar update removed the footer and reduced the installed toolbar to 411 × 52 pt. Each icon has descriptive native hover help and an accessibility label/help string. The signed release built, verified, installed into `~/Applications/StreamApp.app`, and relaunched after checking the prior app was idle. Computer Use verified the installed single-row toolbar and Arrow's accessible help. The saved smoothing key was absent, so the existing 0.5 default applies; no user style preference was overwritten.
- Straight/freehand consistency and hold mode: four focused annotation tests passed, including bitmap thickness equality for Pen/Arrow at synthetic tablet pressure, stronger-pressure width growth, zero-pressure pen-up retention, hold before contact, converting an active curved stroke, release not latching the next stroke, exact undo after conversion, and Escape clearing a held mode. The installed Drawing settings toggle was exercised on/off; its enabled value persisted as `StreamApp.annotation.holdToStraighten = 1`, then was restored off to retain the prior interaction preference. Signed release packaging/install and native settings inspection passed.
- Removed explanatory paragraphs from Drawing settings at user request. Rebuilt/reinstalled the signed app and visually checked the installed executable's settings UI: only smoothing, width, color, and Hold to straighten remain. The isolated verification process was stopped afterward.
- No Wacom driver configuration was changed. Physical pressure/barrel-button delivery, subjective handwriting feel, and capture of the new geometry in a recording remain unqualified.
- Pen-button swap: seven focused `AnnotationInkTests` passed, including physical lower/upper tablet-button masks, repeated-packet edge handling, clear during a stroke without ink resurrection, existing pressure rendering, and hold/release behavior. These are synthetic AppKit events, not physical pen-delivery verification. The temporary StreamApp Wacom profile created during investigation was removed; the saved preferences contain no StreamApp profile and retain the global lower-button function 91.
- The signed updated bundle was launched with `--ui-smoke`. Computer Use verified middle-click selecting Straight, a curved synthetic pointer drag rendering a straight line, and right-click removing that line. The isolated smoke process was stopped. Installation of StreamApp was deliberately refused by its packaging script while existing instances were running; the verified bundle remains at the repository root.

## Chat-aware live Dock sizing

- Two focused geometry checks cover chat reducing the requested Dock height, a physically impossible target saturating at zero, dynamic capture height preserving desktop width/menu-bar origin, and no cropping of other displays or individual windows.
- All 15 tests in five suites passed with the Dock changes. System Events get/set scripts compiled against this machine's scripting dictionary; neither was executed. No Automation permission was granted.
- Physical live resizing, Handoff appearance/disappearance and the new permission flow are left for user testing. Earlier restart-based calibration evidence below does not qualify the replacement live-control implementation.
- Release installation was blocked by concurrent capture/audio edits after that passing checkpoint. The final attempted build reported incomplete scopes around the preview monitor/catch and missing preview teardown boundaries in `CaptureEngine.swift`. The Dock revision was not installed; the previous installed app was relaunched. A combined build is required after those edits settle.

## Earlier menu preview, Twitch test mode and fitted desktop

- Installed native menu opens and closes on consecutive status-item clicks. Real Layout and Webcam previews were inspected; Off is first and selected after relaunch. Layout → Off removes the video surface while keeping audio meters.
- Dock calibration initially rejected the built-in display: macOS reserved 128 points versus the 131.5-point target. The implementation now accepts a narrow desktop gap while preserving an exact 16:9 capture; it never extends into the Dock.
- Final installed menu shows Fit 16:9 beside Render chat. Its resize confirmation and Cancel were exercised; cancellation leaves the toggle Off and the Dock unchanged.
- Actual toggle enabled successfully, remained recoverable after app restart, and produced a live desktop/webcam preview including the menu bar but excluding the Dock. Turning it off reported verified restoration of the original Dock size. The feature was left Off.
- Twitch test settings and the native “Start Twitch bandwidth test?” confirmation were exercised with a dummy key in nonpersistent demo mode. Cancelled without starting a broadcast. No Twitch delivery or WAN stability claim.
- All 13 tests in four suites passed, including bandwidth-test URL construction and rejection of non-Twitch hosts/override queries. Packaged synthetic smoke passed scene/chat/camera/audio changes, clean finalization and restart; the first recording decoded fully with FFmpeg without errors.
- Tablet Companion’s generated tablet-and-pen icon was inspected in its icon asset and the actual Dock.

## Tablet Companion and Center decoupling — 2026-09-20

- Installed native companion in `~/Applications/Tablet Companion.app`, source in `~/src/wacom`. Direct driver discovery identifies the connected Intuos BT S.
- Actual companion UI Apply → Restore → Apply changed only the global leftmost ExpressKey between Shift and Control–Option–Command–D. Driver flush/readback verified Option, Control, and Command remained assigned to the other keys. Physical tablet-button event delivery was not simulated.
- Center was closed before companion operations; the driver subsequently relaunched it because its autostart preference was enabled. A controlled Center toggle and driver flush identified `WCAutoStart`; it is now Off. The companion has its own explicit autostart-disable operation, not a Center scripting dependency.
- Typed-XML smoke passed shortcut round-trip, CDATA preservation, unchanged other keys, restoring Shift, and rejection of an unknown tablet identity.
- Actual direct driver startup smoke enabled then disabled Center autostart, with all ExpressKey assignments preserved. Final preference is Off.
- Installed companion downloaded and verified the official installer through its native UI. No installer license was accepted and no driver reinstall was performed.
- Inspected the official 6.4.14-1 package: Wacom Developer ID Installer signature and Apple notarization verified. Its distribution has one mandatory payload including Center; no driver-only installer choice exists in this package.
- Companion build uses a persistent Apple Development identity and is not notarized. No clean-Mac installation or new permission grant is claimed from tests on this already-configured Mac.

## Menu icon, focus and idle audio — 2026-09-20

- Installed release inspected in the actual menu bar: original three-ribbon wing mark, native template contrast, separate recording dot. Opening the menu immediately showed a blue Start Recording button without a selected-scene focus outline.
- Real authorized microphone registered approximately −45 dBFS in Mic and Mix preview before recording. Start switched to Recorded mix; Stop finalized the recording and resumed the idle audio check. Closing the menu cleared the system capture indicators.
- The resulting local MKV decoded fully with FFmpeg and no errors. No broadcast was started. All 11 tests in three suites passed.

Built and exercised on the M2 Max laptop, macOS Darwin 27. Current bundle is persistently Apple Development signed and installed at `~/Applications/StreamApp.app`; not notarized.

## Rounded webcam, cursor and menu presentation

Evidence: `../Research/app-verification/native-surface/`.

- Installed synthetic smoke passed scene/chat/camera changes and restart. Inspected snapshots show rounded desktop webcam corners without a frame and square edge-to-edge Full Camera. The 16.2-second first output fully decoded: 486 video packets, no backwards DTS/duplicate PTS, maximum gap 34 ms.
- Actual installed local recording ran 76 seconds and fully decoded: 2,280 video packets, no backwards DTS/duplicate PTS, maximum gap 34 ms. Its frame confirms rounded real camera video and public ink without the private toolbar. A magnified encoded cursor region confirms a plus crosshair during drawing. Private recording stays in Movies; temporary extracted private frames were removed.
- Created ink through the native overlay, pressed Escape, then used the new menu **Clear annotations** button; fresh desktop screenshots confirmed retained ink disappeared.
- After a real status-item click, the popover first appeared in the native window sample at 252 ms. All 21 visible samples through 1,312 ms reported exactly `(891, 28, 446, 626)` points. No post-show jump was observed; screenshots confirmed its contents fit the current built-in display. Other display arrangements remain untested.
- A 12-second real desktop/webcam recording sample averaged 34.11% of one CPU core across nine steady process-tree samples, with 222.80 MiB peak footprint. It excludes GPU/shared WindowServer cost and does not isolate the incremental cost of rounded styling.
- Final release packaging/install succeeded and all 11 tests passed. tldraw's official custom-UI browser demo was exercised for drawing, selecting/moving and erasing synthetic strokes; this is not a WKWebView, Wacom, VoiceOver or comparative performance qualification. See the explicit drawing-engine decision in architecture.

## Independent chat, annotations, exclusions and audio

Evidence: `../Research/app-verification/annotations-audio/`.

- Final installed build passed packaged synthetic smoke with chat toggled in both scenes, camera/audio changes, finalization and restart. The first recording fully decoded: 488 video packets, zero backwards DTS/duplicate PTS, maximum gap 34 ms. Synthetic desktop-without-chat and full-camera-without-chat snapshots were inspected.
- All 11 tests in three suites passed, including legacy-settings preservation, transient window rules, chat-free geometry, brief-peak retention, mute clearing, linked compression across pull boundaries and bounded mixed peaks.
- Native pen, eraser, undo and Escape were exercised. A 183-second real desktop/webcam recording contains ink but no chat panel or annotation toolbar. Full decode passed; 5,491 video packets, zero backwards DTS/duplicate PTS, maximum gap 34 ms. Private media remains outside Git.
- The initial Option–Command–D shortcut conflicted with Dock; the installed shortcut is **Control–Option–Command–D**. Opening drawing with that shortcut and dismissing its controls with Escape were verified in the final installed app.
- A separate actual recording excluded the Infuse application and one Ghostty window while retaining the webcam. The excluded windows and StreamApp settings were absent from the encoded frame, exposing underlying windows as expected. Verification-only exclusions were cleared afterward.
- A 12-second live desktop/webcam sample with no chat averaged 32.17% of one CPU core across nine steady process-tree samples; peak footprint 249.28 MiB. This is a short observation, excludes GPU/shared WindowServer cost, and is not a controlled comparison with the earlier full-camera measurements.
- An actual AudioMixer CPU probe processed 60 seconds of synthetic stereo audio in 0.103 seconds without compression and 0.108 seconds with compression. It includes fixture-generation and measurement overhead; it is not a perceptual quality or whole-application power benchmark.
- Wacom Center reported no connected device. Physical pen pressure and ExpressKey assignment remain unverified. Official driver API research supports keystroke/modifier and preference operations without opening Center, not driver-free operation or verified compatibility with every current tablet.

## GPU preview and output confidence

Evidence: `../Research/app-verification/gpu-preview/`.

- Actual native `PreviewSurface` presentation probe: 354 presented frames, 30.0001 fps after warmup, maximum steady-state presentation gap 33.337 ms. Hiding the window disabled preview requests; three already-scheduled presentations completed around the hide transition. This measures drawable presentation, not just a configured timer.
- Installed setup Start/Stop preview have identical accessibility bounds: `(520, 386, 164, 24)`. The fixed-size control sits above the preview. Native screenshot confirms GPU-rendered synthetic program content.
- Normal local recording started without any preview. The menu displayed advancing output time and actual bytes written; Show webcam explicitly enabled the real camera view. Both were exercised in the installed app.
- Same-session 15-second live fullcam samples: without preview, 32.34% of one CPU core and 235.49 MiB peak footprint; opt-in camera preview, 37.01% and 246.25 MiB. Each has 12 steady process-tree samples. These short observations exclude GPU/shared WindowServer costs and are not a controlled comparison to older runs.
- The 92.6-second real camera/audio recording finalized and fully decoded: 2,778 video packets, zero backwards DTS or duplicate PTS, maximum video gap 34 ms. Private video remains in `~/Movies/StreamApp`; only metadata is copied here.
- Packaged synthetic smoke passed scene changes, camera/audio controls, stop and restart. Output progress advanced from 2.4 s / 1 MB to 14.5 s / 10.2 MB; the resulting media decoded cleanly.
- Native WebKit probe passed exact 384×1080 snapshots, initial paint, dirty updates, no additional snapshots while clean, and unchanged-status suppression. Throwaway probes were removed after verification.
- Final release build/install and all seven existing tests passed.

## Onboarding, fullcam glass and morph update

Evidence: `../Research/app-verification/onboarding-motion/`.

- Installed bundle passed strict deep signature verification and has an Apple-anchored designated requirement, not a changing ad-hoc cdhash. Signing fingerprint is pinned in ignored `.local/`.
- Seven tests in three suites passed. Added behavioral regressions for interrupted morph continuity/exact completion and Reduce Motion interrupting an active transition.
- Packaged synthetic smoke passed. Encoded frames at 4.10, 4.20 and 4.32 seconds show camera resizing into full-frame while the shared chat becomes a glass overlay. Fullcam fixture demonstrates sharp detail outside the blurred panel and sharp text above it.
- Native WebKit alpha probe initially caught an opaque snapshot despite transparent CSS; after disabling its backing background, the real SSE snapshot passed alpha < 0.01 in empty regions.
- Installed first-run Connect → Prepare → Try it exercised through actual native UI. Prepare shows a scene preview and explicit live rehearsal control. Camera, microphone and system audio have matching icons. Blank stream-key save is disabled; Twitch setup prefills the verified TLS ingest without starting broadcast or reading secrets.
- User-authorized live recording captured built-in display, real camera, microphone and system audio for 154.3 seconds: 4,629 H.264 packets, clean full decode, zero backwards DTS/duplicate PTS, maximum video interval 34 ms. Actual microphone and system meters registered signal; the recording contains the 880 Hz test tone (amplitude 0.01785 at 7 seconds).
- Live layout changes, camera disable/re-enable, connected chat overlay and local stop worked. Chat messages continued through scene changes. A second local rehearsal with Twitch enabled in settings had no TCP sockets in the FFmpeg child; it finalized and decoded cleanly (991 frames). No key was loaded or supplied. A third rehearsal was finalized by Finish (270 frames), decoded cleanly, and persisted onboarding completion.
- A 20-second fullcam live process-tree sample (17 steady samples, preview enabled, real camera/audio, WebKit SSE, GPU glass) averaged 35.27% of one CPU core; peak footprint 254.56 MiB. This excludes GPU and shared WindowServer cost, is a short observation rather than a performance guarantee, and is not a controlled OBS comparison.
- Live recordings stay in `~/Movies/StreamApp`, outside Git. Repository evidence includes only synthetic frames, non-private setup screenshots and aggregate media/resource metadata. Temporary chat URL restored to port 8080, public streaming left disabled, local fixture stopped.

## Earlier base implementation verification

- Release app built with 17 bundled non-system dynamic libraries; strict deep signature verification passed during packaging.
- `swift test`: five tests in two suites passed, including stereo PCM layouts, bounded mixing, mute/late-sample handling, SSE blank-line framing and oversized-line rejection.
- Packaged synthetic smoke: both scenes, camera-off slate, live camera position/chat side, microphone mute, system gain, clean finalization and second session passed.
- Final first recording: 481 H.264 frames through 16.000 seconds; audio through 16.000 seconds. Second session: 91 video frames through 3.000 seconds, audio through 3.008 seconds. Full decode clean; no duplicate PTS or backwards DTS. Evidence: `../Research/app-verification/media-0.json` and `media-1.json`.
- Real ScreenCaptureKit captured only a known synthetic virtual display and fixture window. Native SSE chat rendered actual messages. Live sidebar width/side, stop and restart passed. Both recordings decoded cleanly (`media-2.json`, `media-3.json`); audio intentionally silent. Screenshots: `live-display.png`, `live-window.png`.
- Actual menu-bar popover verified after the reported off-screen placement bug: x=856, y=39, width=446, height=626 points within the 1512×982 built-in screen. Same bounds idle and recording; Start/Stop stays pinned. Content height is selected from the anchor display before showing; the actual popover window is clamped to its visible frame. Screenshots: `menu-fixed.png`, `menu-recording-fixed.png`.
- Native settings Sources/Layout/Outputs were inspected without granting permissions or writing a stream key. Earlier UI interaction also verified scene selection, webcam toggle and microphone mute/meter changes.

## Network and sustained operation

- Local RTMP receiver deliberately interrupted for six seconds. Recording continued; recovered stream decoded cleanly and 122 recovered H.264 packets matched the recording starting at frame 360. `packet-proof.json` records this comparison. The deliberately killed initial receiver file is truncated (`media-6.json`); this is not a failed application recording. Recovered file passes (`media-7.json`).
- Tone measurements verify microphone mute and half system gain, not merely slider wiring (`mixer-proof.json`).
- Bundled FFmpeg's exact nested FIFO/tee TLS options were exercised against a localhost self-signed certificate: connection rejected with `certificate verify failed`. RTMPS explicitly enables certificate verification and uses `/etc/ssl/cert.pem`; it does not rely on FFmpeg's permissive default. See `tls-rejection.txt`.
- A prior 180-second synthetic app soak produced 5,402 video frames, clean full decode and no backwards/duplicate timestamps (`media-4.json`). This ran before the final shared-clock/drain hardening and popover sizing fix. The final shorter smoke and real-SCK scenarios above exercised those media-clock changes.
- That synthetic soak's 90-second sample averaged 26.33% of one CPU core across app and FFmpeg, with 98.20 MiB peak footprint. It did not include real camera, ScreenCaptureKit or WebKit workload; it is **not** an apples-to-apples OBS comparison or a power/fan measurement. Historical controlled comparisons remain in Research.

## Deliberately not claimed

Public provider/WAN streaming, perceptual hardware lip-sync, multi-hour operation, clean-machine distribution and notarization remain untested. No stream credentials or public broadcast were used. The initial base tests below used only synthetic sources; the current update above adds explicitly authorized live device capture. Twitch ingest TLS handshake was independently validated without credentials or media, but that does not claim a successful authenticated Twitch broadcast.

## Reproduce

```sh
python3 scripts/build-app.py
swift test
StreamApp.app/Contents/MacOS/StreamApp --smoke .build/smoke
python3 scripts/verify-media.py PATH_TO_RECORDING --output .build/verification.json
```

`--demo` uses synthetic sources without normal settings/Keychain writes. The packaged smoke's RTMP option accepts only loopback destinations. Historical fixture tools and original clips are preserved in the verified research archive, not shipped in the application.

## Configurable annotation controls

- Native UI exercised the six-tool radial picker, selected Arrow and observed toolbar selection, and opened the color/width pickers. Width choices fit a 6×4 grid. Color rendering and keyboard picker positioning were corrected after visual inspection.
- 29 Swift tests in 9 suites passed, including delivered-button routing independent of tablet masks, no Clear from secondary-click, hover-before-contact Straighten, release semantics, and exact shortcut modifiers.
- Production Wacom Swift smoke passed journal applied/not-applied/conflict paths, legacy restore expansion, repeated remapping baseline retention, and typed XML controls.
- Installed Companion applied and verified Annotate/Color/Stroke width/Clear and lower Middle / upper Secondary click on the connected Intuos BT S. Overlay remained Off. Physical pen hover behavior after remapping still needs a hardware press; synthetic input is not proof of it.
- Final installed UI showed distinct named color swatches near the pointer; a native-input stroke appeared red and disappeared with the Clear shortcut. Companion's main screen and Apply dialog were visually checked after moving setup/details into collapsed sections.
- Driver readback retained only global application association `0`, tip function `1`, lower function `2`, upper function `3`, Press-and-Tap `false`, and button overlay `false`.

## Privacy shield slice — 2026-10-24

Checked in the isolated `~/src/streamapp-work/privacy` Mac clone; no installation or user-app restart.

- `swift build`: passed (debug build, 13.83 s). The clone emitted stale-build-root warnings and existing microphone weak-capture warnings.
- `swift test`: **86 tests in 17 suites passed**, including real Vision fast-OCR recognition of CoreText-rendered fake AWS and `sk-proj-` credentials, packet delay/order/invalidation/fail-closed/keyframe/monotonicity checks, PCM exact delay/wrap/flush and redaction hold/merge/expansion checks. Earlier runs exposed test macro mutability errors, detector indexing/UUID false positives and OCR-inserted whitespace; these were repaired before the passing full run.
- `python3 scripts/build-app.py --identity -`: passed, including the production build and ad-hoc bundle signing. The default signing identity is unavailable over SSH with the login keychain locked; Developer ID signing/notarization was not checked.
- `StreamApp.app/Contents/MacOS/StreamApp --ui-smoke` and `--settings-smoke`: each printed `StreamApp ready — idle; no capture started` and survived five seconds without exiting/crashing. These existing modes do **not** self-terminate; a Python subprocess supervisor terminated only its own exact child PID afterward. This is a launch smoke, not visual UI inspection.
- `StreamApp.app/Contents/MacOS/StreamApp --smoke .build/privacy-smoke --smoke-stage-seconds 1 --privacy-shield`: passed all five scene stages, clean delayed stop and restart with the default two-second shield delay. No device capture permission was required (synthetic sources).
- `python3 scripts/verify-media.py .build/privacy-smoke/StreamApp-2026-10-24T00-31-40Z-F436E6D4.mp4 --output .build/privacy-media-0.json` and the corresponding second recording `StreamApp-2026-10-24T00-31-48Z-8B8012F4.mp4` / `.build/privacy-media-1.json`: full decode exit 0, no backwards DTS or duplicate PTS in either stream. An additional `ffprobe -v error -show_packets -show_entries packet=stream_index,pts_time,dts_time -of json <file>` check asserted strictly increasing PTS and DTS in packet order. First recording: 163 video / 255 audio packets, durations 5.454375 / 5.440000 s (14.375 ms difference). Restart: 90 video / 142 audio packets, durations 3.021375 / 3.021333 s (0.042 ms difference).

Real-screen secret introduction/removal through the full encoder/muxer path, scan-overrun recovery in a live recording, sustained OCR power/memory cost, visual popover status/pixellation, real-device lip sync and WAN streaming remain unverified. OCR recall remains best-effort; passing synthetic fixtures is not a privacy guarantee.

## Music-production audio slice — 2026-10-24

Verified in the isolated `btc-mbp14:~/src/streamapp-work/audio` clone; no installation or authenticated broadcast:

- `swift build` passed. `STREAMAPP_FFMPEG_PATH="$PWD/.build/ffmpeg/bin/ffmpeg" STREAMAPP_AUDIO_FIXTURE_VIDEO="$PWD/.build/audio-fixture.flv" swift test` passed **83 tests in 15 suites**, zero failures (final run 3.696 s).
- Added consumer checks cover centered mono and stereo 3/4 selection from interleaved/planar four-channel PCM at 44.1/48/96 kHz, delivered-channel fallback, settings defaults/unknown values/round-trip, exact signed offsets for both sources, independent extreme-offset windows across ring wrap, AEC raw-time alignment, limiter-reduction peak hold, and timed silence/rejoin after microphone loss.
- The first mapped interleaved fixtures exposed a Core Audio channel-map stride problem. A reusable same-rate planar layout stage corrected it; all six rate/layout cases then passed without weakening the expected channel values.
- `.build/ffmpeg/bin/ffmpeg -buildconf` confirmed AAC, tee, FIFO, FLV, MP4/Matroska and the existing audio conversion filters. No FFmpeg component/configuration change was needed.
- Fixture creation: `/opt/homebrew/bin/ffmpeg -hide_banner -nostdin -y -f lavfi -i color=c=black:s=320x180:r=30:d=1 -an -c:v h264_videotoolbox -f flv .build/audio-fixture.flv`. The **bundled minimal FFmpeg** then accepted the production `ffmpegArguments` against that video and native generated stereo PCM for both MP4 and MKV, including filenames with spaces, `|` and `'`. Both outputs were nonempty; each invocation exited zero. Logs showed one H.264 copy plus AAC 160/320 kb/s encodes. The essential Both-mode arguments were:

```text
-map 0:v -map 1:a -map 1:a -c:v copy -c:a aac
-b:a:0 160k -b:a:1 320k -flags:a +global_header -shortest -f tee
[f=mp4:movflags=+hybrid_fragmented:select=\'v:0,a:1\']RECORDING|
[f=fifo:onfail=ignore:fifo_format=flv:queue_size=120:drop_pkts_on_overflow=1:attempt_recovery=1:recover_any_error=1:recovery_wait_time=1:restart_with_keyframe=1:select=\'v:0,a:0\']STREAM
```

- `python3 scripts/build-app.py --identity -` passed (local ad-hoc signing, no `--install`; the SSH login keychain is locked). `StreamApp.app/Contents/MacOS/StreamApp --ui-smoke` and `--settings-smoke` each printed `StreamApp ready — idle; no capture started` and stayed alive for a five-second launch check. These modes are persistent inspection windows, not self-exiting tests; a Python subprocess wrapper terminated only its own exact child PID after each check.

Unverified: physical multichannel-interface delivery, Bluetooth/default-route warning transitions, physical disconnect/reconnect and runtime-error recovery, camera/interface clap sync at maximum offsets, actual Ableton main/cue routing, AAC decoded true peaks, provider delivery, and multi-hour independent-clock behavior. Synthetic rejoin tests establish mixer timing, not hardware recovery. The optional additional instrument/loopback source is **not implemented**; neither drift correction nor isolated recording tracks are claimed.

## Merged audio audit repairs — 2026-10-24

The merged candidate reserves lookahead for configured negative offsets even when a source starts disabled, and retains mic/SCK/reference capture until the existing bounded audio/Privacy shield drain finishes. The writer's PCM delay ring, frozen audio target and parent-owned FFmpeg timestamp preservation remain intact; no new polling was introduced.

Verified on `btc-mbp14` in `~/src/streamapp-work/merged`:

- `swift build` passed (2.84 s).
- Recreated `.build/audio-fixture.flv` with `/opt/homebrew/bin/ffmpeg -hide_banner -nostdin -y -f lavfi -i color=c=black:s=320x180:r=30:d=1 -an -c:v h264_videotoolbox -f flv .build/audio-fixture.flv`.
- `STREAMAPP_FFMPEG_PATH="$PWD/.build/ffmpeg/bin/ffmpeg" STREAMAPP_AUDIO_FIXTURE_VIDEO="$PWD/.build/audio-fixture.flv" swift test` passed **108 tests in 20 suites**, zero failures (3.920 s). New regressions exercise initially disabled advanced mic/app sources, stable 600 ms playout and 26-packet video queue after live enable, and real post-stop samples covering the final advanced interval with both zero and three-second privacy delays.
- `python3 scripts/build-app.py --identity -` passed; no installation.
- `StreamApp.app/Contents/MacOS/StreamApp --smoke /tmp/x` passed and exited zero, including clean stop/restart.
- `StreamApp.app/Contents/MacOS/StreamApp --smoke /tmp/y --privacy-shield` passed and exited zero, including delayed-tail stop/restart.

These are synthetic/pure-logic checks, not physical mic/interface/SCK capture qualification at −500 ms. Hardware tail-content and live device-enable behavior remain unverified.

## Integrated candidate and timestamp preservation — 2026-10-24

- Webcam placement, Privacy shield, music-production audio and the encoder/session-activity changes were merged into one tree. In a Mac clone of that tree, `swift test` passed 108 tests in 20 suites. An ad-hoc bundle (not installed) passed `--smoke` and `--smoke --smoke-stage-seconds 2 --privacy-shield`. `verify-media.py` decoded all four MP4s with exit 0 and no errors; ffprobe showed audio and video starting at 0 with durations within 16 ms.
- `-copyts` throwaway check: H.264 in an FLV whose first packet is at 1.2 s, muxed with zero-based PCM. Default arguments moved video to 0 in MP4/Matroska (0.021 s in FLV), putting it 1.2 s ahead of audio. With `-copyts`, Matroska video started at 1.200 s and FLV at 1.221 s. MP4 held the first frame from 0 and its second packet was at 1.254 s. Audio started at 0 in every output.
- `PrivacyScanner` hides the whole recognized line when Vision cannot return a box for a detected substring; previously that detection was dropped. This is a code change without a separate fixture.
- Real-screen check of the installed app (`--bench --privacy-shield`, 10 s, main display, TextEdit showing fake AWS/OpenAI keys at 32 pt). Frames were extracted at 5 fps and read with Vision accurate OCR. The AKIA key was pixellated from the first frame. The `aws_secret_access_key` value and the `sk-proj-` key stayed readable for the 0.8 s the window was in front. Cause: fast OCR returned `aws_sec ret_access_key` and its value as separate observations, and read TextEdit's spell-check dots as periods (`s.k-p.ro.i-Q2xh…`). `\bsecret` also could not match inside `aws_secret_access_key`.
- Fix: credential keywords now match inside identifiers, and an observation ending in a credential label also hides the nearest observation to its right on the same row. An offline harness (throwaway) drew eight `.env`/JSON/shell lines in Menlo, ran the scanner's fast-OCR settings and the shipped detector, and applied the same-row rule. It covered 1920×1080 at 35 px and 15 px, and 3024×1964 at 26 px. Every secret value was hidden in all three, and the prose control line was not. With imitation spell-check dots, Vision returned no text for most lines, and `DB PASSWORD=` was read as `DB PASSWORD-`. Those cases stay unredacted. `swift test`: 111 tests passed. The real-screen run was not repeated after the fix.

## Video Effects, shrinking redactions, wrapped secrets, censor style — 2026-10-24

- **Video Effects:** a throwaway bundle called `AVCaptureDevice.showSystemUserInterface(.videoEffects)` with no camera session open, and no panel appeared. The button sat in Capture → Camera, which is disabled while a session or preview runs, so it was clickable only when macOS would ignore it. It moved to Settings → Layout → Scene and is enabled from `StudioEngine.cameraOpen`. In `--settings-smoke` (demo, camera off), the Layout row showed **Open…** disabled with the availability caption, and Capture → Camera showed only Camera and Mirror. The panel opening with a live camera was not checked.
- **Shrinking coverage:** `redactionsHoldEachDetectionAndShrinkAfterMovement` drives a detection that moves (a two-second trail covering both positions, then only the new one), text shrinking inside existing coverage (no generation bump, box shrinks after the hold) and expiry.
- **Wrapped secrets:** a throwaway Vision test rendered a dark-terminal `cat .env` in Menlo at 18, 22, 26 and 30 pt, with a long `typesafe_api_key=` hex value and an `OPENROUTER_API_KEY=sk-or-v1-…` value wrapped at the right edge, followed by `NODE_ENV=production`. It ran `PrivacyScanner.recognize`. Before the continuation rule accepted OCR-inserted spaces, fast OCR read wrapped lines as `314dd2e2f 204544170ab` and `56789abcd2f e583c291`, and they stayed visible. After the change, every wrapped continuation line was covered at all four sizes, and `NODE_ENV=production` was not. At 30 pt, fast OCR read the first line as `typesaf e_api key-7f 3a9c…` (`=` as `-`, spaces inside the hex), so that first line stayed unredacted, as it was before this change.
- **Censor style:** `everyCensorStyleHidesTheSourceCompletely` renders each style (solid, rounded, striped) in near-black, white and red over random noise and over white. Inside the cover, the pixels are identical for both sources and differ from the noise.
- Mac clone: `swift test` passed 113 tests in 20 suites. An ad-hoc bundle passed `--smoke --smoke-stage-seconds 2 --privacy-shield`. `--settings-smoke` Output → Privacy shield showed Censor style (Solid bar) and Censor color (0.06 grey) with reset buttons, disabled while the shield is off. A real-screen moving-window recording was not made.

## Render-late privacy shield — 2026-10-24

- **Diagnosis** of a user recording (`StreamApp-2026-10-24T01-39-35Z-39B6A955.mp4`, previous build). Video froze because `PrivacyDelayQueue` dropped packets and waited for keyframes when coverage changed. Bars far wider than the text came from width-proportional padding, merging across rows and screen-space hold trails left at old window positions. The secret cut at its underscore because only the value (capture group 1) was matched, and fast OCR read `_` as a space and `=` as `-`.
- **Mac clone, final candidate:** `swift test` passed **125 tests in 21 suites**. They cover:
  - owner-local placement during drags without trails or guards;
  - carry through a move for as long as it lasts, dropped once a still window's pixels change;
  - the lifecycle guard: a window leaving the list stays covered at its scanned position, and every changed pixel is guarded until a later scan ends the transition;
  - a scan bracket wider than the normal spacing guarding what only its interior showed;
  - idle preview covering changes since the newest scan and never showing a screen its plan does not describe;
  - exact-first ownership;
  - change, overrun and pool-gap guards;
  - capture-time history and stale-epoch rejection;
  - delayed camera;
  - every censor style hiding an interior box and one clipped at the source corner;
  - whole-assignment, OCR-misread, label and wrap detection;
  - the band OCR path:
    - Vision band reads must place a rendered credential where a whole-image read does (this confirmed region-relative results are projected correctly);
    - bands must never cut cached text and must fall back to a whole-image read when too large;
    - band growth must terminate when rounding leaves a reached boundary "near" text.
- **Release audit** (`omp-audit`, auditor, GPT-6.1 Sol xhigh): two BLOCK verdicts, the initial audit and its one allowed recheck. All six findings were fixed afterwards. No further audit has passed this candidate, so the release boundary holds: it is not installed.
  - First audit:
    1. A failed scan between two clean scans left text shown only around it unguarded.
    2. After a geometry reset, idle preview showed the raw live screen with an empty plan. It now renders only the frame its plan describes.
    3. Band growth could reassign the same boundary forever. A Double simulation of the auditor's counterexample (text maxY 0.49999999999999994, change at y 560 of 1000) looped before the fix and ended at [0.376, 0.508] after it. Growth now requires a strict outward move.
  - Recheck:
    1. A slow (overrunning) scan widens the bracket the same way as a failure. The first fix's failure marker was replaced by one rule: a bracket wider than interval + 0.1 s guards every tile of its interior frames that differs from the later scan.
    2. Idle preview ignored changes since its newest scan, including during scan failures. It now guards tiles changed since that scan.
    3. Rounded covers clipped at the capture edge rounded away corners over detected text. The shape now extends past each source edge it touches.

  The new timeline, preview and censor-corner tests were not run against the old code.
- **Ad-hoc bundle, final candidate:** `--smoke --smoke-stage-seconds 2 --privacy-shield` printed `SMOKE PASS: live scenes, chat toggle, camera toggle, audio controls, clean stop and restart` (synthetic sources) on all three builds. `--settings-smoke` printed its ready marker on the pre-audit build. The caption, now reworded to 0.35 s, was not inspected visually. `strings` found no probe markers in the pre-audit binary.
- **Real-screen e2e** on the MBP's main display (1662×1080 capture, a dark text-dense chat app in front). `--bench --bench-seconds 14 --bench-no-system-audio --privacy-shield`, plus a throwaway window showing a fake `.env` (`typesafe_api_key=` with a wrapped hex value, `OPENROUTER_API_KEY=sk-or-v1-…`, `aws_secret_access_key = …`, `NODE_ENV=production`). The window is still for 2 s, dragged for 3 s, still for 1.5 s, dragged back fast, still, then closed. Each run checks:
  - leaks: every one of the 421 decoded frames, OCR-scanned for any secret fragment;
  - coverage: the fraction of non-black pixels at the censor luma, sampled at 2 fps;
  - CPU: 12 `ps` samples.

  Each MP4 had 421 packets over 14.02 s, with no gap above 40 ms after the first-frame offset.
  - **Teardown leak (fixed):** one full scan of an earlier build found the whole window uncovered in one frame at close. It was listed as gone while drawn at a new position. The lifecycle guard fixed it.
  - **Fast-drag leak (fixed):** with a one-scan carry limit, 2 of 8 runs leaked the `aws_secret_access_key` rows for one frame mid-drag. A probe showed fast OCR missed those rows in two consecutive mid-drag scans; the carry dropped them at the second, which was itself the rendered frame. With carry for the whole move: 0 leaks in 5 + 3 + 3 + 1 + 1 + 1 full runs. The last three were on probe-free builds before the audit, after the first fixes, and after the recheck fixes:

    | Run | Cover median | Cover p90 | CPU median |
    |---|---|---|---|
    | After first fixes | 16.7% | 20.8% | ~35.6% |
    | After recheck fixes | 16.1% | 21.3% | ~40.5% |

    Contact sheets showed covered rows mid-drag, no trails and no whole-screen cover. During the final run's fast drag back, one frame showed a solid guard over the window and part of the adjacent chat text.
  - **Coverage:** this screen's dark UI puts 14.5% median / 14.8% p90 of pixels in the censor luma range with the shield off. Shielded: 15.9–18.5% median, 20.6–23.0% p90. Teardown spikes of 0.53–0.88 lasted one 0.5 s sample, and none appeared in the last three runs (max 0.26). Contact sheets showed covers on the window's rows during and after drags with no trails. Some spill remains where OCR merges a window row with adjacent background text.
  - **CPU** (median of 12 samples): shield off 12.6–13.4%.

    | Build | CPU median |
    |---|---|
    | Whole-image OCR at 5 Hz | ~45% |
    | Shield pipeline with Vision stubbed out (attribution only) | ~22% |
    | Band OCR at 5 Hz | ~40% |
    | Band OCR at 4 Hz, final | 35–43% |

    The agreed gate (shield off +15 points, about 28%) **was not met**. Every scan sees changed pixels: the menu-bar clock and extras, a blinking caret, and the capture's bottom 8 rows, which differ at scattered x in every frame (cause not established). Band reads take 15–65 ms (avg ~44) against ~82 ms for a whole image, because Vision has a fixed cost per request. Window drags take whole-image reads by design.
  - **Rejected experiment:** a pixel-anchored tracker (`PrivacyTracker`) also had 0 leaks, but covered 26% median / 40.5% p90 of the frame with drag trails at 48.6% CPU. Its first cut covered 99.5% of the screen because accurate-OCR model compilation never finished. It was removed.
  - An earlier probe measured fast OCR at 33–122 ms per scan, with results ready 40–146 ms after capture, within the 0.5 s delay. Before guards were capped at eight, 100–140 guard rects made composition take ~70 ms, and the session stopped with "Video timing fell behind".
- **Not verified:** camera history with a physical camera (bench and smoke disable it or use synthetic sources); physical camera/audio lip-sync under the delay; streaming output; long-session memory; other screen contents, scales or displays.

## Privacy shield accuracy and atlas rescans — 2026-10-24

- **Underscore cut (user report):** a recording from the installed (previous) build showed a `typesafe_api_key` cover ending at the `_`, with the rest of the value visible. Fast OCR reads `_` as a space and `=` as `-`, which ended the credential match inside its value. The detector now hides a credential from its start to the end of its OCR line, also matching confusion-tolerant variants (symbols read as token characters; look-alike digits read as letters, without whitespace). `hidesAnOCRLineFromItsCredentialToTheEnd` includes a first-row key with `_` before its hex tail, and the same key ending at `_`.
- **Offline accuracy harness** (throwaway, removed): 80 rendered `.env`-style cases across fonts, sizes and wraps, scanned with the shipped fast-OCR settings and detector and then compared cell by cell. Uncovered secret cells went from 409 to 11; 3 of 80 cases still leak. Every remaining leak is the last ≤ 5 characters of the wrapped `OPENROUTER_API_KEY` value on its own row (JetBrains Mono, 16 px), which fast OCR returns no text for. Changing `VNRecognizeTextRequest.revision` (1/2/3) changed neither accuracy nor CPU (~47–49 ms per whole-image call).
- **Correction:** the earlier per-frame "23.5 ms" `changedTiles` overhead was a debug-build figure. In release, the row-first comparison takes 0.12 ms on an identical 1662×1080 frame (0.78 ms before the change).
- **Atlas rescans:** in the release build on the MBP, still-screen scans went from ~35–45 ms (one request per band) to ~6–20 ms wall (one request for all regions). Reusing a `VNRecognizeTextRequest` or `VNSequenceRequestHandler` saved nothing in a throwaway test: Vision creates its recognizer on every perform. Rigid window-move reuse was built and removed: on this scaled capture (1512×982 points to 1662×1080 pixels) the pixel-exact move check never matched in a probe, and tolerance matching was rejected as unsafe for low-contrast text.
- **Mac clone, final candidate:** `swift test` passed 127 tests in 21 suites, including atlas reads placing two rendered credentials where a whole-image read does, region growth/containment, outline strips not covering a window's centre, the 60% fallback and growth termination after rounding. Release bundle built without `--install`.
- **Real-screen e2e** (same harness as above: `--bench --bench-seconds 14 --bench-no-system-audio --privacy-shield`, MBP main display, dark text-dense chat app in front). The throwaway window (960×260, MesloLGS NF 18) shows a fake `typesafe_api_key=tsk_…N2_97252…` whose `_` and hex tail sit on the first visual row before it wraps, plus `OPENROUTER_API_KEY`, `aws_secret_access_key` and `NODE_ENV=production`. The leak scan OCRs every decoded frame for every 5-character window of each secret value; its self-test reads all three rendered secret rows.
  - Positive control, shield off: the key rows were found in ~110 frames.
  - Shield on, drag timeline: 0 leaking frames of 421 on each of two builds (probe and final), no video gap above 40 ms after the first-frame offset. Pixels at the censor luma (2 fps samples): 0% before the window opens and after it closes, so this desktop had none of its own; median 5.1%, p90 5.8%, max 19.3% (one sample) of visible pixels overall. Contact sheet and full-resolution crops showed every secret row covered past the `_`, mid-drag and still, no trails and no whole-screen cover; on the `aws_secret_access_key` row the cover spilled left of the window onto adjacent chat text.
  - Shield on, still window (same window, no drag): 0 leaking frames of 421.
  - **CPU** (median of 12 `ps` samples, final build): shield off, still window 13.0%; shield on, still window 28.5%; shield on, drag timeline 30.6%. Previous candidate: 35–43%. The ≤ 26% target was not met; still-window use sits at the 28% ceiling and drags exceed it. A probe build attributed the remaining cost to OCR of real screen changes: every scan saw changed pixels (another app's live output, clock, caret), with small-region scans at ~10–20 ms wall each and dragged-window scans (up to ~50% of the image) at ~40–50 ms. In a `sample` profile of the drag run, Vision text recognition was ~18 of ~29 sampled on-CPU points of a core; the scanner's own work ~4, capture ~3, composition ~3.
- Ad-hoc release bundle: `--smoke --smoke-stage-seconds 2 --privacy-shield` printed `SMOKE PASS: live scenes, chat toggle, camera toggle, audio controls, clean stop and restart`.
- Real-screen recordings, frames and screenshots were deleted after these checks. The candidate was not installed: a release audit has not passed it.

## Privacy shield tracking, capture format, pointer splits — 2026-10-24

- **Pointer split (user report: "the area under the cursor gets uncensored"):** harness scenarios draw an arrow pointer over the secret rows, either sweeping (`cursor-arrow-sweep`) or resting and jumping every 20 frames (`cursor-arrow-rest`, `cursor-arrow-bare-rest` over bare `ghp_`/`sk-proj`/`xoxb` tokens). Before the fix, `cursor-arrow-rest` leaked 16 frames (32 character-frames): the pointer split OCR's row into `OPENROUTER_API_KEY=sk-or-v1-a` and the rest of the value, and only the two pieces were covered, leaving the cells under the pointer gap (x 627–642) uncovered. A line hidden after its label or a credential line it continues now spans from its anchor's right edge. After the fix, all four pointer scenarios leaked 0 frames, with benign over-cover of 3.35%, 0.59%, 0% (`bare`, no pointer) and 1.60%. `SensitiveTextDetectorTests` gained a pointer-split case; the existing label/continuation expectations now include the bridged gap.
- **Compositor crash (found in the e2e drag bench, two reports in `~/Library/Logs/DiagnosticReports`):** `EXC_BREAKPOINT` on `streamapp.compositor`, "Double value cannot be converted to Int32 because it is either infinite or NaN" in `PrivacyMotionTracker.place`. `ScanResult.carry` shrank a carried rectangle by 2 pixels vertically; a sliver under 4 pixels tall (clipped by a front window or the capture edge) became `CGRect.null`, whose infinite origin then trapped. A first fix (carry the found rectangle ∩ its visible part) made a test of a front window leaving a 1-row sliver, then a third scan, pass; against the old code that test crashed the test process. The release audit then found that storing only the sliver loses the row once the front window moves away (below), so carry now keeps the whole found row; the test became `carryKeepsTheWholeFoundRowWhileAFrontWindowLeavesASliver`, which also expects the full row back after the front window leaves. It was not re-run against the original code.
- **Tracker cost:** the sparse signature's rows, columns and values are built once with each patch, not per search. Instrumentation of the drag bench showed moving windows never matched beyond the nearest 8 rows, so they search only that radius. A window's horizontal registration probe runs once per frame, and a failed probe is reused rather than repeated per detection. All instrumentation was removed; no `ZZ` markers remain in sources or tests.
- **420f capture:** with the shield on, both capture streams deliver 420f, and the history pool copies planes exactly (no CIContext conversion). A shield-on and a shield-off frame of the same screen matched in a visual comparison and in mean colour over a reference region.
- **Vision probes:** fast recognition runs on the CPU only. Accurate recognition costs about twice the CPU. Vision reloads its recognizer on every request regardless of request reuse. Vision settings are unchanged.
- **Release audit `PrivacyShieldCursor`: BLOCK, five findings, all addressed in this candidate:**
  - *F5, carry stores a sliver:* carry keeps the whole found row with its patch offset (test above).
  - *F4, neighbour-origin covers clipped to the current bounds:* each candidate origin is clipped against the window as listed at that origin. `unresolvedNeighborOriginIsClippedToTheWindowListedThere` failed before the fix and passes after.
  - *F1, failed or overrunning scan unguarded; F3, window moving and closing unguarded:* changed-tile guards (architecture: "Changed-tile guards") fire only when evidence is missing: no predecessor, no successor by the deadline, a bracket wider than 0.35 s, or a sensitive window gone from a later list. Tests: `missingOrOverWideEvidenceGuardsWhatNoScanRead`, `aSensitiveWindowLeavingTheListGuardsWhatChangedAnywhere`. `guardMaskCoversExactlyItsTilesHowEverFragmented` renders more than 140 checkerboard tiles on a 410×200 source: every tile is the censor colour (±1), every other pixel is unchanged.
  - *F2, idle preview shows new text indefinitely while scans fail:* once the newest scan is more than 0.5 s old on the host clock, idle preview guards everything changed since it. `idlePreviewGuardsChangesOnlyOnceItsNewestScanPassesTheDeadline` replaces the earlier idle-preview test.
- **Harness** (`PrivacyEvaluation`, replacement policy, 58 scenarios, guards counted as covers): most rows are identical to the run before the guards. Guarded scenarios had these benign over-cover rates: `thrown-scan` 6.81%, `nil-scan` 2.02%, `early-owner-gone` 3.51%, deadline-after 12.47%. `scroll-phase-1`…`-7` benign rose (`scroll-phase-7` 8.16% → 10.15%). `wide-interior-only` fell from 2376 to 1474 leaking character-frames (22 frames, benign 25.11%). A debug print showed that the remaining cells are a metric artifact: each leaking cell's box reaches 4 pixels into an unchanged tile above it, which holds no new text. The other leaks are unchanged known limits: `scroll-pixel-fast` 3, `scroll-reversal` 2, `flash-1`/`-2`/`-3` 1/2/3 frames (text shown for 1–3 frames between on-time scans).
- **Release audit recheck `PrivacyShieldCursorRecheck` (candidate sha 03b112c2…): BLOCK, two findings, both fixed afterwards.** In both, the window list clipped a found cover, which exposed text that the dense check had just verified in the shown pixels:
  - a window listed 10 rows above its pixels clipped the cover's last rows;
  - a front window listed before it was drawn removed the cover entirely.

  Found and carried placements are now clipped only to the capture bounds; unresolved candidates keep owner and front-window clipping. `aSecretFoundBetweenScansIsCoveredWhereverTheListPutsWindows` (both counterexamples) and `foundAndCarriedCoversFollowThePixelsNotAFrontWindowListedOverThem` (which replaces the sliver test) failed against the recheck candidate with 3 issues and pass with the fix. Effect on the full harness: no leak or benign-cover count changed. Mean covered area rose by at most 0.0005 of the frame (`scroll-repeated`), and `two-windows` max rectangles fell from 7 to 6.
- **Mac clone, final:** `swift test` passed **136 tests in 23 suites**. On the rebuilt bundle, the privacy-shield smoke printed `SMOKE PASS` and the three UI smokes printed `StreamApp ready — idle; no capture started`.
- **Mac clone, recheck candidate:** `swift test` passed **135 tests in 23 suites**. The release bundle was built without `--install`. `--smoke --smoke-stage-seconds 2 --privacy-shield` printed `SMOKE PASS: live scenes, chat toggle, camera toggle, audio controls, clean stop and restart`. `--ui-smoke`, `--settings-smoke` and `--onboarding-smoke` each printed `StreamApp ready — idle; no capture started` and were stopped after 120 s. Their windows were not inspected visually.
- **Real-screen e2e** (same bench and throwaway `.env` window as the previous section): 9 interleaved runs (shield off, still, drag) × 3 all logged `stopped`. No new crash report appeared. The leak scan of a drag recording found 0 leaking frames of 421, and no gap above 40 ms after the first-frame offset (start offset 0.054 s).
  - A temporary stderr probe in `unreadReference` (since removed) counted guarded frames. One drag run and one still run each guarded 7 frames, all of them consecutive frames right after the window closed (window gone from the successor's list). No frame during the drag or the still period was guarded.
  - Cover share (pixels at the censor luma, 2 fps samples of a drag recording): median 4.9%, p90 9.8%, max 10.0%.
  - Still frames cover exactly the secret rows; `$ cat .env` and `NODE_ENV=production` stay visible. Mid-drag frames cover about one text row more above and below. That matches the unresolved-placement row padding (`uncertainRows`, one row pitch); no guard fired then. The attribution was not instrumented.
- **CPU** (`ps` %CPU, 12 samples per run; means of 3 interleaved reps; load average 4–5 from the user's own apps):

  | Run | Shield off | Shield on, still | Shield on, drag |
  |---|---|---|---|
  | Rep 1 | 11.6% | 22.7% | 27.1% |
  | Rep 2 | 11.1% | 20.6% | 25.8% |
  | Rep 3 | 10.7% | 22.1% | 26.3% |

  Raw samples, rep 1–3:
  - Off: `17.7 12.8 8.9 10.6 7.4 10.9 9.9 12.7 12.2 11.5 12.4 11.9`; `14.2 12.4 9.4 9.7 8.8 10.9 10.2 12.9 11.4 11.5 11.2 10.1`; `15.2 10.1 7.7 9.5 9.3 10.2 8.9 12.8 10.9 12.1 9.5 11.7`.
  - Still: `24.5 21.6 32.8 17.3 19.7 21.1 22.4 21.9 17.8 21.8 19.3 32.2`; `22.2 14.8 32.6 13.9 17.1 13.3 20.2 19.8 25 20.8 21.2 25.7`; `18.5 18.9 29.1 19.9 17.2 22.4 23.9 22.9 22.5 23.7 23 23.3`.
  - Drag: `17.1 21.6 35.5 18.8 32.1 28.6 35.7 23.4 30.9 32.7 21.5 27.8`; `15.7 18 34.2 18.5 28.9 28.2 31.3 20.5 32.4 32.7 22.9 25.7`; `18.2 22.4 33.1 16.9 28.9 29.3 28.4 26.8 32.5 27.2 28.1 23.6`.

  The build before the guards measured 22.1–22.6% still and 25.5–26.7% drag under similar load. The previous section's build measured 28.5% still and 30.6% drag.
- **Final build, drag run:** a drag run logged `stopped` with no new crash report. The leak scan found 0 leaking frames of 421 (start offset 0.054 s). Cover share was median 4.9%, p90 9.4%, max 9.8%. CPU was 25.7% (mean of `23.6 16.8 19 21 42.6 24.2 35 25 24.7 33.9 20 22.4`).
- Real-screen recordings, frames and screenshots were deleted after these checks. The candidate is not installed: the one allowed recheck returned BLOCK, so installing it needs another audit.

