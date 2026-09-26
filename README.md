# audio-capture

A macOS CLI tool that records both system audio and microphone input into a single `.m4a` file. Built for capturing meetings where you can't enable the app's built-in transcription.

## How it works

- **System audio** (other participants) is captured transparently via [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) — no virtual audio devices, no configuration changes in your meeting app
- **Microphone** (you) is recorded via AVCaptureSession using your default input device (or one you pick with `--device`)
- Both streams are mixed in real time on a shared clock and written straight to a single `.m4a`, so there's no merge step when you stop
- When stdout is piped, the mixed audio is also streamed live as raw PCM for other tools to consume

No new audio devices appear in your system. Google Meet, Zoom, and other apps don't need any settings changes.

## Requirements

- macOS 14 (Sonoma) or later
- First run will prompt for **Screen Recording** and **Microphone** permissions

## Install

```
make
make install  # installs to /usr/local/bin
```

## Usage

```
audio-capture                              # start recording, Ctrl+C to stop
audio-capture -n "standup"                 # label the recording
audio-capture -n "1on1" -o ~/Audio         # custom output directory
audio-capture -l                           # list available microphones
audio-capture -d "USB" -n "standup"        # use a specific mic
```

Files are saved to `~/Recordings/` by default:

```
~/Recordings/2026-09-17_14-30-00_standup.m4a
```

### Options

| Flag | Description |
|------|-------------|
| `-n, --name <label>` | Label appended to the filename |
| `-d, --device <name>` | Microphone to use (substring match) |
| `-l, --list-devices` | List available microphones |
| `-o, --output <dir>` | Output directory (default: `~/Recordings`) |
| `-r, --pipe-rate <hz>` | Sample rate of piped audio (default: `16000`) |
| `-h, --help` | Show help |

### Piping audio to other tools

When stdout isn't a terminal, `audio-capture` streams the mixed audio as raw PCM while still saving the `.m4a`:

- Format: signed 16-bit little-endian, mono, 16 kHz (change with `--pipe-rate`)
- Status messages go to stderr, so they never mix into the audio stream

```
audio-capture -n project-1 | transcribe -o project_1_transcript.txt
audio-capture | ffmpeg -f s16le -ar 16000 -ac 1 -i - live.wav
```

If the downstream tool falls behind, piped audio is dropped (with a warning) rather than stalling the recording. If it exits, recording continues to the file.

Pressing Ctrl+C in a pipeline signals every process in it, so the downstream tool may stop at the same moment. To stop only the recorder, run `pkill -INT audio-capture` from another terminal.

### Live transcription

`make install` also installs `transcribe`, a small Python script (standard library only) that transcribes the piped audio live with [whisper.cpp](https://github.com/ggml-org/whisper.cpp):

```
brew install whisper-cpp
mkdir -p ~/.whisper-models
curl -L -o ~/.whisper-models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin

audio-capture -n standup | transcribe -o standup.txt
```

```
[00:00:04] This is a live test of the audio capture pipeline. The quarterly numbers are up 12%
[00:00:10] and we should review the hiring plan on Monday
```

It runs a local `whisper-server` so the model loads only once. The audio is split into ~8 second chunks at the quietest moment, so words aren't cut in half. Timestamps are relative to the start of the recording, so they line up with the `.m4a`.

Ctrl+C is safe here: `transcribe` keeps running until `audio-capture` finishes flushing, transcribes the last chunk, then exits. Press Ctrl+C twice to quit immediately.

| Flag | Description |
|------|-------------|
| `-o, --output <file>` | Also append the transcript to this file |
| `-m, --model <path>` | Model file (default: `$WHISPER_MODEL` or `~/.whisper-models/ggml-large-v3-turbo.bin`) |
| `-l, --language <code>` | Spoken language, or `auto` (default: `en`) |
| `-c, --chunk <seconds>` | Seconds of audio per request (default: `8`) |
| `-r, --rate <hz>` | Input sample rate, must match `--pipe-rate` (default: `16000`) |

## Permissions

On first run, macOS will prompt for two permissions:

1. **Screen Recording** — required for system audio capture (even though no video is recorded)
2. **Microphone** — required for mic input

Grant both in **System Settings → Privacy & Security**. Your terminal app may need a restart after granting Screen Recording.

## License

MIT
