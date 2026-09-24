# StreamApp

Record your screen or stream to Twitch from your Mac’s menu bar.

## Install

The supported release install is for Apple silicon (arm64) Macs running macOS 26 or newer. Download the latest **StreamApp** ZIP from the [GitHub Releases](https://github.com/btuckerc/streamapp/releases/latest) page, then in Finder:

1. Open the downloaded ZIP.
2. Move **StreamApp.app** to your **Applications** folder.
3. Open **StreamApp** from Applications.

The release app is Developer ID signed, notarized, and stapled. No Apple developer certificate, `xattr` bypass, or other signing setup is required. The GitHub release also provides bundled FFmpeg in the app and a separate corresponding-source archive asset; keep that asset with the release materials when redistributing.

### Build from source

Source builds require macOS 26 or newer, Xcode, Python 3, and Homebrew. **No Apple signing certificate is required.** With [Homebrew](https://brew.sh) installed, quit any running StreamApp instance and run:

```sh
brew install openssl@3 pkg-config meson ninja
python3 scripts/build-app.py --install
```

Open **StreamApp** in your home folder’s **Applications** folder. To build without installing, omit `--install`; the app is created in the project folder.

To try a change, quit the running StreamApp, then run the install command again and reopen it; `--install` refuses to replace a running app.

The first build downloads and compiles pinned WebRTC/Abseil sources for local echo cancellation and a pinned, checksum-verified FFmpeg 9.0.2 source release; later builds reuse both static dependencies. For direct `swift build` or `swift test`, run `python3 scripts/build-aec.py` first. No WebRTC or FFmpeg runtime installation or network service is needed by the installed app. Homebrew `ffmpeg` is only used by the developer scripts `scripts/rtmp-receiver.py` and `scripts/verify-media.py`.

Fresh checkouts use local ad-hoc signing automatically. You can also request it explicitly with `--identity -`, including with `--install`. These builds are not notarized for distribution, and macOS permissions may need reapproval after rebuilding.

An optional `--identity` or `APPLE_SIGNING_IDENTITY` selects an installed Apple Development or Developer ID Application certificate. Existing local signing pins are preserved, so established developer builds keep their stable identity; an unavailable selected certificate fails rather than silently switching identities. Use `--identity -` to opt out for a local build without changing the pin.

## Developer ID release build

Release mode requires an installed **Developer ID Application** certificate and does not modify the local development signing pin or install the app. It packages the native host architecture only:

```sh
python3 scripts/build-app.py --release \
  --identity "Developer ID Application: Your Name (TEAMID)" \
  --version 1.3.1 --build-number 10 --output /absolute/path/StreamApp.app
```

The output path must not already exist. `scripts/build-ffmpeg.py` builds a minimal, static, LGPLv3 FFmpeg command-line tool containing only what StreamApp uses (FLV/PCM input, H.264 stream copy, AAC encoding, MP4/Matroska/tee/FIFO/FLV output, file/RTMP/RTMPS with statically linked OpenSSL). Its exact configuration, source checksum and licenses are recorded in the app; redistribution requires corresponding source and applicable license notices. A nonfree FFmpeg configuration is refused.

This command signs only; it does not notarize or publish. Use the shared sibling checkout's `python3 ../mac-releases/release.py --help` for the complete `build streamapp` → `notarize` → `verify` → `draft` → `publish` workflow. Stream App requires `--corresponding-source /path/to/archive.tar.gz` when building a release; that archive is distributed alongside the app. This must contain the exact corresponding dependency sources/build materials, not merely a source URL or an arbitrary source snapshot. The pipeline does not certify license compliance.

## Set up

1. Follow the setup window. Allow screen, camera, and microphone access when needed.
2. Choose the screen or window you want to record.
3. Pick **Desktop** or **Full Camera**. Turn your webcam and audio sources on or off.
4. Choose **Record**, **Stream**, or **Both** in the menu, then click **Start**. **Record** stays local even with a saved streaming setup; **Both** streams and saves a local copy. Click **Stop** when finished.

Recordings go in **Movies → StreamApp**. Change the folder in **Settings → Output**. After a recording stops, **Show Recording** beside the quit button reveals the file in Finder.

**Settings → Output → Recording format** chooses **MP4** (default) or **MKV**; both contain the same H.264 and AAC streams. MP4 uses FFmpeg's hybrid fragmented mode, the same approach as OBS's default [Hybrid MP4](https://obsproject.com/kb/hybrid-mp4): if the app crashes or the Mac loses power, everything written so far can be recovered, and a normal stop produces a regular MP4 that QuickTime, Finder, and editors open directly. MKV also survives crashes, but QuickTime and Finder cannot play it.

Choosing Stream or Both with missing or invalid connection details opens **Connect streaming**. Choose Twitch and connect your account, or choose Custom RTMP and save its server/key in Keychain. Setup never starts a broadcast: return to the menu and press Start, then confirm. Stop the current session before changing output modes.

StreamApp asks for camera, microphone, or Screen Recording access when you first turn on a source that needs it, following macOS convention. If access was turned off in System Settings, turning the source on offers **Open System Settings** instead. A one-line notice appears at the top of the menu, and beside the affected setting, only when an enabled source lacks access; unused sources never nag.

In onboarding's **Prepare** step, **Fit 16:9** sits beside **Render chat** below the preview. Set Fit before starting a local preview; the existing Dock confirmation and restoration behavior apply. New setups enable system audio by default. **Audio from** in Prepare selects all other apps or an isolated app: open Ableton, refresh the list, and choose it to exclude unrelated alerts. Saved disabled/isolated choices and the older audio-scope privacy migration remain unchanged. Screen Recording authorization is still required; you can turn audio off without granting it.

**Settings → Capture → Include menu bar** controls whether macOS's menu bar appears in display capture. It is on by default, is saved, and does not affect individual window capture or your actual desktop. Disabling it crops the selected display's top reserved strip (including the notch safe area) before fitting the remaining desktop into the output canvas. This intersects with the Dock-fit crop without changing the Dock-fit target or the 1080p output size.

**Settings → Layout → Background** fills unused space around display/window content: Black (default), Color, Image, Blurred desktop, or Mirrored wallpaper. The desktop stays sharp and uncropped. Blur has an amount slider; images are imported into app-owned storage, with a fallback color for transparency or a missing file. Mirrored wallpaper reflects a cached snapshot of the selected display's current rendered wallpaper, not recorded windows; unavailable wallpaper uses the fallback color. It refreshes on desktop/source changes, rather than continuously following wallpaper animation. These controls affect the program preview, recordings and streams, not the physical desktop or the camera's crop.

The menu is one panel with no scrolling: scene and preview, a row of Webcam, Punch in, Chat, Annotate, and Clear buttons, one row per audio source, and session start/stop. It grows only while a video preview is shown. Video preview starts **Off**; choose **Layout** or **Webcam** from the menu's **Preview** picker or in **Settings → Layout**. Closing the menu stops its idle capture unless Layout settings still needs it. Preview does not start a recording or broadcast. The menu-bar icon, like the app icon, is a screen with a webcam circle breaking its lower-right corner; the circle is hollow when idle and fills during recording or broadcasting.

**Webcam sizing** uses the frame’s natural axis. **Wide** uses the Desktop region’s width: the 25% normal default grows to exactly 50% when punched in. **Square** and **Circle** use the canvas height for both states: 25% normally and 50% when punched in, or 270 px and 540 px on the 1080p canvas. The separately saved Punch-in size is bounded to 40–90%; normal size is bounded to 12–40%. Both stay anchored to the current corner without moving desktop or chat. Set frame, both sizes and position in **Settings → Layout**. Press **Control–Option–Command–V**, or the menu's **Punch in** button, to toggle emphasis. Camera-only motion uses a gentle 600 ms Bézier transition; Reduce Motion cuts immediately. Punch-in never enables a disabled webcam or switches to Full Camera, and clears when the webcam is disabled, you leave Desktop, or the app restarts.
The **Webcam** section in **Settings → Layout** offers **Wide**, **Square**, and **Circle** frames. The camera uses clean clipping and a quiet separation shadow; Full Camera remains edge-to-edge and unstyled.

Settings is a standard macOS preferences window: a toolbar of pane icons (Capture, Audio, Layout, Chat, Prompter, Drawing, Output) with the selected pane's name as the window title. Reset arrows beside Settings controls restore that preference immediately and are disabled at its default. **Restore Defaults…** at the bottom requires confirmation, restores any active Dock fit first, and resets configuration plus drawing preferences. It preserves recordings, saved credentials, onboarding completion, and macOS permissions.

Each audio row has a mute button, a level verdict (**No sound**, **Too quiet**, **Good**, **Too loud**, **Clipping**), a gain readout, an enable switch, and a fader drawn over that source's live loudness meter, so dragging shows its effect immediately. Meters show perceived loudness (ITU-R BS.1770 LUFS), not peaks. Aim for the green band, −19 to −13 LUFS around the −16 LUFS streaming target (AES TD1008, [Apple](https://podcasters.apple.com/support/893-audio-requirements)); a tick holds the recent loudest moment. **Clipping** means sample peaks reached −1 dBFS. The dB readout is the gain adjustment, not the measured signal level. Double-click or Option-click the fader to restore 0 dB without changing mute/enable; Shift-drag adjusts finely, and dragging snaps to 0 dB. The **Mix** meter shows what viewers hear, with its 3-second loudness in LUFS. Enable switches remain separate because disabling releases capture while mute only silences the mix. Microphone gain is before compression: increasing it also drives compression harder. Compression lives in **Settings → Audio → Processing**, not the quick menu.

**Settings → Audio → Processing → Echo cancellation** optionally reduces speaker playback entering your microphone, before microphone gain/compression. It is saved independently of compression and defaults off. It uses other apps' playback privately as a reference even when broadcast app audio is disabled, muted, or limited to one app; the reference itself is never added to your recording/stream. Your selected system-audio feed stays stereo and unchanged. Enabled AEC makes the microphone mono, removes rumble below about 100 Hz, and can soften quiet speech or musical input; use bypass/headphones for critical music. The status shows when cancellation is active or bypassed because its reference is unavailable. This is in-app WebRTC processing, not macOS Voice Isolation.

**Noise reduction** is a separate, saved, default-off switch in the same section. It reduces microphone hiss/fan noise with or without AEC, without capturing playback when AEC and app audio are off. It processes the mic as mono and can soften very quiet speech or music. Leave it off for voice fidelity; enabling it adds approximately 7 ms of signal delay. Toggling it does not reset AEC's learned echo filter.

**Settings → Capture → Show StreamApp windows** controls whether the menu and app windows appear in display recordings and streams. It is off by default, saves your choice, and can be changed during a session. Annotation ink stays visible either way.

**Fit 16:9**, in **Settings → Layout** and onboarding's **Prepare** step, temporarily shows and resizes a bottom Dock to fit the desktop into the scene. It remembers both the previous size and auto-hide setting, including across app restarts, and restores them when turned off. Chat and its width change the target. Applying or restoring settings briefly restarts Dock; System Events permission is no longer required. Capture follows the measured area above the Dock, including the menu bar, as items appear or disappear. If macOS cannot reach the ideal height, the whole usable desktop fits with padding rather than losing content. Restoration waits for the hidden Dock’s pre-fit desktop boundary before clearing its recovery journal. Newer manual size or visibility choices are kept. Handoff and Dock items are never changed. StreamApp does not reposition other apps’ windows.

## Notch teleprompter

Choose **Off**, **Transcript**, or **Twitch chat** in **Settings → Prompter**. Teleprompter controls live only in Settings, not the quick menu. The pure-black panel extends down from the physical display camera—not the webcam image in your video—with three transcript lines or the latest six chat messages. It prefers the built-in notched display.

In Prompter settings, **Save Template…** creates an editable Markdown script; **Open…** loads an existing Markdown script and **Reload** reads saved edits. Put `---` on its own line between cues. Longer cues wrap into three-line pages. **Left / Right** move backward / forward globally while the transcript is expanded. The arrows pause when collapsed, while editing StreamApp settings, or while choosing files.

Click anywhere on the panel to retract it; the fixed chevron immediately left of the notch expands it again without losing your place. Twitch mode uses the channel in **Settings → Chat** (blank follows your connected account) independently of **Render chat**.

The entire teleprompter, including its chevron, is **private in StreamApp by default**, even with **Show StreamApp windows** enabled. **Visible in stream and recording** explicitly includes it in display capture on that screen. It is not added to Full Camera or other single-window sources. This privacy rule does not hide it from other recording apps.

## Producing music in Ableton

1. Open Ableton. In **Settings → Audio**, click the refresh button beside **Audio from**, select **Ableton Live**, and enable **Capture app audio**. Video selection and scene changes do not change this audio selection.
2. With AirPods, use them for playback only. Choose the Mac or a USB/interface microphone explicitly, or disable the microphone. **Mute does not release a microphone**; even the visible menu's level check opens an enabled mic. Other apps can also open the AirPods mic and affect playback.
3. With speakers, disable the microphone for clean music-only capture. For voice plus music, headphones avoid speaker bleed and delayed doubling. Monitor directly through Ableton/interface, not the stream.
4. Use wired headphones for latency-sensitive playing. Start with a stable Ableton buffer (128–256 samples is a starting point, not a guarantee), choose the intended stereo main output, and use **Standard** macOS Mic Mode for musical inputs.
5. Record a short check: play music, open another audio app, change scenes, speak, stop, and replay the file. Check left/right, unwanted cue/metronome/alerts, doubling, clipping, and camera sync.

**Upgrade note:** older saved configurations captured audio according to video filters. App audio is disabled once when loading those settings so the upgrade cannot silently expose previously excluded apps. Choose an audio source and re-enable it. **All other apps** includes alerts and is independent of visual exclusions.

OBS 30+ has a native **macOS Audio Capture** source: target Ableton, keep it in every required scene, disable duplicate desktop/screen-capture audio, and leave monitoring **Off**. BlackHole/Loopback are optional routing fallbacks, not prerequisites.

See the [audio risk matrix, OBS checklist, and qualification limits](docs/architecture.md#ableton--obs-audio-qualification).

## Twitch

In **Settings → Output**, select **Twitch** and **Connect with Twitch**. Approve **StreamApp by btuckerc** in your browser. StreamApp requests only chat-read and stream-key-read permissions, stores OAuth credentials in macOS Keychain, and retrieves your key automatically when starting a confirmed Twitch stream. No manual key or separate chat server is needed. Twitch is the default when no service choice is saved; an explicitly saved **Custom RTMP** choice is retained. **Record** stays local.

In **Settings → Chat**, or onboarding's optional Twitch section, enter a username, `@name`, or Twitch channel link. **Apply** appears only after editing; connected accounts check that the channel exists before saving. Blank uses your connected account's channel. **Test** shows messages without recording or broadcasting. Turn on **Render chat** to include them in the program.

Under **Chat → Appearance → Preset**, choose **Terminal** (24 px), **Compact** (20 px), **Large text** (32 px), or **Monochrome** (24 px, no name colors, emote images or highlights). Individual tweaks show as **Custom**. All use restrained monospace `<username> message` formatting; sizes refer to the 1080p output, not the scaled preview. Appearance changes apply without reconnecting. The chat preview's **Text** view is selectable.

Appearance also controls Twitch colors, emotes, command/mention highlighting, timestamps, the channel heading, connection status and background. Dark name colors are brightened to reach a 4.5:1 contrast target.

**Emotes** is on by default: Twitch plus public global/channel catalogs from **7TV, BetterTTV and FrankerFaceZ**, with no extension or separate provider login. Codes are case-sensitive (`SAJ`, not `saj`). Images are static to avoid continuous animation work; adjacent zero-width modifiers can layer over emotes. Catalogs are cached and refreshed every 30 minutes while chat is active, not fetched per message. Unknown or unavailable images remain readable text. The info icon in the chat preview reports loaded counts and unavailable providers. Private/personal packs and animated effects are not supported.

To test your connection, turn on **Twitch test stream**, select **Stream** or **Both**, then click **Start** and confirm. It sends video to Twitch without making it viewable live. **Record** remains local even while this test setting is saved. Check connection stability and bitrate in [Twitch Inspector](https://inspector.twitch.tv/).

Turn test mode off when you want to go live. Starting a stream always asks for confirmation.

## Draw on your screen

Click **Annotate** or press **Control–Option–Command–D**. Press **Esc** to stop drawing. Click **Clear** to erase the drawing.

The compact icon toolbar uses native pen, marker, eraser, arrow, shape and edit symbols in a single row, without footer text. Hover for descriptions; blue outlines mark the selected tool and Straight mode.

In **Settings → Drawing**, choose smoothing and pen width (1–24 pt, default **6 pt**), plus three independent colors: **Stroke**, red by default, for pen, arrows, and shape outlines; **Highlighter**, yellow by default; and **Fill** for ellipse/rectangle interiors. Fill supports opacity and defaults to no fill. Settings apply to new strokes without recoloring existing ink. Freehand and straight Pen/Arrow use the same tablet-pressure width; straight strokes retain contact pressure on pen-up. Highlight and Erase use a broader tip. Off and Strong sit directly beside the smoothing slider.

Choose **Arrow** for a freehand stroke with an arrowhead at its end. **Straight** toggles straight pen lines and arrows. **Hold to straighten** defaults on: the mapped Straighten button (middle by default) temporarily straightens before or during a stroke; release returns subsequent strokes to the toolbar mode. Saved preferences are preserved. Tap the secondary button to toggle Pen/Erase (from other tools, return to Pen); hold it for a quarter-second to open the radial menu. Clockwise from the top: **Colors, Pen, Arrow, Rectangle, Ellipse, Erase, Undo, Highlight**. Hover and release to choose; release in the center or press Escape to cancel. Colors opens a second radial palette: choose **Stroke / Highlighter / Fill**, then a swatch; Fill also offers **No fill**, and **‹ Tools** goes back. The toolbar palette button opens the same colors. **Settings → Drawing → Pen buttons** lets you learn and assign any delivered non-primary button. Drivers that consume a button for Scroll must first map it to a click that apps receive. Tablet Companion offers reversible global Wacom assignments; no application profile is created.

Tablet Companion’s suggested tablet-button order is **Annotate, Webcam punch-in, Stroke width, Clear**. These are the tablet’s ExpressKeys, not its pen buttons. Each available button can be reassigned; Color remains an option. Punch-in works outside drawing mode while StreamApp’s Desktop webcam is enabled. Color, width, and Clear shortcuts work only while drawing; Clear is not a pen action. Escape dismisses a picker before leaving drawing.

Drag **Ellipse** or **Rectangle** to create shapes. Hold **Shift** for circles/squares, or 15° angle snapping in Straight mode. **Erase** defaults to removing whole strokes, arrows, or shapes you touch. Choose **Settings → Drawing → Tools → Eraser → Partial** to rub out just the area under the tip instead. **Undo** reverses the last drawing or eraser gesture, restoring all objects removed in that gesture.

## License

Copyright (C) 2026 btuckerc. StreamApp is free software: you may redistribute it and/or modify it under the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version (**GPL-3.0-or-later**).

StreamApp is distributed in the hope that it will be useful, but **without any warranty**, including the implied warranties of merchantability or fitness for a particular purpose. See [LICENSE](LICENSE) for the full terms.

The app bundles a separate, statically linked LGPLv3 FFmpeg command-line tool (with OpenSSL, Apache-2.0); StreamApp itself links no FFmpeg library. Each release includes the matching application and dependency sources, build materials, and third-party notices in its corresponding-source archive. Third-party components retain their own copyright and compatible license terms. License notices are also bundled under `Contents/Resources/ThirdParty`. No click-through installer agreement is added.

## Notes

- Video: 1080p, 30 frames per second, 6 Mb/s.
- Twitch chat connects directly through EventSub WebSocket; no anglbot/SSE bridge or chat-posting permission.
- Builds, recordings, local settings, and signing details stay out of Git.
- The build includes FFmpeg. Its bundled license notices are inside the app.

[Technical details](docs/architecture.md) · [Checks performed](docs/verification.md) · [Benchmarks vs OBS](docs/benchmarks.md)
