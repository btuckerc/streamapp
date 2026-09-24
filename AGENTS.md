# StreamApp agent notes

- Goal: low compute and low resource use. No new timers or polling; per-sample audio work stays allocation-free.
- Deploy a change: quit the running StreamApp gracefully (and any smoke runs, which share the process name), then `python3 scripts/build-app.py --install`, then reopen `~/Applications/StreamApp.app`. `--install` refuses while StreamApp runs.
- Checks: `swift test` (fresh checkout: `python3 scripts/build-aec.py` first). UI: `StreamApp.app/Contents/MacOS/StreamApp --ui-smoke`, `--settings-smoke`, or `--onboarding-smoke` after building without `--install`.
- FFmpeg: `scripts/build-ffmpeg.py` builds a pinned, static, minimal LGPLv3 `ffmpeg` (only the demuxers/decoders/encoders/muxers/protocols/filters `MediaOutput` uses; OpenSSL linked statically). A new recording format, codec, filter or protocol must be added to its `--enable-*` list. The app bundle ships no dylibs; the in-app FLV muxer is native C (`Sources/EncodedMuxer`).
- Benchmarks: `python3 bench/run.py --label <version>` compares StreamApp with OBS on this Mac (AC power, Low Power Mode off, both apps quit); `python3 bench/report.py old/results.json new/results.json` diffs runs. Run it for releases, OBS upgrades and performance changes; see `docs/benchmarks.md`.
