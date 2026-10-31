# Third-party notices

GenerativeView is released under the [MIT License](LICENSE). It is built on,
ships with, or downloads the work of others, under their own licences. All of
them permit releasing GenerativeView under MIT; their notices travel with the
app and are shown in full under **More (⋮) → About → Open-source licences**.

## What is compiled into the app

| Part | Licence | Notices |
| --- | --- | --- |
| Flutter engine and framework, Dart packages | BSD-3-Clause, MIT, Apache-2.0, MPL-2.0 (`dbus`, unmodified, from pub.dev) | Collected by Flutter itself |
| Rust crates in the core (`core/Cargo.lock`) | MIT, Apache-2.0, BSD, ISC, Zlib, BSL-1.0, CC0-1.0, Unicode-3.0, IJG | `assets/licenses/rust.txt.gz` |
| SQLite (bundled by `rusqlite`) | Public domain | `assets/licenses/other.txt.gz` |
| English word list (pyspellchecker) | MIT | `assets/spelling/LICENSE-pyspellchecker.txt` |

`assets/licenses/rust.txt.gz` is generated from `core/Cargo.lock` by
`tool/gen-licenses.py`; CI fails if a dependency changes without it being
re-run. The script also refuses any crate available only under a copyleft
licence.

## Shared libraries shipped beside the app

Video playback uses **libmpv** and **FFmpeg**, both under the GNU LGPL,
version 2.1 or later. They are separate shared libraries, built without
their GPL-only parts, and may be replaced with your own builds.

- **Android**: libmpv and FFmpeg from
  [media_kit](https://github.com/media-kit/libmpv-android-video-build)
  (its default build, which leaves out the GPL-only parts).
- **Linux AppImage**, only used where the system has no libmpv: mpv v0.35.1
  built with `-Dgpl=false`, FFmpeg n5.1.6 without `--enable-gpl`, and dav1d
  (BSD-2-Clause), from the upstream sources by
  [`tool/build-libmpv-bundle.sh`](tool/build-libmpv-bundle.sh). The bundle
  carries every licence in its `mpv/licenses` folder, including the Debian
  copyright file of each system library it brings along (such as libass,
  ISC).

## Downloaded on request, not shipped

- **Real-ESRGAN** upscale models — BSD-3-Clause, © 2021 Xintao Wang.
- **DataComp CLIP ViT-B/32** content-search model, trained by LAION with
  OpenCLIP — MIT.

## Built with

The About panel lists and links every project above. Thank you to all of
their authors.
