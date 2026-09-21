# StreamApp

Record your screen or stream to Twitch from your Mac’s menu bar.

## Install

The supported release install is for Apple silicon (arm64) Macs running macOS 26 or newer. Download the latest **StreamApp** ZIP from the [GitHub Releases](https://github.com/btuckerc/streamapp/releases/latest) page, then in Finder:

1. Open the downloaded ZIP.
2. Move **StreamApp.app** to your **Applications** folder.
3. Open **StreamApp** from Applications.

The release app is Developer ID signed, notarized, and stapled. No Apple developer certificate, `xattr` bypass, or other signing setup is required. The GitHub release also provides bundled FFmpeg in the app and a separate corresponding-source archive asset; keep that asset with the release materials when redistributing.

### Build from source

Source builds require macOS 26 or newer, Xcode, Python 3, Homebrew, and an Apple signing certificate (or the local ad-hoc development signing option). With [Homebrew](https://brew.sh) installed, run these commands in this folder:

```sh
brew install ffmpeg pkg-config
python3 scripts/build-app.py --install
```

Open **StreamApp** in your home folder’s **Applications** folder.

## Developer ID release build

Release mode requires an installed **Developer ID Application** certificate and does not modify the local development signing pin or install the app. It packages the native host architecture only:

```sh
python3 scripts/build-app.py --release \
  --identity "Developer ID Application: Your Name (TEAMID)" \
  --version 1.1.1 --build-number 5 --output /absolute/path/StreamApp.app
```

The output path must not already exist. FFmpeg is bundled from Homebrew with its dependency graph and build configuration recorded in the app; the current GPL/version-3 configuration requires corresponding source and applicable license notices for any redistribution. A nonfree FFmpeg configuration is refused.

This command signs only; it does not notarize or publish. Use the shared sibling checkout's `python3 ../mac-releases/release.py --help` for the complete `build streamapp` → `notarize` → `verify` → `draft` → `publish` workflow. Stream App requires `--corresponding-source /path/to/archive.tar.gz` when building a release; that archive is distributed alongside the app. This must contain the exact corresponding dependency sources/build materials, not merely a source URL or an arbitrary source snapshot. The pipeline does not certify license compliance.

## Set up

1. Follow the setup window. Allow screen, camera, and microphone access when needed.
2. Choose the screen or window you want to record.
3. Pick **Desktop** or **Full Camera**. Turn your webcam and audio sources on or off.
4. Choose **Record**, **Stream**, or **Both** in the menu, then click **Start**. **Record** stays local even with a saved streaming setup; **Both** streams and saves a local copy. Click **Stop** when finished.

Recordings go in **Movies → StreamApp**. Change the folder in **Settings → Outputs**.

Choosing Stream or Both with missing or invalid connection details opens **Connect streaming**. Choose Twitch and connect your account, or choose Custom RTMP and save its server/key in Keychain. Setup never starts a broadcast: return to the menu and press Start, then confirm. Stop the current session before changing output modes.

If screen/system-audio, camera, or microphone access is missing, **Finish permissions setup…** appears above the menu's meters and at the top of Settings. It lists missing access and reopens onboarding, including after setup was skipped. Once all capture permissions are granted, it disappears. macOS approvals remain separate, explicit actions inside setup; unused sources do not need to be enabled.

In onboarding's **Prepare** step, **Fit 16:9** sits beside **Render chat** below the preview. Set Fit before starting a local preview; the existing Dock confirmation and restoration behavior apply. New setups enable system audio by default. **Audio from** in Prepare selects all other apps or an isolated app: open Ableton, refresh the list, and choose it to exclude unrelated alerts. Saved disabled/isolated choices and the older audio-scope privacy migration remain unchanged. Screen Recording authorization is still required; you can turn audio off without granting it.

**Settings → Layout → Include menu bar** controls whether macOS's menu bar appears in display capture, independently of Fit 16:9. It is on by default, is saved, and does not affect individual window capture or your actual desktop. Disabling it hides the menu-bar content without cropping the canvas or changing the Dock-fit target.

**Settings → Layout → Background** fills unused space around display/window content: Black (default), Color, Image, Blurred desktop, or Mirrored wallpaper. The desktop stays sharp and uncropped. Blur has an amount slider; images are imported into app-owned storage, with a fallback color for transparency or a missing file. Mirrored wallpaper reflects a cached snapshot of the selected display's current rendered wallpaper, not recorded windows; unavailable wallpaper uses the fallback color. It refreshes on desktop/source changes, rather than continuously following wallpaper animation. These controls affect the program preview, recordings and streams, not the physical desktop or the camera's crop.

The menu shows live audio levels. Video preview starts **Off**; choose **Layout** or **Webcam** in the menu or **Settings → Layout**. Both use the same preview control; the Settings preview stays above the scrolling controls. Closing the menu stops its idle capture unless Layout settings still needs it. Preview does not start a recording or broadcast. **Fit 16:9** uses the same label everywhere; hover for the Dock-adjustment and restoration details.

Reset arrows beside Settings controls restore that preference immediately and are disabled at its default. **Restore All Defaults…** at the bottom requires confirmation, restores any active Dock fit first, and resets configuration plus drawing preferences. It preserves recordings, saved credentials, onboarding completion, and macOS permissions. The pinned Layout preview casts a subtle shadow over the scrolling controls beneath it.

The gear beside **System audio** opens **Settings → Audio** directly, including when Settings is already open on another tab.

**Settings → Sources → Show StreamApp windows** controls whether the menu and app windows appear in display recordings and streams. It is off by default, saves your choice, and can be changed during a session. Annotation ink stays visible either way.

**Fit 16:9**, beside **Render chat**, temporarily shows and resizes a bottom Dock to fit the desktop into the scene. It remembers both the previous size and auto-hide setting, including across app restarts, and restores them when turned off. Chat and its width change the target. Allow **System Events** control if macOS asks; the Dock is not restarted. Capture follows the actual area above the Dock, including the menu bar, as items appear or disappear. If macOS cannot reach the ideal height, the whole usable desktop fits with padding rather than losing content. Newer manual size or visibility choices are kept. Handoff and Dock items are never changed. More detail is in **Settings → Layout**.

## Producing music in Ableton

1. Open Ableton. In **Settings → Audio**, click **Refresh Apps & Devices**, select **Ableton Live** under **Audio from**, and enable **Capture app audio**. Video selection and scene changes do not change this audio selection.
2. With AirPods, use them for playback only. Choose the Mac or a USB/interface microphone explicitly, or disable the microphone. **Mute does not release a microphone**; even the visible menu's level check opens an enabled mic. Other apps can also open the AirPods mic and affect playback.
3. With speakers, disable the microphone for clean music-only capture. For voice plus music, headphones avoid speaker bleed and delayed doubling. Monitor directly through Ableton/interface, not the stream.
4. Use wired headphones for latency-sensitive playing. Start with a stable Ableton buffer (128–256 samples is a starting point, not a guarantee), choose the intended stereo main output, and use **Standard** macOS Mic Mode for musical inputs.
5. Record a short check: play music, open another audio app, change scenes, speak, stop, and replay the file. Check left/right, unwanted cue/metronome/alerts, doubling, clipping, and camera sync.

**Upgrade note:** older saved configurations captured audio according to video filters. App audio is disabled once when loading those settings so the upgrade cannot silently expose previously excluded apps. Choose an audio source and re-enable it. **All other apps** includes alerts and is independent of visual exclusions.

OBS 30+ has a native **macOS Audio Capture** source: target Ableton, keep it in every required scene, disable duplicate desktop/screen-capture audio, and leave monitoring **Off**. BlackHole/Loopback are optional routing fallbacks, not prerequisites.

See the [audio risk matrix, OBS checklist, and qualification limits](docs/architecture.md#ableton--obs-audio-qualification).

## Twitch

In **Settings → Outputs**, select **Twitch** and **Connect with Twitch**. Approve **StreamApp by btuckerc** in your browser. StreamApp requests only chat-read and stream-key-read permissions, stores OAuth credentials in macOS Keychain, and retrieves your key automatically when starting a confirmed Twitch stream. No manual key or separate chat server is needed. Twitch is the default when no service choice is saved; an explicitly saved **Custom RTMP** choice is retained. **Record** stays local.

In **Settings → Sources → Chat**, or onboarding's optional Twitch section, enter a username, `@name`, or Twitch channel link. **Apply** appears only after editing; connected accounts check that the channel exists before saving. Blank uses your connected account's channel. **Test chat** shows messages without recording or broadcasting. Turn on **Render chat** to include them in the program.

Under **Chat → Appearance → Preset**, choose **Terminal** (24 px), **Compact** (20 px), **Large text** (32 px), or **Monochrome** (24 px, no name colors, emote images or highlights). Individual tweaks show as **Custom**. All use restrained monospace `<username> message` formatting; sizes refer to the 1080p output, not the scaled preview. Appearance changes apply without reconnecting. **Test chat → Text** provides a selectable text view.

Appearance also controls Twitch colors, emotes, command/mention highlighting, timestamps, the channel heading, connection status and background. Dark name colors are brightened to reach a 4.5:1 contrast target.

**Emotes** is on by default: Twitch plus public global/channel catalogs from **7TV, BetterTTV and FrankerFaceZ**, with no extension or separate provider login. Codes are case-sensitive (`SAJ`, not `saj`). Images are static to avoid continuous animation work; adjacent zero-width modifiers can layer over emotes. Catalogs are cached and refreshed every 30 minutes while chat is active, not fetched per message. Unknown or unavailable images remain readable text. The info icon in Test chat reports loaded counts and unavailable providers. Private/personal packs and animated effects are not supported.

**Bot commands** explains the legacy `!fish` / `!help` commands: anglbot must run separately in that channel. StreamApp does not execute commands, post replies or embed bot HTML/charts.

To test your connection, turn on **Twitch test stream**, select **Stream** or **Both**, then click **Start Test Stream** or **Start Test & Recording** and confirm. It sends video to Twitch without making it viewable live. **Record** remains local even while this test setting is saved. Check connection stability and bitrate in [Twitch Inspector](https://inspector.twitch.tv/).

Turn test mode off when you want to go live. Starting a stream always asks for confirmation.

## Draw on your screen

Click **Annotate desktop** or press **Control–Option–Command–D**. Press **Esc** to stop drawing. Click **Clear** to erase the drawing.

The compact icon toolbar uses native pen, marker, eraser, arrow, shape and edit symbols in a single row, without footer text. Hover for descriptions; blue outlines mark the selected tool and Straight mode.

In **Settings → Drawing**, choose smoothing and pen width (1–24 pt), plus three independent colors: **Stroke** for pen, arrows, and shape outlines; **Highlighter**, yellow by default; and **Fill** for ellipse/rectangle interiors. Fill supports opacity and defaults to no fill. The quick color palette also lets you choose which color to change. Settings apply to new strokes without recoloring existing ink. Freehand and straight Pen/Arrow use the same tablet-pressure width; straight strokes retain contact pressure on pen-up. Highlight and Erase use a broader tip.

Choose **Arrow** for a freehand stroke with an arrowhead at its end. **Straight** toggles straight pen lines and arrows. By default, middle-click toggles Straight. Tap the secondary button to toggle Pen/Erase (from other tools, return to Pen); hold it for a quarter-second to open the six-tool radial menu. Hover over a sector and release the button to select—no tip tap. Release in the center or press Escape to cancel. **Settings → Drawing → Pen buttons** lets you learn and assign any delivered non-primary button; no fixed pen-button count is assumed. **Hold to straighten** makes your mapped Straighten button temporary: press before or during a stroke, release to return subsequent strokes to freehand. Drivers that consume a button for Scroll must first map it to a click that apps receive. Tablet Companion offers reversible global Wacom assignments; no application profile is created.

Tablet Companion’s suggested tablet-button order is **Annotate, Color, Stroke width, Clear**. Each available button can be reassigned. Color, width, and Clear shortcuts work only while drawing; Clear is not a pen action. Escape dismisses a picker before leaving drawing.

Drag **Ellipse** or **Rectangle** to create shapes. Hold **Shift** for circles/squares, or 15° angle snapping in Straight mode. **Erase** defaults to removing whole strokes, arrows, or shapes you touch. Choose **Settings → Drawing → Eraser → Partial** to rub out just the area under the tip instead. **Undo** reverses the last drawing or eraser gesture, restoring all objects removed in that gesture.

## License

Copyright (C) 2026 btuckerc. StreamApp is free software: you may redistribute it and/or modify it under the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version (**GPL-3.0-or-later**).

StreamApp is distributed in the hope that it will be useful, but **without any warranty**, including the implied warranties of merchantability or fitness for a particular purpose. See [LICENSE](LICENSE) for the full terms.

The app links a GPL-enabled FFmpeg build. Each release includes the matching application and dependency sources, Homebrew recipes, build materials, and third-party notices in its corresponding-source archive. Third-party components retain their own copyright and compatible license terms. License notices are also bundled under `Contents/Resources/ThirdParty`. No click-through installer agreement is added.

## Notes

- Video: 1080p, 30 frames per second, 6 Mb/s.
- Twitch chat connects directly through EventSub WebSocket; no anglbot/SSE bridge or chat-posting permission.
- Builds, recordings, local settings, and signing details stay out of Git.
- The build includes FFmpeg. Its bundled license notices are inside the app.

[Technical details](docs/architecture.md) · [Checks performed](docs/verification.md)
