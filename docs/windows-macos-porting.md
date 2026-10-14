# Windows and macOS Porting Guide & Architecture Decisions

This document records the cross-platform changes made to prepare **GenerativeView** for Windows and macOS builds on top of the existing Linux and Android targets, and provides the native runner implementations (`windows/` and `macos/`) and CI recipes needed to complete the port.

## 1. Architectural Decisions in This Patch

### 1.1 Local Time Zone & Calendar Math (`core/src/dates.rs`)
- **Problem:** `core/src/dates.rs` relied on POSIX `extern "C" { fn tzset(); }` and `libc::localtime_r(&secs, &mut tm)`. On Windows MSVC (`x86_64-pc-windows-msvc`), the Universal CRT (`ucrtbase`) does not export `tzset` or `localtime_r`; instead it exports `_tzset()` and `localtime_s(tm: *mut libc::tm, time: *const libc::time_t)` with reversed arguments, and rejects negative `time_t` values (pre-1970).
- **Decision:** Split `init_zone()` and `local_tm(secs)` with `#[cfg(unix)]` and `#[cfg(windows)]`. On Windows, negative timestamps return `None` from `local_tm` so `local_day(ms)` falls back to deterministic civil division (`ms.div_euclid(86_400_000)`), avoiding CRT invalid-parameter assertions while keeping zero external crate overhead.

### 1.2 Forward-Slash Path Normalization (`core/src/fsnav.rs` & `lib/src/core/models.dart`)
- **Problem:** SQLite directory rows (`dirs.path`), `ItemList` binary packing, and Dart's `MediaItem.path` all join and split paths using `'/'`. On Windows, `std::fs::read_dir` and `USERPROFILE` emit backslashes (`\`) and extended-length prefixes (`\\?\`).
- **Decision:** Normalize all paths at the boundary via `fsnav::normalize_path` in Rust and `joinMediaPath` in `lib/src/core/models.dart`. Windows Win32 and Rust `std::fs` APIs accept forward-slash paths (`C:/Users/josh/Pictures/img.png`) natively, so standardizing on `'/'` keeps SQLite queries, notes sidecar lookups, and Dart UI models uniform across all four operating systems.

### 1.3 Per-OS Root & Volume Discovery (`core/src/fsnav.rs`)
- **Problem:** Desktop root discovery previously assumed Linux (`HOME`, `/proc/mounts`, and `"/"`) and only hid dot-prefixed folders (`.hidden`).
- **Decision:**
  - **Home directory:** Checks `HOME` first and falls back to `USERPROFILE` on Windows, populating `Home`, `Pictures`, `Downloads`, `Documents`, `Desktop`, and standard AI output folders (`ComfyUI/output`, `invokeai/outputs`, `stable-diffusion-webui/outputs`).
  - **Windows drives:** Enumerates `A:/` through `Z:/` and adds existing drive roots as `kind: "drive"`.
  - **macOS volumes:** Scans `/Volumes` via `discover_volumes_in`, skipping hidden entries and the `/` root symlink so mounted external drives and DMGs appear alongside `"File system"` (`/`).
  - **Hidden & system folders:** Filters `$RECYCLE.BIN` and `System Volume Information` by name on all platforms, and checks `FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM` via `MetadataExt::file_attributes()` on `#[cfg(windows)]`.

### 1.4 Atomic Sidecar Writes under File Watchers (`core/src/notes.rs`)
- **Problem:** `write_atomic` writes `.generativeview.json.<pid>.tmp` and calls `std::fs::rename(&tmp, path)`. On Windows, if `ReadDirectoryChangesW` (used by `notify`), Windows Search Indexer, or a reader thread briefly holds an open handle without `FILE_SHARE_DELETE`, `rename` transiently returns `PermissionDenied` or sharing violation (OS error 32).
- **Decision:** Added a 4-attempt retry loop with a 15ms backoff in `write_atomic` plus explicit target removal fallback if `AlreadyExists` is returned.

### 1.5 Dynamic Library Resolution (`lib/src/core/native_core.dart`)
- **Decision:** `NativeCore.resolveLibraryPath` checks `GVCORE_LIB` first and then selects `gvcore.dll` on Windows, `libgvcore.dylib` on macOS, and `libgvcore.so` on Linux and Android.

### 1.6 Desktop URL Launching & Primary Shortcut Modifiers (`lib/src/platform.dart`, `lib/src/ui/shortcut_layer.dart`)
- **Decision:**
  - `desktopUrlCommand` maps URL launching to `open <url>` on macOS, `rundll32 url.dll,FileProtocolHandler <url>` on Windows, and `xdg-open <url>` on Linux.
  - `isPrimaryShortcutModifier` maps primary shortcuts (`F`, `C`, `Shift+C`, `V`, `+`, `-`) to `Command` (`isMetaPressed`) on macOS and `Ctrl` (`isControlPressed`) on Windows, Linux, and Android.

