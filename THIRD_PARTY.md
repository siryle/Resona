# Third-party notices

Resona is distributed under the GNU General Public License, version 3.
The complete license is included in `LICENSE`. Corresponding source is available
in the same repository and at each release tag.

The Go implementations in `internal/resona/plugins.go` and
`internal/resona/telegram.go` adapt the behavior of these MoviePilot plugins:

- MusicSaverBot, upstream version 1.0.45
- TelegramLocalApi, upstream version 1.0.12
- Author: Seed680
- Source: https://github.com/seed680/moviepilot-plugins
- Inspected revision: f4ab6ffb7c8495d28ebb98001c7422fb089e8740
- Upstream license: GPL-3.0

The adaptations integrate with Resona's Go service, authenticated API, atomic
storage, scanner and Web interface. No upstream Python runtime or MoviePilot
installation is required. Upstream version numbers on the plugin cards identify
the reference versions; they do not imply binary compatibility with MoviePilot.

The native Go local service in `internal/resona/telegram_local.go` implements
only the music saver's `getUpdates`, `getFile` and `sendMessage` operations.
It uses the pure Go MTProto implementation Gogram:

- Source: https://github.com/amarnathcjd/gogram
- Author: @AmarnathCJD and contributors
- Version: v1.8.0-beta.11
- Revision: a5c7f2c8da409e93d80f12d16eb8d76ebbc7eeb8
- License: GPL-3.0
- The required source and license are checked in under
  `vendor/github.com/amarnathcjd/gogram`; checksums are recorded in `go.sum`.
- This dependency is unmodified. The Resona adapter and its durable queue,
  bounded downloads, proxy configuration and authenticated loopback endpoints
  are maintained in this repository.

Building the Go service with `-mod=vendor` requires no module download. The
Docker image does not download, compile or include Telegram Bot API or TDLib.

Telegram, FFmpeg, operating system packages, and Apple frameworks retain their
respective licenses. No Telegram credentials are supplied with Resona.

The 115 source integration adapts the Cookie QR login and stable STRM / redirect
workflow of DDSRem-Dev/MoviePilot-Plugins:

- Source: https://github.com/DDSRem-Dev/MoviePilot-Plugins
- Reference: `plugins.v3/p115strmhelper/api.py`, `helper/strm/full/__init__.py`,
  `helper/useragent.py`, `helper/r302/__init__.py` (`get_downurl_cookie`),
  and its p115client adapter
- Device choices and refresh behavior: `frontend.v3/p115strmhelper/src/components/composables/useQrCode.js` and `dialogs/QrCodeDialog.vue`
- Inspected revision: 3d8c516084c3adcd60b29e24dbcf35fc3effbee7
- License: GPL-3.0
- Uses the reference's seven login devices, defaulting to `alipaymini`; no Open API app ID,
  embedded account Cookie, or MoviePilot/Python runtime is included.
- The Cookie download request follows the Android endpoint with only an RSA-encrypted
  `pick_code`, exact player User-Agent, and UA-scoped link caching. The reference
  uses HTTP; Resona defaults to HTTPS and requires explicit opt-in for cleartext
  HTTP compatibility. Neither its metadata 405 fallback nor HTTP compatibility
  guarantees removal of persistent account/IP restrictions.

The RSA/XOR download framing in `internal/resona/cloud115_crypto.go` is adapted
to Go from p115cipher, by ChenyangGao:

- Source: https://github.com/ChenyangGao/p115client/tree/main/modules/p115cipher
- File information lookup also follows the `fs_file` protocol in
  `p115client/client.py` (`/files/get_info`).
- Reference version: 0.0.6
- Inspected revision: 856e4f8f09ce034534bd458f06d3dee4474a1698
- License: GPL-3.0 (the complete license is included in `LICENSE`)
- The implementation uses Go's standard RSA request encryption and validates
  response framing. No upstream Python package or extra runtime is required.

Authorization QR images use the unmodified Go QR encoder:

- Source: https://github.com/skip2/go-qrcode
- Revision: da1b6568686e
- Version: v0.0.0-20200617195104-da1b6568686e
- License: MIT; source and license are vendored in this repository.

Copyright (c) 2014 Tom Harwood

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## Android / Windows client

The shared client in `clients/resona` uses unmodified Flutter packages, pinned
in `pubspec.lock`:

- Flutter and Dart: https://github.com/flutter/flutter (BSD-3-Clause)
- media_kit and media_kit_libs_audio: https://github.com/media-kit/media-kit (MIT)
- flutter_secure_storage: https://github.com/juliansteenbakker/flutter_secure_storage (BSD-3-Clause)
- path_provider: https://github.com/flutter/packages (BSD-3-Clause)
- crypto: https://github.com/dart-lang/core/tree/main/pkgs/crypto (BSD-3-Clause)
- audio_service: https://github.com/ryanheise/audio_service (MIT)
- audio_session: https://github.com/ryanheise/audio_session (MIT)

Flutter includes package notices in its generated license registry, available
from the client Settings page. Delivery packages also include this file and
Resona's complete GPL-3.0 license. Android distribution keys are user-supplied;
none are included in the repository.

media_kit's platform packages bundle native libmpv / FFmpeg audio libraries.
These components retain their own GPL / LGPL and codec licenses, not the MIT
license of the Dart wrapper. Their corresponding source, build recipes and
patches are published by the binary providers:

- Android: https://github.com/media-kit/libmpv-android-audio-build
- Windows: https://github.com/media-kit/libmpv-win32-audio-build
- mpv: https://github.com/mpv-player/mpv
- FFmpeg: https://ffmpeg.org/legal.html

The native binary revisions are selected by the pinned platform packages in
`pubspec.lock`. Distributors must preserve these notices and provide the
corresponding source for their exact binaries under the applicable licenses.
