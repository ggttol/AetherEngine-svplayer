# SVPlayer modifications to AetherEngine

This repository is a modified version of [AetherEngine](https://github.com/superuser404notfound/AetherEngine)
by Vincent Herbst, based on upstream commit `572a8f7`. It is distributed under the same license as
upstream; see [LICENSE](LICENSE) (LGPL-3.0 with the upstream App Store / TestFlight exception).
The modified version is used by the SVPlayer app (iOS, iPadOS, macOS, tvOS).

All changes are in the commits on top of upstream history; `git diff 572a8f7` shows them in full.

## Summary of changes (2026-11-20, updated 2026-11-25)

- Audio packet tap: a public `audioTap` API that forwards the selected audio track's packets, decoded to
  PCM with their source timestamps, from the demux layer (HLS segment producer, software host and
  audio-only routes), plus seek and track-change notifications. Used for on-device subtitle recognition.
- Look-ahead audio reader built on `AVIOReader` (HTTP Range) that keeps audio decoded ahead of the
  playhead for the tap.
- Scrub-preview, end-of-media clock, renderer and audio-output fixes found during SVPlayer testing.
- Patent-sensitive traits (`TrueHDObjectAudio`, `DTSXObjectAudio`, `DualLayerDolbyVision`,
  `DolbyVisionFelCurves`, `DolbyVisionStillReshaping`) stay disabled.

Modified source files carry a `SVPlayer modification` comment at each change.
- 2026-11-21: foreground restore and background teardown fixes, AirPlay / Picture in Picture background handling, audio packet window de-duplication, and audit fixes (see SVPlayer modification comments in each file).
- 2026-11-23: audio packet tap moved to an event-driven serial queue (no blocking wait on a higher-QoS thread, fixing QoS priority-inversion warnings); ML upscaler timing capture fix; Picture in Picture area tracker main-actor fix.
- 2026-11-24: bitrate-aware forward buffer with seconds-based prefetch park/resume hysteresis and foreground-paused prefetch expansion; host-installed TLS trust for scoped self-signed origins (direct HTTPS instead of a local proxy); fix play intent being cleared during audio-shaping rebuilds (volume boost); Plex token stripped on cross-origin redirects; header-aware frame capture.
- 2026-11-25: directory thumbnail extraction for large LAN/cloud sources (bounded probe windows, keyframe offset strategy, HDR10/HLG tone mapping, MPEG-TS start-time handling, structured diagnostics); Dolby Vision profile 5 thumbnails are not decoded (placeholder fallback, patent traits stay off).
