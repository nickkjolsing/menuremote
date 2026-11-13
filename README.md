![MenuRemote — Apple TV, from your menu bar. The app interface with sample playback and the remote expanded.](docs/images/menuremote.png)

<p align="center">
  <img alt="macOS 14 or later" src="https://img.shields.io/badge/macOS-14%2B-222222?logo=apple&amp;logoColor=white">
  <img alt="Apple silicon" src="https://img.shields.io/badge/Apple_silicon-arm64-7256a8">
  <a href="https://github.com/nickkjolsing/menuremote/actions/workflows/build.yml"><img alt="Build" src="https://github.com/nickkjolsing/menuremote/actions/workflows/build.yml/badge.svg"></a>
</p>

# MenuRemote

A native macOS menu bar remote for Apple TV. See what's playing and control playback.

- Artwork, playback progress, seeking, and 10-second skips
- Direction pad, keyboard controls, volume, and sleep/wake
- Automatic reconnect, device switching, and optional launch at login
- Manual in-app updates from GitHub Releases

## Install

**Requires:** Apple silicon, macOS 14+, and [uv](https://docs.astral.sh/uv/getting-started/installation/). Keep your Mac and Apple TV on the same local network.

Install uv (`brew install uv` with [Homebrew](https://brew.sh/)), then download the ZIP from [Releases](https://github.com/nickkjolsing/menuremote/releases/latest), unzip it, and move **MenuRemote.app** to `/Applications`.

Builds are ad-hoc signed, not notarized. macOS may block downloaded copies.

<details>
<summary>Build from source</summary>

Requires [Xcode Command Line Tools](https://developer.apple.com/xcode/resources/) in addition to uv.

```sh
xcode-select --install # Skip if already installed; finish before continuing.
git clone https://github.com/nickkjolsing/menuremote.git
cd menuremote
./build.sh --install
```

`--install` copies the app to `/Applications` and opens it. Without that flag, the app lands in `build/MenuRemote.app`.

</details>

On first launch, MenuRemote uses uv to download Python 3.13 and install pyatv 0.18.0 in its own environment.

## Pair & play

1. Click the Apple TV icon in your menu bar and select your TV.
2. Enter the four-digit code shown on the TV. A second code may be requested.
3. Click the remote icon to expand the direction pad. Use **⋯** to switch TVs or enable **Launch at Login**.

Use **⋯ → Check for Updates…** to look for a newer release and choose whether to install it. Updates preserve your pairing credentials. Automatic checks and installation are disabled.

Keyboard controls work while the panel is open and focused:

| Key | Action |
| --- | --- |
| Arrow keys / Return | Navigate / select |
| Space | Play / pause |
| Delete / `h` | Back / TV home |
| `[` / `]` | Skip back / forward 10 seconds |
| Escape | Close panel |

Volume, artwork, and seeking depend on the TV app and audio output.

## Troubleshooting

- **No TV found?** Check the local network connection and allow MenuRemote under **System Settings → Privacy & Security → Local Network**, if listed. Try scanning again.
- **TV missing from the list?** Choose **Show other devices** to see every discovered device. MenuRemote suggests TVs by their remote services; an unfamiliar model or software version doesn't prevent selection.
- **Setup failed?** Confirm uv is installed, then click **Retry**.
- **Connection lost?** Use **⋯ → Reconnect**. Logs: `~/Library/Logs/MenuRemote.log`.

Pairing credentials and the Python environment stay in `~/Library/Application Support/MenuRemote/`. Keep `pyatv.conf` private.

## Contributing

Small PRs welcome. Run `./build.sh` before submitting. For bugs, [open an issue](https://github.com/nickkjolsing/menuremote/issues) with your macOS/tvOS versions, steps to reproduce, and relevant redacted logs.

Use Conventional Commit PR titles: `fix:` for patches, `feat:` for features, `feat!:` for breaking changes. See [Releasing](docs/RELEASING.md) for the automated release process.

[MIT licensed](LICENSE). Built with SwiftUI and [pyatv](https://github.com/postlund/pyatv). Not affiliated with Apple.
