# Verification — 2026-09-20

## Menu preview, Twitch test mode and fitted desktop

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
