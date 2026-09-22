# Verification — 2026-09-20

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
