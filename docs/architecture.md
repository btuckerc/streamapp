# Implementation and research decisions

## Product surface

StreamApp is an AppKit `NSStatusItem` + `NSPopover` hosting SwiftUI cards and a separate settings window. The presets are **Desktop** and **Full Camera**, with independent chat rendering, chat side/width, webcam corner/size, device selection and live audio controls. Existing scene identifiers remain unchanged in saved settings; missing configuration fields decode with defaults rather than discarding older settings.

The Usage Bar reference was `../usage-bar/Sources/CodexBar/`: `UsageMenuCardLayout.swift` supplies the compact 20pt horizontal-padding/section rhythm; `StatusItemController+MenuPresentation.swift` illustrates native SwiftUI hosting and measured layouts; `StatusItemController+MenuTracking.swift` documents why frequent meter updates should not rebuild a synchronously tracking NSMenu. StreamApp uses a popover and one stable status item. Meters sample at 5 Hz; output health samples at 1 Hz. Preview presentation runs independently of SwiftUI updates.

Popover placement is owned by AppKit: one retained hosting controller is sized and laid out before `show(relativeTo:of:preferredEdge:)`. There is no `popoverDidShow` frame correction; that previous correction visibly moved the already-open window. Animation is disabled for immediate menu-like presentation (Apple documents `animates` as a hint, not a guarantee). Dictation's `src-tauri/src/lib.rs` attaches its Tauri menu with `show_menu_on_left_click(true)`; Usage Bar's `StatusItemController.swift` attaches `NSMenu` to the status item. Neither is evidence for manually moving an already-shown popover. StreamApp retains NSPopover for live sliders/meters, using [AppKit anchoring](https://developer.apple.com/documentation/appkit/nspopover/show(relativeto:of:preferrededge:)) and [animation policy](https://developer.apple.com/documentation/appkit/nspopover/animates).

Source/device/output settings lock during a session. Scene selection, chat geometry, webcam enable/position, gains and mutes remain live. Start does not silently grant permissions or substitute a synthetic input for a missing real source. Broadcasting requires explicit confirmation; stop stays visible outside scrolling controls.

The application-defined popover closes on outside clicks and Escape. Status-item clicks are excluded from local/global dismissal monitors so the button's action toggles once rather than closing on mouse-down and reopening on mouse-up.

**Fit desktop to 16:9** journals the previous Dock tile size in a private machine-local file, measures the bottom Dock's reserved height after adjustment, and crops the selected whole-display capture to its upper 16:9 region. It rejects incompatible arrangements and refuses stale geometry. Disabling restores the saved size only if it still matches StreamApp's applied setting; a newer external setting wins.

Twitch bandwidth tests use the documented `bandwidthtest=true` query only on recognized Twitch ingest hosts. Both test and live starts require confirmation. Twitch Inspector, not local FFmpeg progress, establishes remote delivery quality.

Dictation's `../dictation/docs/onboarding.md` supplied the Connect → Prepare → Try it structure, explicit permission recovery and optional real trial. StreamApp's trial copies settings and forces local recording with streaming disabled; live trial changes preserve that isolation. One task owns stop/finalization, including close during device startup. Onboarding completion is separate from the existing Codable settings schema.

Twitch setup uses its own dashboard and a Keychain stream key. No OAuth client registration exists in this repository, so it does not pretend to provide OAuth account linking. The secure global ingest is prefilled only on Configure Twitch; setup itself sends no media to Twitch. Twitch chat still uses the existing anglbot SSE bridge.

## Media path

```text
ScreenCaptureKit ─── latest-frame slot ─┐
AVCapture camera ─── latest-frame slot ─┼─ Metal/CoreImage composition
Cached local WKWebView chat snapshot ──┘          │
                                      VT encoder pixel-buffer pool
                                                 │
                                      hardware H.264, no B-frames
                                                 │
                                      libavformat timestamped FLV
                                                 │
Microphone + SCK audio → bounded native PCM mix → FFmpeg
                                                 ├─ Matroska recording
                                                 └─ bounded FIFO RTMP/RTMPS, reconnect
```

- `CaptureEngine.swift` owns main-actor lifecycle, authorization preflights and explicit device ownership. Capture callbacks use separate queues and replace bounded latest-frame slots, not an accumulating queue of frame tasks.
- `FrameRenderer.swift` composes on its own serial queue. Immutable pooled frames are reused when inputs/configuration have not changed; the 30 Hz encoder clock continues. Full raw video never crosses a process pipe. `GPUPreview.swift` retains only the latest composed IOSurface for program preview, or the captured camera buffer for an opt-in webcam view. Metal/CoreImage scales it into the drawable without CPU readback or repeating scene composition. One GPU submission is allowed in flight; rendering never waits for the preview. Hidden/occluded/offscreen views pause and release the mailbox. Diagnostic PNG export is an explicit one-off, not a presentation path.
- `SceneTransition.swift` interpolates camera, desktop and chat rectangles over 350 ms with smoothstep easing. Interruptions retarget from the visible geometry, not a previous endpoint; completion settles to exact target values. Reduce Motion cuts. Full Camera retains sharp full-frame camera video; only the right chat panel plus a 48px kernel halo is cropped, downsampled to ¼ resolution, Gaussian-blurred on Metal and tinted. Text is composited afterward. There is no second encoder, full-frame blur or CPU blur path.
- The desktop webcam has rounded alpha clipping and a quiet black shadow, replacing the solid rectangular border. Core Image generates the rounded mask and blurs only its alpha silhouette; the camera remains sharp. Filter graphs are retained until geometry changes; no CPU mask rasterization or camera readback is introduced. Radius and shadow fade with the existing scene morph; settled Full Camera bypasses both. This follows [Apple's depth/material guidance](https://developer.apple.com/design/human-interface-guidelines/materials), but is encoded-frame styling, not actual AppKit Liquid Glass or refraction.
- `VideoEncoder.swift` requires hardware VideoToolbox H.264, three in-flight submissions and a six-buffer allocation threshold. `EncodedMuxer` preserves PTS/DTS and writes only compressed packets, with finite backpressure deadlines.
- `AudioMixer.swift` uses fixed-capacity stereo rings aligned to the host clock. AVAudioConverter handles interleaved/noninterleaved input and sample-rate conversion; a 100 ms playout allowance accommodates capture delivery. Gains/mutes are applied before mixing, absent/disabled sources are silent, late audio is discarded rather than replayed, and mixed peaks are bounded. There is no speaker-monitoring path.
- Microphone compression uses stereo-linked detection, a −18 dBFS threshold, 3:1 ratio, 6 dB soft knee, 10 ms attack and 150 ms release; no makeup gain or AGC. Nonlinear gain calculations run at 1 kHz, with sample-smoothed gain. A linked instant-attack/releasing final limiter caps PCM sample peaks near −1 dBFS without extra latency. This is not an oversampled true-peak limiter; AAC reconstruction may exceed the PCM ceiling.
- Channel meters observe post-gain/mute/processing sample peaks; the output meter observes the final protected mix. Peaks accumulate until one atomic UI read, so short transients survive 5 Hz polling. The UI maps −60…0 dBFS logarithmically and labels silence; gain reduction is reported separately. Speaker playback volume, integrated LUFS and dBFS are different quantities.
- Visible-menu audio checks reuse the mixer with a bounded 20 ms pull clock. Video defaults Off. Layout runs the existing compositor without an encoder at 30 Hz with a four-buffer allocation ceiling; Webcam uses the latest camera frame directly. A generation-guarded serialized transition releases preview resources before recording and on menu close. No recording or broadcast starts; configured chat may connect when Layout is enabled. Gain/mute changes reconfigure the mixer without restarting devices. Off cancels queued camera startup before teardown.
- `MediaOutput.swift` uses private 0700 temporary directories and 0600 named FIFOs, avoiding fragile inherited-FD assumptions or global `dup2` changes in the GUI process. PCM writes preserve partial-write boundaries and fail on a stalled consumer rather than silently dropping bytes. FFmpeg stream-copies H.264 and encodes only AAC. RTMP can reconnect independently of the local recording.
- FFmpeg emits machine-readable progress once per second through a private pipe. Recording confidence uses advancing output timestamps/frame counts and actual file size, not process launch or preview activity. No progress for three seconds after output begins is reported as stalled; startup gets ten seconds. Broadcast-only progress never claims remote delivery. Readers remain open through output finalization.
- Stop releases capture, drains VideoToolbox, closes media transport, and waits for FFmpeg to finalize. Failure states are surfaced, not silently downgraded to a fake or software path.

## Chat, settings and privacy

`Chat.swift` loads bundled HTML, consumes SSE through an ephemeral native URLSession, and passes structured message values into an owned renderer. It never loads arbitrary remote HTML. `SSEDecoder` preserves blank-line event boundaries and bounds line/event size. Text uses DOM `textContent`; user colors are restricted to hex RGB. The rendered list is bounded to 100 messages.

Snapshotting is invalidation-driven, one request in flight and at most 30 Hz. A coalesced one-shot timer runs only when dirty; clean chat has no polling timer. Identical connection statuses do not mutate the DOM. Retina backing scale is measured so snapshots match the requested output width ×1080 pixels. DOM/font/resize/CSS animation invalidations are supported for this owned renderer; this is not a general-purpose browser source with arbitrary canvas/video paint detection.

Chat stays alive across layout switches when enabled. Disabling Render chat stops and releases WebKit/SSE, clears its image and skips panel/blur composition; the desktop expands to full width. The macOS WKWebView backing must have `drawsBackground=false` as well as transparent CSS/under-page color. Camera-off clears the image immediately; leaving Desktop preserves only its last screen frame for the short exit morph, and returning restarts real screen capture.

Launching the app does not capture or enumerate private windows. Source listing and permission requests are explicit UI actions. No settings file contains the stream key; it is stored in Keychain only when requested. Raw FFmpeg stderr is never displayed or persisted because it can echo an RTMP key. This is a local non-sandboxed app; administrators can still inspect process arguments, including the FFmpeg destination. Do not mistake redacted UI logs for protection against privileged local inspection.

### Native annotations and exclusions

`AnnotationOverlay.swift` uses a transparent floating AppKit canvas and a separate private toolbar. Retained pressure-width paths update only dirty regions; storage is bounded to 512 strokes / 100,000 points. Pen, highlighter, eraser, undo and clear require no WebKit, polling loop or third-party drawing SDK. **Control–Option–Command–D** toggles drawing; Escape releases pointer input while preserving ink. The extra Control modifier avoids macOS's Option–Command–D Dock shortcut. Annotations apply to display capture in Desktop + Webcam, not single-window capture or Full Camera.

Drawing uses AppKit's plus crosshair through canvas cursor rectangles; leaving drawing restores the normal cursor. The menu's **Clear annotations** calls the same canvas clear operation as the private toolbar and works after Escape.

ScreenCaptureKit's [application filter with window exceptions](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(display:excludingapplications:exceptingwindows:)) excludes StreamApp itself and selected apps, then explicitly includes the canvas. Individual windows in otherwise included apps are excluded via the same exception list. The toolbar remains private. Filters are resolved at session start; refresh/restart after excluded apps reopen. App bundle rules persist; window IDs do not survive StreamApp relaunch. This is an app capture policy, not protection from other capture software or a system-wide confidentiality boundary.

### Drawing-engine decision — 2026-09-20

**Retain the working native overlay in this installed build; choose tldraw rather than expanding the custom implementation into a full editable-canvas engine.** tldraw wins the documented feature comparison, not a measured latency or subjective-user-preference contest. A production replacement requires a valid license and a verified native host; neither is implied by a successful browser demo.

| Evidence | Current native overlay | tldraw |
|---|---|---|
| Drawing | Pressure-width paths; no smoothing algorithm | [Documented smoothing/interpolation, real pen pressure and simulated mouse pressure](https://tldraw.dev/sdk-features/draw-shape) |
| Editing | Fixed ink, undo and clear; no redo/selection | [Selection, shape manipulation and history APIs](https://tldraw.dev/docs/editor); parent exercised drawing, selecting/moving and erasing in the official custom-UI demo |
| Eraser | Pixel eraser drawn with clear blending | The exercised default eraser removed a whole stroke; behavior is not interchangeable |
| Accessibility | Native toolbar buttons; no semantic navigation among strokes | [Documented shape announcements and keyboard navigation](https://tldraw.dev/sdk-features/accessibility); VoiceOver inside WKWebView remains untested |
| Public ink/private UI | Real recording verified the two-window capture boundary | [Custom UI is supported](https://tldraw.dev/examples/custom-ui), but `hideUi` alone does not remove the context menu; requires deliberate native-toolbar and transparent-host integration |
| Runtime/input | Actual installed drawing and recording exercised | No comparable WKWebView CPU/RAM/latency measurement or connected-Wacom pressure test; no performance winner claimed |

The browser exercise used `https://examples.tldraw.com/custom-ui/full` in an isolated managed browser, with synthetic strokes only; it was not a WKWebView or tablet test. The reviewed release reference is [v5.4.2](https://github.com/tldraw/tldraw/releases/tag/v5.4.2). tldraw is a React drawing SDK, not a Wacom driver: native window ownership, global shortcut, click-through, display coordinates and ScreenCaptureKit inclusion still belong to StreamApp. [Installation docs](https://tldraw.dev/installation) support bundled/self-hosted assets; the default CDN must not become a hidden offline dependency.

[Current licensing](https://tldraw.dev/community/license) requires a production key. The [free hobby license](https://tldraw.dev/get-a-license/hobby) is discretionary and retains the watermark, even for personal noncommercial use. [Pricing](https://tldraw.dev/pricing) is annual, value-based and quote-only; no public dollar price is listed. Watermark-free use needs a commercial/custom arrangement. The current [LicenseManager source](https://github.com/tldraw/tldraw/blob/main/packages/editor/src/lib/license/LicenseManager.ts) contains native-protocol license support, but that does not establish the terms or price for a bundled WKWebView application. Ask the vendor for the appropriate native license.

Offline key validation is not a guarantee of zero network activity: current source and [issue #10034](https://github.com/tldraw/tldraw/issues/10034) conflict with older documentation about telemetry for watermark-bearing production/hobby keys. Verify the exact SDK version and license before promising offline behavior. No license was requested, terms accepted, or tldraw code bundled. Migration still requires transparent WKWebView/capture verification, private controls, and hardware input qualification.

### Wacom configuration research

The separate `~/src/wacom` Tablet Companion now handles the connected Intuos BT S global leftmost ExpressKey. Direct AppleEvents to `com.wacom.wacomtablet` provide tablet identity, connection state, and preference flushing. The coordinator `com.wacom.TabletDriver` returned empty property replies on driver 6.4.14-1; the public SDK's raw ExpressKey route was not usable for this device. Neither result means the entire driver API is unavailable.

Controlled Center changes established the physical Button1 mapping and exact typed-XML shortcut representation. Companion Apply/Restore preserves the current preference document, changes only that global button's assignment fields, stages the driver's native restore file in its app-group preferences directory, and invokes Wacom Tablet Utility `--restart`. It flushes and checks imported state, retains a private restore point and pre-import backup, and refuses conflicting target-key changes. Apply → Restore → Apply was exercised with Center closed; other three keys remained Option, Control, and Command. This is a version-sensitive driver integration, not a public portable preferences API or driver-free input stack. Physical tablet-button event delivery still requires a hands-on press.

The [official macOS Device Kit](https://github.com/Wacom-Developer/wacom-device-kit-macos-api) documents AppleEvent operations. The [direct 6.4.14-1 installer](https://cdn.wacom.com/u/productsupport/drivers/mac/professional/WacomTablet_6.4.14-1.dmg) is obtainable without Center or an account. Its signed/notarized package has one mandatory payload, not a driver-only installation choice; it includes Center and background driver helpers. StreamApp itself includes no Wacom dependency, driver writes, or remapping service.

### Audio research boundary

[EBU R 128 s2](https://tech.ebu.ch/docs/r/r128s2.pdf) distinguishes playback environments and permits different streaming distribution loudness, including −20…−16 LUFS in its described adaptation case. It does not establish one universally enjoyable compressor preset or equate peak meters with loudness. The shipped preset is a conservative engineering choice, not a claim of LUFS normalization. Aggressive gating, automatic makeup/AGC, denoising and ducking are deliberately not added without evidence they improve this microphone/use case.

## External references

- [OBS knowledge base](https://obsproject.com/kb/) and [OBS architecture/API docs](https://obsproject.com/docs/): scenes as compositions of sources; per-source audio controls; reuse a mature media/output engine rather than inventing RTMP.
- [Ecamm](https://www.ecamm.com/): Mac-focused presentation/scene controls are a useful product comparison. StreamApp does not attempt its broader production suite.
- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) and [capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos): high-performance display/window/audio capture, bounded queues and explicit permissions.
- [Camera entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.camera) and [audio-input entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input): hardened-runtime device access still requires explicit per-app user consent.
- [FFmpeg legal guidance](https://ffmpeg.org/legal.html): exact configure flags determine licensing; bundling requires notices and applicable source/relinking obligations. The local Homebrew artifact enables GPL/version-3 components.
- [OBS Move Transition](https://github.com/exeldro/obs-move-transition): shared source geometry between scenes, used as a design reference; no plugin source was copied.
- [Core Image Gaussian blur](https://developer.apple.com/documentation/coreimage/cigaussianblur) and [CIContext](https://developer.apple.com/documentation/coreimage/cicontext): GPU composition and region-limited filtering.
- [Twitch video broadcast](https://dev.twitch.tv/docs/video-broadcast/), [ingest API](https://dev.twitch.tv/docs/video-broadcast/reference/), and [recommended ingest](https://help.twitch.tv/s/twitch-ingest-recommendation?language=en_US): dashboard keys, ingest selection and separate broadcast authorization.

## Release boundary

The root and installed `.app` are persistently Apple Development signed with bundled dependencies, not notarized public releases. Authorized live camera/microphone/system-audio tests passed on this laptop; see verification for exact scope. Provider/WAN broadcasting, multi-hour operation, clean-machine distribution and notarization remain unqualified. The earlier OBS comparison applies only to its controlled workload, not automatically to every scene/device. The installed app uses the existing local signing identity without exporting private keys; its pin stays out of Git.
