# Runtime benchmark: StreamApp vs OBS

`bench/` runs the same capture/encode workload in StreamApp and OBS Studio on the same Mac. It records CPU, GPU, energy, memory, start/stop timing, glass-to-network latency, A/V sync and output quality. Results are versioned JSON, so every StreamApp release and every OBS upgrade can be compared with earlier runs.

## Run it

```sh
# Prerequisites: AC power, Low Power Mode off, StreamApp and OBS both quit, no audio playing,
# /Applications/OBS.app installed, Homebrew ffmpeg/ffprobe (analysis only), a freshly built StreamApp.app
python3 scripts/build-app.py
python3 bench/run.py --label v1.3.0           # 3 reps × 7 scenarios × both apps, ~45 min
python3 bench/report.py bench/results/<old>/results.json bench/results/<new>/results.json
```

- **Output.** `bench/results/<stamp>-<label>/results.json` holds every trial plus a summary. `report.md` renders it. Raw probe samples, stimulus logs, recordings, received streams and OBS logs go under `.build/bench/runs/<stamp>/`, which is not versioned.
- **Scenarios.** `idle` (app launched, nothing started), `record`, `stream` and `both` (record + stream) run on a static screen. `record-motion`, `stream-motion` and `both-motion` scroll noise across the whole display so every captured frame changes.
- **Options.** `--scenarios record,stream-motion`, `--repeat 5`, `--seconds 60`, `--apps streamapp` (for trend runs without OBS), and `--streamapp PATH` / `--obs PATH` to compare specific bundles (e.g. two OBS versions installed side by side).
- **Refusals.** The harness refuses to run:
  - on battery or in Low Power Mode (`--allow-unstable-power` runs anyway and marks the report as provisional);
  - while audio is playing (`--allow-audio`), because that audio would mix into the captured system audio;
  - while StreamApp or OBS is running (`--allow-running`).
- **Machine state.** For every trial, an opaque grey cover fills the main display, above the menu bar and Dock. The screen is unusable during a run, and trials capture identical content whatever was open underneath. A 320-pt square at the centre flips between dark and light grey, and a short 2 kHz tick plays on every dark→light flip. The cover follows the harness: it exits if the harness is interrupted or killed.

### Why the screen is covered

The first full run captured whatever the display showed. Mid-run, a video began playing in a browser. From then on, both apps' capture work jumped:

- WindowServer GPU: ≈4 → ≈75 ms/s.
- StreamApp's own CPU: ≈14 → ≈27 %.
- StreamApp's own GPU: ≈1 → ≈12 ms/s.

The video's audio also produced spurious 2 kHz detections. That run was discarded. Screen content is now controlled, with separate static and motion profiles. `media.av_offset` now withholds offsets when it finds more tone bursts than the stimulus played.

### Workflows

| Event | Do |
|---|---|
| StreamApp release | Build, run `bench/run.py --label vX.Y.Z`, then `report.py` against the previous release's `results.json`. |
| OBS upgrade | Install the new OBS, run `bench/run.py --label obs-NN`, then compare with the last run. |
| Quick check of one change | `bench/run.py --apps streamapp --scenarios record,record-motion --repeat 3 --label wip` |

Compare only runs from the same machine, macOS version and display mode; the report header records all three. `report.py` flags comparisons that span harness schemas.

## Workload parity

Both apps are configured for the same job:

- **Capture:** the main display, fitted to a 1920×1080 canvas at 30 fps with the cursor shown.
- **Video:** VideoToolbox hardware H.264 High, CBR 6 Mb/s, 2 s keyframes, no B-frames.
- **Audio:** system audio, AAC 160 kb/s, 48 kHz stereo.
- **Recording:** fragmented/hybrid MP4.
- **Stream:** RTMP to `rtmp://127.0.0.1:19351/live/bench`.
- **Extras:** no camera, chat, overlays, filters or microphone.

