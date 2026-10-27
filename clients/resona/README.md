# Resona Android / Windows

Shared Flutter client for Android phones, Android tablets and Windows x64.
The existing Swift clients remain the iOS / macOS implementation.

## Features

- Android follows the iOS listening / library / downloads / search / settings
  structure, with a mini-player above the phone tab bar and a navigation rail on
  tablets. Windows follows the macOS sidebar, search header and persistent
  playback footer. Supports resizing, rotation, text scaling and light / dark themes.
- Windows opens playback details within the main workspace: a record and album
  information beside synchronized, clickable lyrics, with the sidebar and
  playback footer still available. Narrow windows stack artwork above lyrics.
- Launch directly into music, with server connection in Settings. Tokenless
  account identity restores local audio after logout; expired credentials or an
  unreachable server never block access to cached music.
- Server login and OS-protected session storage (Android encrypted storage,
  Windows Credential Manager), including reverse-proxy path prefixes.
- Local / cloud libraries, paginated songs, albums, artists, search and favorites.
- Native libmpv audio playback, seeking, previous / next, list repeat and LRC
  lyrics. Android media notification, media buttons and background playback use
  a foreground media service; audio focus and headphone removal pause playback.
- Played songs are downloaded in the background, verified with the server's
  SHA-256 or 115 SHA-1 when available, then published to an account-isolated
  cache. Incomplete downloads are never listed offline. Cached lyrics and covers
  are snapshots; clear playback cache in Settings to fetch newer versions.
- Manual song downloads include audio, cover and lyrics, and remain accessible
  without login. Cache cleanup stops playback, cancels active transfers and waits
  before deleting automatic cache; it preserves manually downloaded songs.
  Remove manual downloads explicitly from their song menu.
- A randomly addressed loopback relay handles native decoder requests and HTTP
  Range. Redirects are checked individually; the Resona bearer token is sent
  only to the configured server origin, never to a 115 CDN. TLS verification is
  enabled. HTTP is supported for LAN servers but is not recommended on public
  networks. No 115 Cookie is stored in the client.

## Build

Use Flutter **3.47.8** stable, JDK 17 and Android SDK for Android, or Visual Studio
with the Desktop development with C++ workload for Windows. Android requires
Android 7.0 / API 24 or newer. Windows requires Windows 10 / 11 x64 and the
Microsoft Visual C++ runtime, which is included in the installer. Run the EXE
installer to install or upgrade Resona in its existing location. Login, downloads
and playback state remain in the user's application data directory. Previously
extracted ZIP copies are not registered installations; install once with the EXE
and remove the extracted program files when no longer needed.
See the official [Android setup](https://docs.flutter.dev/platform-integration/android/setup)
and [Windows setup](https://docs.flutter.dev/platform-integration/windows/setup).

From the repository root:

```sh
cd clients/resona
flutter pub get --enforce-lockfile
flutter analyze --fatal-infos
flutter test
cd ../..
python3 scripts/build-clients.py android
# On Windows:
python scripts/build-clients.py windows
```

Windows packaging also requires Inno Setup **6.7.1** or newer. The installer has
a stable application ID, a Start menu entry, an optional desktop shortcut and an
uninstaller. It reuses the previous installation directory, supports same-version
repair and rejects downgrades. Its wizard uses the compiler's bundled English
messages. On disposable GitHub Actions runners, packaging tests an older
registered fixture followed by an upgrade without a directory argument, verifies
installed files, tests repair and downgrade rejection, and uninstalls the app.

`VERSION.json` is the only release version source. The script passes its version
and build to Flutter, verifies the APK manifest / EXE version and writes versioned
packages and SHA-256 files under `dist/`. `pubspec.yaml` contains only a development
placeholder; do not increment it for releases. Use the build script for delivery.

Without signing credentials, Android builds use a development certificate and
are named `-preview.apk`. They can be sideloaded but different build machines
may use different keys, so replacing a preview can require uninstalling it
(which removes local credentials and cached audio). For updateable APKs provide
all four environment variables:

- `RESONA_ANDROID_KEYSTORE`: absolute path to a protected keystore
- `RESONA_ANDROID_STORE_PASSWORD`
- `RESONA_ANDROID_KEY_ALIAS`
- `RESONA_ANDROID_KEY_PASSWORD`

Never commit signing material. Windows packages are not Authenticode-signed;
Windows may show a SmartScreen warning. iOS still requires user signing, and
macOS builds retain their existing ad-hoc signing convention.

## GitHub Actions

`.github/workflows/clients.yml` tests and builds Android, Windows, iOS and macOS
on their respective GitHub-hosted runners. Gitea mirrors source and version tags
to the public GitHub repository. Pushing a `v<version>-<build>` tag builds every
client, Linux server packages and Docker images, then publishes verified packages
and SHA-256 files to GitHub Releases. Multi-architecture Docker images are also
published to GHCR. Build intermediates are available in the run's **Artifacts**.
Published versions are immutable; rerunning a published tag skips rebuilding.

Configure `ANDROID_KEYSTORE_BASE64`, `ANDROID_STORE_PASSWORD`,
`ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD` as GitHub Actions secrets to sign
Android builds. Without them the workflow produces previews. Pull requests use
preview signing without access to distribution keys. Pull requests test and
build all platforms without publishing releases or pushing container images.
The workflow requires GitHub Actions; Gitea only stores and mirrors source.

## Device Verification

Unit / widget tests cover navigation breakpoints at 390 / 800 / 1280 logical
pixels with 1.3× text and both themes, login validation, LRC parsing, API path
prefixes, account-isolated cache commits, integrity failure and redirect policy.
Before a production rollout, also test Android phone and tablet rotation,
background playback, headset unplugging, process restart / login persistence,
cache cleanup and Windows resizing / actual device audio. Emulator and widget
tests do not substitute for hardware audio and power-management tests.
