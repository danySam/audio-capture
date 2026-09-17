# audio-capture

A macOS CLI tool that records both system audio and microphone input into a single `.m4a` file. Built for capturing meetings where you can't enable the app's built-in transcription.

## How it works

- **System audio** (other participants) is captured transparently via [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) — no virtual audio devices, no configuration changes in your meeting app
- **Microphone** (you) is recorded via AVCaptureSession using your default input device (or one you pick with `--device`)
- Both streams are merged into a single time-synced `.m4a` file when you stop recording

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
| `-h, --help` | Show help |

## Permissions

On first run, macOS will prompt for two permissions:

1. **Screen Recording** — required for system audio capture (even though no video is recorded)
2. **Microphone** — required for mic input

Grant both in **System Settings → Privacy & Security**. Your terminal app may need a restart after granting Screen Recording.

## License

MIT