| | StreamApp (`--bench` mode) | OBS (generated profile) |
|---|---|---|
| Launch | `open -n -g` (LaunchServices, so the app's own permissions apply) | Same, plus `--minimize-to-tray` |
| State | Non-persisting demo model; user settings, keys and Twitch are never read or written | Fresh config home per trial via `CFFIXED_USER_HOME`; websocket on port 4466; the user's OBS config and port 4455 are untouched |
| Control | Self-timed: `--bench DIR --bench-delay S --bench-seconds S [--bench-idle] [--bench-no-record] [--bench-rtmp URL]` prints `BENCH {json}` events | obs-websocket v5: `StartRecord`/`StartStream`, output state events, `GetStats` |
| Capture pipeline | ScreenCaptureKit BGRA at output size, queue depth 3 | OBS `screen_capture` (SCK at native resolution, 10-bit, queue depth 8), GPU scaled to the canvas |
| Encoder | `RealTime` true | OBS default (`RealTime` false) |
| Audio encoder | FFmpeg `aac` | CoreAudio AAC |
| UI during run | Menu-bar item only | Main window minimised to the tray; preview not drawn |

The differences in the lower rows are the apps' own pipelines, which is what is being compared. Neither app shows a visible preview.

## What is measured

Each trial follows the same sequence:

1. Cooldown.
2. Machine baseline, with the stimulus running and the app not yet launched.
3. Launch.
4. Wait for ready: StreamApp's `ready` event, or the first successful OBS `GetVersion`.
5. Settle for 5 s.
6. Start, then warm up for 5 s.
7. The 30 s **measured window**.
8. Stop and quit.

Apps alternate order between repetitions to cancel thermal and background drift. Reported values are medians across repetitions, with the min–max range.

| Metric | Source | Notes |
|---|---|---|
| Launch → ready, CPU to ready | Harness clock before `open`; app `ready` event / websocket | OBS readiness includes obs-websocket polling (≤20 ms). |
| Start / stop latency | Request → StreamApp `start_returned`/`stopped`, or OBS `OUTPUT_STARTED`/`OUTPUT_STOPPED` events | |
| CPU %, CPU energy, instructions, wakeups, footprint | `bench/probe`: kernel `proc_pid_rusage` v6 | Covers the app, its descendants (StreamApp's `ffmpeg`) and processes whose *responsible* pid is the app (`VTEncoderXPCService`, `SetStoreUpdateService`). CPU energy is the kernel's per-process estimate. |
| GPU time | AGX `IOAccelerator` per-client `accumulatedGPUTime` | Covers the app's own Metal/CoreImage/VideoToolbox clients. |
| WindowServer GPU, GPU energy, host CPU (above baseline) | AGX client for WindowServer; IOReport "GPU Energy"; `host_statistics` | Machine-wide values minus the pre-launch baseline, which catches capture work done on the app's behalf. Host CPU is noisy: it includes every other process on the Mac, so trust it only when the Mac is otherwise idle. |
| Glass → loopback receiver | `bench/stimulus` + `bench/rtmp.py` | Time from a display-link flip to arrival of the first RTMP video message whose decoded frame shows it. Arrivals are timestamped at the socket, so the receiver adds no decode or demux buffering. Every run first calibrates the floor with a synthetic x264 publisher (≈1–3 ms). |
| Start request → first received frame | Same receiver | Time to go live on the wire. |
| A/V offset | Tone onset minus the dark→light video transition, per flip, in the recording and in the received stream | Positive means audio is late. The stimulus' own audio-output latency and the 33 ms capture quantisation are shared by both apps, so compare apps rather than absolute values. |
| Output cadence and bitrate | `ffprobe` packet timestamps | Effective fps, gaps over 1.5 frame intervals, and the maximum frame interval (both after the first second), plus container bitrate. OBS's own skipped/lagged frame counters are kept in `app_stats`. |

### Limits

- WindowServer CPU, `replayd`, `coreaudiod` and CPU package energy cannot be attributed to a process without root. The machine-wide deltas stand in for them.
- Disk-write counters are not reported: writeback happens outside the measured window.
- Per-process memory is physical footprint, which counts `VTEncoderXPCService` separately for each app (StreamApp ≈57 MB, OBS ≈88 MB).
- The cover, flip square, tone and motion pattern add a load that is identical for both apps. It is present in the pre-launch baseline, so the above-baseline deltas exclude it.

## Files

| Path | Role |
|---|---|
| `bench/run.py` | Orchestrator, metrics, environment capture (machine, macOS, display, power, app versions, bundle sizes, git commit) |
| `bench/report.py` | Markdown for one run or a comparison across runs |
| `bench/streamapp.py`, `bench/obs.py` | App adapters (`Session.launch/run/abort`). Adding another app means adding one adapter. |
| `bench/probe.swift` | Resource sampler (JSON lines) |
| `bench/stimulus.swift` | Display cover (static or motion), flip square and tone, with a host-time event log |
| `bench/rtmp.py` | Minimal RTMP publish server with per-message arrival times, plus receiver calibration |
| `bench/media.py` | `ffprobe` facts, stimulus detection, A/V offset |

## Results

See `bench/results/*/report.md`; each run's `report.md` has the full tables.

### Provisional: 2026-09-24, StreamApp 1.3.0 (9) vs OBS 31.0.1

This was the discarded schema-1 run: M2 Max on battery with Low Power Mode on, and screen content uncontrolled (see "Why the screen is covered"). A/V offsets from it are invalid. The other figures are medians of 3 reps. Content-dependent rows are split by what the screen was doing, taken from the WindowServer GPU mode of each trial.

| Metric | StreamApp | OBS |
|---|---|---|
| Idle CPU / GPU / wakeups | 0.17 % / 0 ms/s / 1.1 /s | 8.4 % / 25 ms/s / 178 /s |
| Idle memory footprint | 22 MB | 85 MB |
| Launch → ready (CPU spent) | 245 ms (205 ms) | 1.17 s (0.86 s) |
| Record, static screen: CPU / own GPU | ≈14 % / ≈1 ms/s | ≈23 % / ≈33 ms/s |
| Record/stream, video playing: CPU / own GPU | ≈27–29 % / ≈10–12 ms/s | ≈26–29 % / ≈30–32 ms/s (both: ≈33 %) |
| Recording footprint (app + ffmpeg + encoder service) | ≈120–125 MB | ≈210–215 MB |
| Start request → output started | ≈400–410 ms | 150 ms (record) – 245 ms (both) |
| Stop request → finalized | ≈245–270 ms | ≈155 ms, both: ≈320 ms |
| Glass → loopback receiver, median / p95 | 257 / 296 ms | 178 / 203 ms |
| Start request → first received frame | ≈600 ms | ≈355 ms |
| Output | 29.98 fps, 0 gaps, 5.9–6.1 Mb/s | 30 fps, 0 gaps, 6.09 Mb/s |

Readings:

- **Where StreamApp is lighter.** It is far lighter idle and at launch. It uses ≈40 % less memory throughout and much less GPU in every scenario, because OBS composites every frame and StreamApp does not.
- **CPU depends on screen activity.** On a static screen StreamApp's CPU is ≈0.6× OBS's. When the screen changes every frame it is at parity for record or stream alone, and ≈0.8× for record + stream.
- **Where OBS is ahead.** OBS goes live faster and delivers frames ≈80 ms sooner.
- **Optimisation targets.** StreamApp's start latency, glass-to-wire latency and time to first received frame are candidate targets. None has been changed.