### 1.7 Video Playback Dependencies (`pubspec.yaml` & PR #20 Context)
- **Decision:** Added `media_kit_libs_windows_video: ^1.0.11` and `media_kit_libs_macos_video: ^1.1.4` to `pubspec.yaml`. Unlike Linux (where `media_kit_libs_linux` requires system `libmpv.so.2` or the custom `tool/build-libmpv-bundle.sh` added in PR #20), the Windows and macOS `media_kit_libs_*_video` packages automatically download and bundle prebuilt `libmpv` + FFmpeg binaries during `flutter build windows` and `flutter build macos`.

## 2. Completing the Native Runner Scaffolding

### Step 1: Generate Flutter Runner Directories
From the repository root, generate the Windows and macOS host runners:
```bash
flutter create --platforms=windows,macos .
flutter pub get
```

### Step 2: Implement `generativeview/media` on Windows (`windows/runner/flutter_window.cpp`)
Register a `flutter::MethodChannel<flutter::EncodableValue>` named `"generativeview/media"` in `FlutterWindow::OnCreate` alongside `RegisterPlugins(flutter_controller_->engine())`:
1. **`copyFile` (`{'path': String}` -> `bool`):**
   - Convert the UTF-8 path to UTF-16 (`std::wstring`), replacing `/` with `\` for Win32 shell APIs.
   - Call `OpenClipboard(GetHandle())` and `EmptyClipboard()`.
   - Allocate `GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(DROPFILES) + (wpath.size() + 2) * sizeof(wchar_t))`.
   - Set `DROPFILES::pFiles = sizeof(DROPFILES)` and `DROPFILES::fWide = TRUE`, copy the double-null-terminated `wchar_t` path after the header, and call `SetClipboardData(CF_HDROP, hGlobal)` followed by `CloseClipboard()`.
2. **`pasteSource` & `readCopiedFile`:**
   - If `IsClipboardFormatAvailable(CF_HDROP)`, read the first file path via `DragQueryFileW(hDrop, 0, buf, MAX_PATH)` and return `{'path': utf8Path}` (for `pasteSource`) or the file's bytes (for `readCopiedFile`).
   - Otherwise check `RegisterClipboardFormat(L"PNG")` or `CF_DIB` and return `{'bytes': pngBytes, 'type': 'image/png'}`.
3. **`trashFile` (`{'path': String}` -> `String`):**
   - Convert `path` to a double-null-terminated UTF-16 string (`wpath.push_back(L'\0')`) with backslashes.
   - Populate `SHFILEOPSTRUCTW op = {}; op.wFunc = FO_DELETE; op.pFrom = wpath.c_str(); op.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT;`.
   - Call `int rc = SHFileOperationW(&op);` and return `"trashed"` when `rc == 0 && !op.fAnyOperationsAborted`, `"cancelled"` if aborted, or `"failed: code"` otherwise.
4. **Bundle `gvcore.dll` in `windows/CMakeLists.txt`:**
   ```cmake
   install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../core/target/release/gvcore.dll"
     DESTINATION "${INSTALL_BUNDLE_DIR}" COMPONENT Runtime)
   ```

### Step 3: Implement `generativeview/media` on macOS (`macos/Runner/MainFlutterWindow.swift`)
Register a `FlutterMethodChannel(name: "generativeview/media", binaryMessenger: flutterViewController.engine.binaryMessenger)` inside `MainFlutterWindow.awakeFromNib()`:
1. **`copyFile`:**
   ```swift
   let pb = NSPasteboard.general
   pb.clearContents()
   let ok = pb.writeObjects([NSURL(fileURLWithPath: path)])
   result(ok)
   ```
2. **`pasteSource` & `readCopiedFile`:**
   - Read file URLs first via `pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]`. If present, return `["path": url.path]` (or `try? Data(contentsOf: url)` for `readCopiedFile`).
   - Otherwise check `pb.data(forType: .png)` or convert `pb.data(forType: .tiff)` using `NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])`.
3. **`trashFile`:**
   ```swift
   do {
     try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
     result("trashed")
   } catch {
     result("failed: \(error.localizedDescription)")
   }
   ```
4. **macOS Entitlements (`macos/Runner/DebugProfile.entitlements` & `Release.entitlements`):**
   - For direct GitHub/DMG distribution outside the Mac App Store, set `com.apple.security.app-sandbox` to `false` in both `.entitlements` files so `gvcore` can freely traverse `/Users/...` and `/Volumes/...` and write `.generativeview.json` sidecar files, and ensure `com.apple.security.network.client` is `true` for Civitai and model downloads.
5. **Bundle `libgvcore.dylib`:**
   - Build `core` (`cargo build --release --manifest-path core/Cargo.toml`), set install name via `install_name_tool -id "@executable_path/../Frameworks/libgvcore.dylib" core/target/release/libgvcore.dylib`, and copy `libgvcore.dylib` into `build/macos/Build/Products/Release/generativeview.app/Contents/Frameworks/`.
