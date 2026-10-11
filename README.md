# GenerativeView

A fast image browser for folders of AI-generated images, for Linux and Android.

Point it at an output folder and it shows a resizable grid of everything in it, reads the generation metadata out of each file (ComfyUI, InvokeAI, A1111/Forge), and lets you search the folder by prompt, model, LoRA, seed or file name. Tap any value to copy it; press and hold one to see every image that shares it.

![The grid with search results and the metadata panel](docs/screenshot-metadata.png)

## What it does

- **Grid** of images and videos from a folder and, optionally, its sub-folders. Resize tiles with the slider, pinch, `Ctrl` + scroll or `Ctrl` `+`/`-`. The crop button (or `C`) switches tiles between cropped-to-fill and showing the whole image.
- **Focus view**: double tap (or `Enter` / `Space`) opens one image; swipe or use the arrow keys to move through the folder; pinch or turn the scroll wheel to zoom; double tap (or `Enter` / `Space` / `Esc`) to go back.
- **Zoom** is measured against the image's real size and moves in steps of 10 %: each notch of the wheel goes to the next multiple of ten, and a pinch settles on the nearest one when you let go. A chip shows the percentage while you zoom; it turns blue, and stays, at exactly 100 % (one image pixel per screen pixel). The size at which the image just fits the window is a stop too. You can zoom out as far as that, or as far as 100 % when fitting the window means enlarging the image.
- **Metadata panel** on the right for the selected image: prompt, negative prompt, seed, model, LoRAs with weights, other models (VAE, text encoders, ControlNet, upscalers), sampler settings, the full ComfyUI node graph, and the raw JSON exactly as stored. Tap a value to copy it. "Copy as tags" gives `<lora:name:weight>`; "Copy all" gives every field as text.
- **Filter by what an image used**: right-click, or press and hold, the seed, a model, a LoRA or a sampler setting in the metadata panel and choose "Show only images…". On the **LoRAs** heading that means every image that uses all of the LoRAs listed, at any strength; on a single LoRA, every image that uses that one. The filter appears in the search box as ordinary search text, so it can be edited, cleared or pinned.
- **Search** across the folder as you type. It finds whole words in prompts (`fox` is not `foxglove`), and names of files, models and LoRAs that start with what you typed. The best matches come first: see [Search syntax](#search-syntax).
- **Content search**: click the magnifying glass in the search box to switch from searching the metadata to describing what you are looking for: `a fox in the snow` then finds pictures that *show* that, whatever their prompts say. Only pictures that match are listed, the best match first. It needs a model (TinyCLIP, 337 MB), which the app offers to download the first time and then runs on your device; see [Content search](#content-search) below. Click the magnifying glass again to go back.
- **Pinned searches**: type a search and click the pin beside the ✕ to keep it. Clicking in the search box lists your pinned searches underneath; click one to run it, or its ✕ to remove it. Typing narrows the list to the pins that contain what you typed.
- **Usage** (the bar-chart button; in a narrow window it is in the sort menu): which models, LoRAs, samplers, schedulers, step counts, CFG values, sizes and prompt words the folder's images use most, how each one's use is spread over time, and a timeline of images per day, week, month or year. Click anything to go back to the grid showing only the images behind that number.
- **Image menu**: right-click, or press and hold, an image in the grid or the focus view. **Copy image** puts the file itself on the clipboard, bytes untouched, so the generation data goes with it wherever you paste. The menu also copies the prompt and the file path.
- **Live**: images that appear, change or disappear while the folder is open show up in the grid and in search on their own.
- **Folder panel** on the left: a lazily loaded tree, plus a box to paste a path into.
- **Pinned folders**: right-click, or press and hold, any folder and choose "Pin this folder". Pinned folders are listed in a section at the top of the panel, under the path box, and wear a filled blue folder icon there and in the tree. Click one to jump to it; the same menu unpins it. Click the section's heading to fold it away.

Both panels collapse; on narrow screens they slide over the grid instead of sitting beside it. When the window is taller than it is wide — a tablet held upright, a window tiled to half the screen — the metadata panel moves under the grid or the focused image as a footer, with a top edge you can drag to resize it.

### Search syntax

| Type | Finds |
| --- | --- |
| `red fox` | images whose metadata has both words, `red` and `fox` |
| `"red fox"` | the exact phrase |
| `fox -snow` | `fox` but not `snow` |
| `fox*` | words that start with `fox`: `foxes`, `foxglove` (also `*fox` for words that end with it, `*fox*` for any that contain it) |
| `model:flux` | model name contains `flux` (also `lora:`, `name:`) |
| `prompt:fox` | the word `fox` in the prompt (also `neg:` for the negative prompt) |
| `seed:1234` | seed starts with `1234` |
| `source:comfyui` | made with that tool (`invokeai`, `a1111`, `forge`, …) |
| `sampler:euler` | sampler name contains `euler` (also `scheduler:`) |
| `steps:30` | exactly 30 steps (also `cfg:7`, where `7` and `7.0` are the same) |
| `size:1024x1024` | image dimensions contain `1024x1024` |
| `date:2026-10` | file dated that month (also `date:2026-10-09`, `date:2026`, and `date:2026-10-01..2026-10-07` for a range) |

Matching is case-insensitive, and in prompts it is by whole word: `fox` finds `a red fox`, `fox's` and `red_fox`, but not `foxglove` or `firefox`, and `lond` does not find `blonde` (`*lond*` does). Names are not made of words in the same way, so in the names of files, models and LoRAs a search only has to start where a word starts: `flux` finds `flux1-dev.safetensors` and `dev` does too, but `lux` does not. The fields that name one of those (`model:`, `lora:`, `name:`, `sampler:`) match any part of it.

**Best match first.** While you are searching, results are ordered by how well they match rather than by date:

1. images with the words in their prompt: first those where the words you typed stand together, then by how early the prompt gets to them and how often it repeats them;
2. images that only have them in a file, model or LoRA name, and then in a setting;
3. images that only have them in the negative prompt.

Equally good matches, and searches where nothing can match better or worse (`model:=…`, `date:…`), stay in the folder's own order. The sort menu offers **Best match first** whenever there is a search; pick another order there and searches keep it until you switch back.

Put `=` after the colon to match a whole value instead of part of one. This is what the "Show only images…" menus and the usage page write for you:

| Type | Finds |
| --- | --- |
| `seed:=1234` | that seed and no other |
| `model:="flux1-dev.safetensors"` | images made with exactly that model, whatever it was used as |
| `lora:=detail_xl lora:=inkwash` | images that use both LoRAs, at any strength |
| `sampler:=euler`, `size:=1024x1024`, `name:=a.png` | the whole sampler name, size or file name |

### Content search

Content search uses a CLIP model: a network that turns a picture and a description into numbers that agree when one matches the other. GenerativeView uses [TinyCLIP ViT-40M/32](https://huggingface.co/wkcn/TinyCLIP-ViT-40M-32-Text-19M-LAION400M) (MIT licence): about half the size and half the arithmetic of the original CLIP ViT-B/32, for somewhat lower accuracy (59.8 % against 63.3 % on the usual ImageNet zero-shot test).

- **The model is not in the app.** The first time you switch content search on, a banner offers to download it: three files, 337 MB, from huggingface.co into the app's data folder (`models/tinyclip-vit-40m-32-text-19m`). That download is the only time GenerativeView uses the network; the pictures and what you type never leave the device. On Android this is what the app's network permission is for. To do without it, copy `config.json`, `tokenizer.json` and `model.safetensors` from that page into the folder yourself.
- **Pictures are looked at once.** With content search on, the app works through the open folder in the background, newest pictures first, and remembers what it saw in `vectors.db` beside the index (about 1 KB per picture). Searches answer from whatever has been looked at so far and fill in as the rest is done. It uses half the machine's cores and the small thumbnails the grid already made. On one core of a cloud VM a picture took 65 to 80 ms; a tablet will be slower, so a first pass over thousands of pictures there takes a while.
- **What you get back** is the pictures that match, best match first, and nothing when none does. The model's scores have no fixed scale, so each picture is measured against itself: the app scores it against a few hundred everyday words (`woman`, `forest`, `sword`, `car`…, in `core/src/clip/everyday.txt`), most of which are *not* in any given picture, and a description matches when it scores well clear of that ordinary run.
- **It is still a judgement, not a lookup.** The model is good at what a picture is of, and weak at small details, counting and text. In a folder where every picture is of much the same thing it tells them apart poorly: it can say "a person, not a landscape" far more reliably than which detail of the person is in view. So a search can miss a picture where the thing is small, and can include one that only resembles it. Where the bar sits is one constant, `CLEAR` in `core/src/clip/mod.rs`, set from measurements on a real library; `cargo run --release --example content_probe -- ~/.local/share/com.jrufer.generativeview "/your/folder"` prints the same measurements for a library you have already searched, using its prompts as a rough answer key.
- A pinned search remembers which kind it is, and "Show only images…" filters always switch back to the metadata search.

The model runs on the CPU in the Rust core (`core/src/clip`): no GPU, no extra libraries. Its arithmetic is checked in the tests against the reference implementation in Hugging Face's `transformers` on a small model with made-up weights (`core/tests/fixtures/clip_mini`).

### Keyboard

| Key | Grid | Focus view |
| --- | --- | --- |
| Arrows, `W` `A` `S` `D` | move selection | previous / next image |
| `Enter`, `Space` | open image | back to grid |
| `Esc` | clear selection | back to grid |
| `Home` / `End`, `PgUp` / `PgDn` | jump | jump |
| `Ctrl` `F` or `/` | search | |
| `Ctrl` `C` | copy the selected image's prompt | same |
| `Ctrl` `Shift` `C` | copy the selected image itself | same |
| `Ctrl` `+` / `-` | tile size | |
| `I` or `]` | toggle metadata panel | same |
| `[` | toggle folder panel | |
| `C` | thumbnails cropped to fill / whole image | |
| `F5` | rescan the folder | |

### Metadata it reads

| Tool | Where it looks |
| --- | --- |
| ComfyUI | `prompt` / `workflow` PNG chunks; EXIF in WebP and JPEG; tags in MP4, MOV and WebM (ComfyUI's own video nodes and VideoHelperSuite) |
| InvokeAI | `invokeai_metadata` (v3 and later) and `sd-metadata` (v2) |
| A1111 / Forge | `parameters` PNG chunk; EXIF UserComment in JPEG and WebP |
| Also | SwarmUI, Fooocus and NovelAI basics. Anything unrecognised still appears under "Raw metadata". |

ComfyUI has no fixed schema, so prompts and settings are found by walking the graph back from the sampler. That handles custom samplers, ControlNet, prompt-concatenation and primitive nodes, rgthree's Power Lora Loader and similar; an unusual custom node may still be missed. The full node list and raw JSON are always there to fall back on.

## Install

Every merge to `main` is built, tested and published under [Releases](https://github.com/JRufer/GenerativeView/releases) as `build-<n>`. Grab the newest:

- **Linux**: `GenerativeView-x86_64.AppImage`. Make it executable and run it:

  ```sh
  chmod +x GenerativeView-x86_64.AppImage
  ./GenerativeView-x86_64.AppImage            # or: ./GenerativeView-x86_64.AppImage /path/to/folder
  ```

  `generativeview-linux-x64.tar.gz` is the same app as a plain folder; run `bundle/install.sh` to install it under `~/.local` with a menu entry.

- **Android**: `GenerativeView-arm64-v8a.apk` for tablets and phones. Sideload it.

**Linux needs** GTK 3, and for video `mpv` (playback) and `ffmpeg` (video thumbnails). On CachyOS / Arch:

```sh
sudo pacman -S --needed gtk3 mpv ffmpeg
```

**Android**: on first launch tap **Allow access** and turn on "All files access" for GenerativeView; it needs real folder paths to scan and watch, which Android only gives through that permission. (That permission is also why this is a sideload app rather than a Play Store one.)

### Signing key

Android only installs an update over an existing app if both are signed with the same key. Until the repository has a key of its own, each CI run signs with a throwaway one, and you have to uninstall before installing a newer build. To fix that once:

```sh
keytool -genkeypair -keystore generativeview.jks -storetype PKCS12 -alias generativeview \
  -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=GenerativeView" -storepass 'choose-a-password'

base64 -w0 generativeview.jks | gh secret set ANDROID_KEYSTORE_BASE64 --repo JRufer/GenerativeView
gh secret set ANDROID_KEYSTORE_PASSWORD --repo JRufer/GenerativeView --body 'choose-a-password'
```

Keep `generativeview.jks` somewhere safe and out of the repository. Builds from then on all carry that signature.

## Build from source

You need Flutter 3.47 or newer and a Rust toolchain.

### Linux

```sh
sudo pacman -S --needed clang cmake ninja pkgconf gtk3 mpv ffmpeg rustup   # CachyOS / Arch
flutter build linux --release      # also runs `cargo build --release` for the core
tool/install-linux.sh              # optional: install to ~/.local with a menu entry
tool/build-appimage.sh             # optional: wrap the bundle as a single-file AppImage
```

`generativeview /path/to/folder` opens that folder directly.

### Android

```sh
rustup target add aarch64-linux-android
cargo install cargo-ndk
export ANDROID_NDK_HOME=/path/to/android-sdk/ndk/<version>

tool/build-android-core.sh arm64-v8a          # builds libgvcore.so into android/app/src/main/jniLibs
flutter build apk --release --split-per-abi
```

Run `tool/build-android-core.sh` again whenever something under `core/` changes.

## How it works

```
lib/        Flutter UI (Dart)
core/       Rust library: metadata parsing, index, file watching, thumbnails, content search
```

The UI talks to the core through a small hand-written `dart:ffi` layer (`lib/src/core/native_core.dart` ↔ `core/src/ffi.rs`). Every call is asynchronous, so the UI thread never waits on disk.

- **Metadata** is read without decoding pixels: the core walks the file's chunk or box structure and pulls out the text. Indexing ten thousand PNGs for the first time took about a second on a two-core test machine; reopening the folder took under a tenth of a second.
- **The index** is one SQLite file holding a row per image and its lower-cased search text. Opening a folder answers from the index at once, then compares it with the disk and parses only what is new or changed.
- **Live updates** come from file-system notifications, with a cheap check of folder timestamps every few seconds as a backstop for storage that sends none (Android shared storage, network mounts).
- **Thumbnails** are generated in two sizes on demand, newest request first, and cached on disk. Requests for tiles that scrolled away are dropped. The rest of the folder is pre-rendered in the background at low priority.
- **Grid data** crosses to Dart as one packed buffer that is read in place, so listing ten thousand items costs no parsing.
- **Content search** keeps one vector per picture, filed under the picture's path, date and size like a thumbnail. A search embeds the description (about 20 ms) and takes one dot product per picture. What is ordinary for a picture (its scores against the everyday words) is worked out the first time it is searched in a session and kept in memory: about a quarter of a second for 1,500 pictures on two cores, model loading included.
- **Whole words and best match** are two small SQL functions in the core, run only over the images whose text contains what was typed at all: searching ten thousand images and ordering them takes about 10 ms on the same test machine.
- **Exact filters and usage counts** read one more text column beside the search text: a line per model, LoRA and setting. Counting what ten thousand images were made with is one pass over it (about 35 ms on the same test machine), and indexing is no slower for it.

The index lives in `~/.local/share/com.jrufer.generativeview` and thumbnails in `~/.cache/com.jrufer.generativeview` (on Android, in the app's own storage). The thumbnails and the image index are caches of what is on disk and are rebuilt if deleted; so is `vectors.db`, though rebuilding it means looking at every picture again. The index file also holds your settings, pinned folders and pinned searches, so deleting it resets those.

## Development

```sh
cd core && cargo test                                    # parsers, index, watcher, thumbnails
cargo run --release --example dump -- image.png          # print what the core reads from a file
cargo run --release --example bench -- /path/to/folder   # time indexing, search and thumbnails
cargo run --release --example content_probe -- DATA DIR  # how content search rates a library (see above)

(cd core && cargo build --release) && flutter test       # the real UI against the real core
xvfb-run -a flutter test integration_test -d linux       # the built app in a virtual display
```

`flutter test` drives the actual app against the actual Rust library on a folder of generated images: it searches, opens the metadata panel, copies values, steps through the focus view and checks that added and deleted files appear and disappear. CI runs the same flow against the built Linux app in a virtual display and against the APK on an emulated Android tablet (`tool/ci-android-emulator.sh`). There it also copies an image and reads the clipboard back (as the picture on Linux, through the clipboard's content address on Android) to check that the file arrives byte for byte; where `xclip` is installed, the Linux run asks from outside the app as well.

Set `GV_SCREENSHOT_DIR` to have the tests save a PNG of each stage, and `GV_SAMPLE_DIR` to point `test/gallery_test.dart` at a folder of your own images.

## Known limits

- Dark theme only.
- Video thumbnails on Linux need `ffmpeg` on the `PATH`; without it videos show a placeholder tile.
- Video metadata is read from MP4, MOV and WebM. Animated WebP and GIF play in the focus view.
- Nothing in the app deletes, moves or edits your files.
- Whether a pasted image keeps its generation data is up to the program you paste into. File managers, and anything that takes the copied *file*, get it untouched; a program that takes the *picture* and re-encodes it (browsers do, for images pasted into a web page) drops the data.
- LoRA and model names are compared as written in each file, so the same LoRA saved as `style/inkwash.safetensors` by ComfyUI and as `inkwash` by A1111 counts as two.
