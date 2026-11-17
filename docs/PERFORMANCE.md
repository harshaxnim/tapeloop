# Tapeloop performance report

**Date:** 17 November 2026 · **Build:** 0.1.0, release configuration · **Machine:** MacBook Air, Apple M2,
macOS 14.6 · **Conditions:** an ordinary working session (browser, editor, terminal) running alongside.

> **Measure your own Mac.** Open Tapeloop, let it record for a minute, then run
> `scripts/measure-performance.sh` (about one minute). It prints the same figures for your hardware.

**Summary.** Tapeloop is one process. While it records your microphone and your Mac's sound, it uses about 1 % of
one CPU core, 13 MB of memory plus the audio it holds (about 22 MB per hour per source at the default quality),
8 threads and 0.1 wake-ups a second, and it writes nothing to disk. There are no helper processes, no WebView and no
`ffmpeg`.

---

## 1. The running app

Both sources recording, the popover closed, measured over 2 minutes with the kernel's own accounting
(`proc_pid_rusage`, the source of Activity Monitor's figures), `leaks`, `vmmap` and `sample`.

| Measure | Before the performance work | Now |
|---|---:|---:|
| CPU | 2.2 % of one core | **1.1 %** |
| Memory (physical footprint, Activity Monitor's "Memory") | 175 MB after 13 minutes, growing | **13.4 MB**, flat |
| Peak memory since launch | 41 MB | **13.4 MB** |
| Threads | 11 | **8** |
| Wake-ups from idle | not measured | **0.1 a second** |
| Disk written | 0 | **0 bytes** |
| Leaks (`leaks`) | about 94 objects a second never freed | **0** |
| Processes | 1 | **1** |

The audio held comes on top of the 13 MB. At the default 48 kbps it is about 22 MB per hour per source, so the
default 2-hour buffer of both sources is about 89 MB. Above the memory limit (500 MB by default) the buffer is
shortened, or, if you allow it, its older part goes to disk.

### Where the remaining time goes

A 10-second `sample` of the recording app: almost all of the CPU time is Apple's AAC encoder compressing the two
sources (`AudioCodecs`: psychoacoustic model, quantization), then format conversion. Tapeloop's own code
(buffering, level meters, timestamps) is a small part. Meeting detection costs nothing between meetings.

### What changed

| Change | Effect |
|---|---|
| Every audio callback drains an autorelease pool | Fixed a leak: each system-audio callback left its buffer object behind (about 94 a second, over 50 MB an hour) |
| The microphone is read directly from Core Audio instead of through `AVAudioEngine` | Fewer threads, no parameter-refresh thread |
| Both sources ask for 4096-frame IO buffers (85 ms) instead of the default 512 (11 ms) | About 8 times fewer audio wake-ups; other apps' audio is not affected (the setting is per process) |
| The encoder reuses its output and conversion buffers; level meters use vector instructions (`vDSP`) | No allocation per callback |
| Finished chunks are stored at their exact size | Before, a chunk could hold up to twice its size, and memory crept up over hours |
| Meeting detection listens for Core Audio changes instead of polling every 2 s | Nothing runs between meetings; it polls only while a meeting starts, runs or ends |
| The popover view, the speech-language list (about 60 recognizers) and the calendar store are made on first use | Launch peak fell from 41 MB to 13 MB |
| Settings and Library free their memory when closed; the popover's 1-second timer runs only while it is open | Nothing wakes the app while you are not looking |

## 2. Stress, soak and leak tests

`TapeloopBench` drives the real recorder engine, encoder, buffer, disk spill and exporter with synthetic audio,
much faster than real time (see [TESTING.md § 1.1](TESTING.md)).

| Test | Result |
|---|---|
| **Soak:** 4 h of two-source audio into the default 2 h buffer | 24 s of CPU per hour of audio (0.66 % of one core). Buffer exactly 2 h; process memory levels off at about 115 MB for 89 MB of audio. Saving 2 h takes 0.1 s. Wipe empties memory and disk. |
| **Soak with disk:** 6 h into a 5 h buffer, 50 MB memory limit | Memory stays at the limit, 59 MB goes to disk, memory levels off. Saving 5 h (108 MB) takes 1.1 s. |
| **Sponge:** 21 formats (8 to 192 kHz; 1, 2, 6 channels); empty, one-frame and huge buffers; NaN, infinite and out-of-range samples; timestamps that go back, repeat or jump hours; 200 rounds of settings changes, pauses, memory warnings, saves and wipes while audio flows | All checks pass, 0 leaks. Found and fixed one bug: setting the Mac's clock back left the buffer out of order. |
| **Speech model:** load, transcribe 43 s of speech, unload, three times | First load 30 s (disk read and one-time GPU shader compilation), then 0.02 s. 43 s of speech in 11 to 14 s. About 83 MB while loaded. About 50 MB of GPU framework caches stay after the first use and do not grow. |
| **Meeting listeners** (`TapeloopBench watch`) | No calls while nothing changes; a new audio process is reported at once. |

Saving does not re-encode: the AAC packets are copied into the file, so a save of hours takes about a second.

## 3. Compared with Rewinder

[Rewinder](https://github.com/abhinavkale-dev/rewinder) is an open-source instant-replay app for the Mac that records
the screen, the system audio and the microphone. Its
[performance report](https://github.com/abhinavkale-dev/rewinder/blob/main/PERFORMANCE_REPORT.md) (10 July 2026,
a 64 GB Apple silicon Mac under heavy load) is a useful reference. Its video figures are left out here, because
Tapeloop records no video. The comparison is rough: different machines and loads, and Rewinder's capture helper
handles audio and video together, so its audio share cannot be separated.

| | Rewinder (native build) | Tapeloop |
|---|---|---|
| Processes while recording | 3: app, ScreenCaptureKit helper, `ffmpeg` | **1** |
| App process memory | 33 MB (peak 73 MB); capture and encoding run in other processes | **13.4 MB (peak 13.4 MB)** including capture and encoding, plus the audio held |
| Audio processing CPU | `ffmpeg` at 26 to 35 % of one core, mostly software audio processing (noise removal, mixing, gain) | **1.1 %** for capturing and encoding both sources |
| App process CPU | 0.3 to 1.4 % | 1.1 % (the whole recorder) |
| Where the buffer lives | Encoded segments on disk: memory stays flat at any length | Encoded audio in memory: nothing written; memory grows with length (89 MB for 2 h), disk only past the limit |
| Disk writes while recording | 0.4 to 1.3 MB/s (mostly video) | **0** |
| Battery | Lowers the video frame rate on battery | No special mode; at 1 % CPU and 0.1 wake-ups a second there is little to cut |
| Microphone processing | Noise removal (RNNoise) and gain | None: the audio is kept as heard |
| App size | 94 MB (90 MB of it `ffmpeg`) | **19 MB** (13 MB of it the optional transcription engine); DMG 9.2 MB |
| Self-measurement | `scripts/measure_performance.sh` | `scripts/measure-performance.sh` |

**Where Tapeloop is lighter:** one process with nothing in between; no disk writes; audio encoding at a small
fraction of the CPU of a software audio chain; a smaller app.

**Where Rewinder's design is better for some uses:** keeping the buffer on disk keeps memory flat however long
the buffer is. Tapeloop trades memory for zero disk writes, and offers disk only as an overflow past a limit.
Rewinder also cleans up the microphone (noise removal), which Tapeloop does not do.

## 4. How to measure

```sh
scripts/measure-performance.sh                     # the running app: CPU, wake-ups, disk, memory, threads, leaks
swift build -c release --product TapeloopBench
.build/release/TapeloopBench soak 4                 # the soak test
.build/release/TapeloopBench sponge --leaks         # the sponge test, then leaks
sample $(pgrep -x Tapeloop) 10 -file sample.txt     # where the CPU time goes
```

Caveats: one machine; CPU depends on the quality setting (32 to 96 kbps) and on how many sources are on; memory
depends on the buffer length. `ps` RSS overcounts shared frameworks; the physical footprint (`vmmap --summary`,
Activity Monitor's "Memory") is the figure to compare.
