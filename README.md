# StreamApp

Record your screen or stream to Twitch from your Mac’s menu bar.

## Install

Requires macOS 26 or newer, Xcode, Python 3, and an Apple signing certificate on your Mac. This is a local build, not an Apple-notarized download.

With [Homebrew](https://brew.sh) installed, run these commands in this folder:

```sh
brew install ffmpeg pkg-config
python3 scripts/build-app.py --install
```

Open **StreamApp** in your home folder’s **Applications** folder.

## Set up

1. Follow the setup window. Allow screen, camera, and microphone access when needed.
2. Choose the screen or window you want to record.
3. Pick **Desktop** or **Full Camera**. Turn your webcam and audio sources on or off.
4. Click **Start Recording**. Click **Stop Session** when finished.

Recordings go in **Movies → StreamApp**. Change the folder in **Settings → Outputs**.

The menu shows live audio levels. Video preview starts **Off**; choose **Layout** or **Webcam** when needed. Closing the menu stops the idle preview, not an active recording.

**Fit 16:9**, beside **Render chat** in the menu, resizes a visible bottom Dock to match the desktop above it—including the menu bar—to the video’s aspect ratio. A near-fit can leave a thin strip above the Dock outside the exact 16:9 capture. The old Dock size is saved locally and restored when turned off, even after restarting StreamApp. If you change the Dock size elsewhere, your newer setting is kept. Unsupported display sizes or Dock arrangements are rejected. The same control and explanation are in **Settings → Layout**.

## Twitch

In **Settings → Outputs**, enable streaming, enter your Twitch server address, and save your stream key. The key stays in macOS Keychain, not in this repo.

To test your connection, turn on **Twitch test stream**, then click **Start Test Stream** and confirm. It sends video to Twitch without making it viewable live. Check connection stability and bitrate in [Twitch Inspector](https://inspector.twitch.tv/).

Turn test mode off when you want to go live. Starting a stream always asks for confirmation.

## Draw on your screen

Click **Annotate desktop** or press **Control–Option–Command–D**. Press **Esc** to stop drawing. Click **Clear** to erase the drawing.

## Notes

- Video: 1080p, 30 frames per second, 6 Mb/s.
- Optional chat needs a separate chat connection; signing in to Twitch does not set it up.
- Builds, recordings, local settings, and signing details stay out of Git.
- The build includes FFmpeg. Its bundled license notices are inside the app.

[Technical details](docs/architecture.md) · [Checks performed](docs/verification.md)
