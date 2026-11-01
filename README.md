# hex-ios-keyboard

An iPhone keyboard with a single button: **hold to talk, let go to type.** Your voice is
transcribed on your Mac by [Hex](https://github.com/vkpdeveloper/anomaly-hex), and the text is
typed into whatever app you're using.

- One big mic button, plus 🌐, return and delete keys
- Haptic tap when listening starts and when it stops
- Transcription runs locally on your Mac (about 70–100 ms per clip with Parakeet)
- A Mac dashboard covers setup, live status and a searchable history with audio playback
- Pair the phone by scanning a QR code; no IP addresses to type

This is a personal tool that you install from Xcode; it's not on the App Store.

## How it works

```
 iPhone                                                Mac
┌──────────────────────────┐   start/stop   ┌───────────────────────┐
│ hex-ios-keyboard         │ ─────────────▶ │ hex-ios-keyboard app  │
│ (keyboard extension)     │                │ (records the mic)     │
│ hold → listen            │ ◀───────────── │                       │
│ release → type text      │   text         └──────────┬────────────┘
└──────────────────────────┘                           │ 16 kHz WAV over Wi-Fi
                                                       ▼
                                         ┌─────────────────────────────┐
                                         │ mac-server (Bun)            │
                                         │  ├─ Hex engine (Parakeet)   │
                                         │  ├─ dashboard :8787         │
                                         │  └─ history ~/.config/…     │
                                         └─────────────────────────────┘
```

iOS doesn't let keyboards use the microphone. So the keyboard remote-controls its own app,
which records in the background. The first time you dictate (and again after 5 idle minutes),
the keyboard opens the app to start a session. Tap **◀** in the top-left to go back, then hold
the mic.

## Requirements

- A Mac with [Hex](https://github.com/vkpdeveloper/anomaly-hex) installed in `/Applications`
  (the Hex app doesn't need to be open)
- [Bun](https://bun.sh) 1.1 or later
- Xcode 16 or later, and a free or paid Apple ID
- An iPhone on iOS 17 or later, on the **same Wi-Fi** as the Mac

## Run it

### 1. Start the Mac server

```bash
cd mac-server
bun install
bun start
```

The dashboard opens at <http://localhost:8787>. It walks you through the remaining steps and
ticks each one off as it's done. Leave this terminal running while you dictate.

### 2. Install the app on your iPhone

1. Plug in your iPhone and unlock it. If it asks, tap **Trust This Computer**.
2. In Xcode → **Settings → Accounts**, add your Apple ID.
3. Open `ios/hex-ios-keyboard.xcodeproj`.
4. Select the **VoiceKeyboard** target → **Signing & Capabilities** → choose your **Team**.
   The project is set up for team `TA2H8548F2`; to use a different one, change
   `DEVELOPMENT_TEAM` in `ios/project.yml` and run `xcodegen generate`. If the bundle ID is
   taken, change `com.niraj` there too.
5. Pick your iPhone at the top of the window and press **Run ▶**.
6. First time only, on the iPhone:
   - Settings → Privacy & Security → **Developer Mode** on (the phone restarts)
   - Settings → General → VPN & Device Management → tap your Apple ID → **Trust**

To build and install from the terminal instead, find your device ID with
`xcrun devicectl list devices` and run:

```bash
cd ios
xcodebuild -project hex-ios-keyboard.xcodeproj -scheme VoiceKeyboard \
  -destination 'platform=iOS,name=<your iPhone name>' \
  -allowProvisioningUpdates -derivedDataPath build build
xcrun devicectl device install app --device <device-id> \
  build/Build/Products/Debug-iphoneos/VoiceKeyboard.app
```

> With a free Apple ID, the app stops opening after 7 days. Press Run again to reinstall it.
> Your settings are kept.

### 3. Set up on the iPhone

Open **hex-ios-keyboard**. It shows three steps that tick themselves off:

1. **Connect to your Mac.** Open the iPhone **Camera**, point it at the QR code on the
   dashboard, and tap the yellow link that appears. If you can't scan it, tap *Type the code
   instead* and enter the code shown on the dashboard. The app finds your Mac on the network, and
   finds it again if its IP changes.
2. **Allow the microphone.**
3. **Add the keyboard.** Tap **Open Settings** → **Keyboards** → turn on **hex-ios-keyboard**
   and **Allow Full Access**. Full Access lets the keyboard talk to the app and play haptics;
   your audio is only ever sent to your own Mac. Then switch to the keyboard once in the app's
   *Try it* box.

### 4. Dictate

In any app: tap 🌐 to switch to hex-ios-keyboard. **Hold** the mic. When you feel the tap and
see *Listening…*, talk. **Let go** and the text is typed in.

## Mac dashboard

<http://localhost:8787> only opens on the Mac itself; other devices get `403`.

- **Status:** whether the server is running, the Hex engine's state (download progress, loading
  or ready) and when your iPhone was last seen
- **Setup:** five steps, plus the pairing QR code until your phone connects
- **History:** every clip with its text, length and transcription time. You can search it, play
  the audio, copy the text, **Show in Finder**, or clear it all.

History is stored in `~/.config/hex-ios-keyboard/`: `history.jsonl` holds the text and `audio/`
holds the WAV files. The pairing code is in `token` there; delete that file to make a new one,
then pair the phone again.

### Server options

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8787` | Port the server listens on |
| `HEX_MODEL` | `parakeet_unified_en` | Hex model ID (list them with `hex model list`) |
| `HEX_LANGUAGE` | `en` | Language code passed to Hex |
| `HEX_BIN` | `/Applications/Hex.app/Contents/MacOS/hex` | Path to the Hex executable |
| `HEX_KEYBOARD_TOKEN` | stored in `~/.config/hex-ios-keyboard/token` | Override the pairing code |
| `NO_OPEN` | not set | Set to `1` to skip opening the dashboard in a browser |

## Microphone modes

In the app under **Microphone**:

- **Mic only while holding** (default): between holds the app stays alive by playing silence,
  and the mic (and the orange dot) turns on only while you hold. If iOS refuses to turn the mic
  on in the background, the app switches to the other mode by itself and tells you.
- **Off:** the mic stays on during a session so recording starts instantly. Audio outside a hold
  is thrown away on the phone.

Either way, a session ends after 5 minutes without a dictation, or when you tap **Turn off**.

## Troubleshooting

| What you see | What to do |
|---|---|
| "Can't find your Mac" | Check that `bun start` is running and both devices are on the same Wi-Fi. On the Mac, allow incoming connections for `bun` (System Settings → Network → Firewall). |
| Holding the mic does nothing | Turn on **Allow Full Access** for hex-ios-keyboard. |
| The keyboard opens the app every time | That's how a new session starts. Tap ◀ to go back; holds work until the session times out. |
| "Untrusted Developer" or the app won't open | Settings → General → VPN & Device Management → trust your Apple ID. With a free Apple ID, reinstall from Xcode every 7 days. |
| Text comes back empty | Open the clip in the dashboard's History and play it. If it's silent, turn **Mic only while holding** off. |
| Hex engine shows "Not working" | Check that Hex is in `/Applications`, or set `HEX_BIN`. The error is shown on the dashboard. |

## Project layout

```
mac-server/
  server.ts          Bridge to Hex: POST /transcribe, GET /health, Bonjour, dashboard API
  dashboard.html     Setup, status and history page
ios/
  project.yml        XcodeGen spec (the .xcodeproj is generated from this)
  VoiceKeyboard/     The app: setup screen, background recorder, Mac connection
  Keyboard/          The keyboard extension: hold-to-talk UI and haptics
  Shared/            State shared through the App Group, and Darwin notifications
  tools/make_icon.py Draws the app icon
```

How the pieces talk to each other:

- **Keyboard → app:** Darwin notifications (`start`, `stop`, `cancel`)
- **App → keyboard:** `state.json` in the App Group container (`group.com.niraj.voicekeyboard`),
  which the keyboard reads 10 times a second
- **App → Mac:** `POST /transcribe` with a WAV body and `Authorization: Bearer <code>`
- **Pairing:** the QR code encodes `voicekb://pair?url=…&token=…`

### Development

- After adding or renaming files under `ios/`, run `xcodegen generate` in `ios/`
  (`brew install xcodegen`).
- To redraw the icon: `python3 ios/tools/make_icon.py ios/VoiceKeyboard/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
  (needs Pillow).
- To type-check the server: `cd mac-server && bunx tsc --noEmit`.
