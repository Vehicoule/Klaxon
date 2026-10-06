# ADR-0005 — Audio decoders and audio device

**Status**: Accepted (amended v16)
**Date**: 2026-10-06

## Context

The Vehicoule app needs audio playback: local files (mp3, flac, wav, ogg, opus) and streaming (opus, AAC). The framework needs an audio output path.

## Decision

**Audio device: SDL_AudioStream** (SDL3's audio API). **Decoders: dr_libs (mp3/flac/wav) + stb_vorbis (ogg) + libopus (opus) + OS decoder (AAC).**

miniaudio is removed from the spec (would duplicate SDL3's audio device + mixer + resampling for zero gain).

## Rationale

| Component | Choice | Why |
|---|---|---|
| Audio device | SDL_AudioStream | Already embedded (SDL3 for window/events/IME). No extra dependency. |
| MP3/FLAC/WAV | dr_libs | Public domain, single-header C, proven. |
| OGG Vorbis | stb_vorbis | Public domain, single-header C. |
| Opus | libopus | The standard for streaming. C, no Rust. |
| AAC | OS decoder (ffmpeg on Linux, AVFoundation on Apple, MediaCodec on Android) | AAC decoding is complex; OS decoders are hardware-accelerated and free. |
| Mixer/Resampling | SDL_AudioStream | Built into SDL3. |

## Consequences

- Audio lives in the **app** (Vehicule), not the framework. Klaxon provides the SDL3 bindings.
- `MediaSource` / `MediaEvent` types are the interface (prevents ad-hoc dribble around dr_libs).
- Gapless playback: next track's decoder starts before current track ends.
- Honest limitation: no sound card on CI VMs — audio validated on device only.
