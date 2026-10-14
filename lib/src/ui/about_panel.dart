import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:package_info_plus/package_info_plus.dart';

import '../platform.dart';
import '../theme.dart';
import 'sheet.dart';

const String appName = 'GenerativeView';
const String _tagline = 'A fast browser for folders of AI-generated images, with searchable generation metadata.';
const String _developer = 'Josh Rufer';
const String _copyright = '© 2026 Joshua Hamilton Rufer';
const String _githubUrl = 'https://github.com/JRufer';
const String _websiteUrl = 'https://jrufer.com';
const String _sourceUrl = 'https://github.com/JRufer/GenerativeView';

/// A project GenerativeView is built on or uses, credited on the About panel.
class Credit {
  const Credit(this.name, this.what, this.licence, this.url);
  final String name;
  final String what;
  final String licence;
  final String url;
}

/// Everything the app is built from, by where it is used. The full licence
/// texts, including every indirect dependency, are on the licences page;
/// this is the list of who to thank.
const List<(String, List<Credit>)> credits = [
  (
    'Foundations',
    [
      Credit('Flutter', 'The interface, on every platform', 'BSD-3-Clause', 'https://flutter.dev'),
      Credit('Dart', 'The language of the interface', 'BSD-3-Clause', 'https://dart.dev'),
      Credit('Rust', 'The language of the core', 'MIT / Apache-2.0', 'https://www.rust-lang.org'),
    ],
  ),
  (
    'Video playback',
    [
      Credit('media_kit', 'Video in Flutter', 'MIT', 'https://github.com/media-kit/media-kit'),
      Credit('mpv', 'The player library (libmpv)', 'LGPL-2.1+', 'https://mpv.io'),
      Credit('FFmpeg', 'Video and sound decoding', 'LGPL-2.1+', 'https://ffmpeg.org'),
      Credit('dav1d', 'AV1 decoding', 'BSD-2-Clause', 'https://code.videolan.org/videolan/dav1d'),
      Credit('libass', 'Subtitle rendering for libmpv', 'ISC', 'https://github.com/libass/libass'),
    ],
  ),
  (
    'The core',
    [
      Credit('SQLite', 'The search index', 'Public domain', 'https://sqlite.org'),
      Credit('rusqlite', 'SQLite from Rust', 'MIT', 'https://github.com/rusqlite/rusqlite'),
      Credit('image', 'Reading PNG, JPEG, WebP, GIF and BMP', 'MIT / Apache-2.0', 'https://github.com/image-rs/image'),
      Credit('fast_image_resize', 'Thumbnails', 'MIT / Apache-2.0', 'https://github.com/Cykooz/fast_image_resize'),
      Credit('jpeg-encoder', 'Saving thumbnails; based in part on the work of the Independent JPEG Group', 'MIT / Apache-2.0, IJG', 'https://github.com/vstroebel/jpeg-encoder'),
      Credit('gemm', 'Matrix arithmetic for upscaling and content search', 'MIT', 'https://github.com/sarah-ek/gemm'),
      Credit('Rayon', 'Using every core', 'MIT / Apache-2.0', 'https://github.com/rayon-rs/rayon'),
      Credit('notify', 'Watching folders for new pictures', 'CC0-1.0', 'https://github.com/notify-rs/notify'),
      Credit('Serde', 'Reading generation metadata', 'MIT / Apache-2.0', 'https://serde.rs'),
      Credit('flate2', 'Compressed metadata and model files', 'MIT / Apache-2.0', 'https://github.com/rust-lang/flate2-rs'),
      Credit('xxhash-rust', 'Fast file fingerprints', 'BSL-1.0', 'https://github.com/DoumanAsh/xxhash-rust'),
      Credit('Crossbeam', 'Work queues', 'MIT / Apache-2.0', 'https://github.com/crossbeam-rs/crossbeam'),
      Credit('parking_lot', 'Locks', 'MIT / Apache-2.0', 'https://github.com/Amanieu/parking_lot'),
      Credit('allo-isolate', 'Talking to Dart from Rust', 'MIT / Apache-2.0', 'https://github.com/sunshine-protocol/allo-isolate'),
      Credit('unicode-rs', 'Text normalisation for search', 'MIT / Apache-2.0', 'https://github.com/unicode-rs'),
      Credit('libc', 'System calls', 'MIT / Apache-2.0', 'https://github.com/rust-lang/libc'),
    ],
  ),
  (
    'Flutter packages',
    [
      Credit('path_provider', 'Where to keep the index and thumbnails', 'BSD-3-Clause', 'https://pub.dev/packages/path_provider'),
      Credit('permission_handler', 'Folder access on Android', 'MIT', 'https://pub.dev/packages/permission_handler'),
      Credit('package_info_plus', 'The version shown here', 'BSD-3-Clause', 'https://pub.dev/packages/package_info_plus'),
      Credit('ffi', 'Calling the core', 'BSD-3-Clause', 'https://pub.dev/packages/ffi'),
    ],
  ),
  (
    'Models and data',
    [
      Credit('Real-ESRGAN', 'The upscale models, by Xintao Wang', 'BSD-3-Clause', 'https://github.com/xinntao/Real-ESRGAN'),
      Credit('TinyCLIP', 'The content-search model, by Microsoft', 'MIT', 'https://github.com/wkcn/TinyCLIP'),
      Credit('pyspellchecker', 'The English word list for the spelling check', 'MIT', 'https://github.com/barrust/pyspellchecker'),
      Credit('Civitai', 'Model and LoRA lookups, when asked for', 'Web service', 'https://civitai.com'),
    ],
  ),
];

/// The About panel: the app, who made it, its licence, and what it is built
/// from.
Future<void> showAbout(BuildContext context) {
  return showPanel<void>(
    context,
    title: 'About',
    icon: Icons.info_outline,
    width: 560,
    builder: (context) => const AboutContent(),
  );
}

Future<String?> _version() async {
  try {
    final info = await PackageInfo.fromPlatform();
    if (info.version.isEmpty) return null;
    final build = info.buildNumber;
    return build.isEmpty || build == '1' ? info.version : '${info.version} (build $build)';
  } catch (_) {
    return null;
  }
}

class AboutContent extends StatefulWidget {
  const AboutContent({super.key});

  @override
  State<AboutContent> createState() => _AboutContentState();
}

class _AboutContentState extends State<AboutContent> {
  late final Future<String?> _versionFuture = _version();

  Future<void> _open(String url) async {
    final opened = await openUrl(url);
    if (!opened && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey<String>('about-panel'),
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 22),
      children: [
        // ---- the app ---------------------------------------------------------
        Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Image.asset('assets/icon.png', width: 96, height: 96, filterQuality: FilterQuality.medium),
          ),
        ),
        const SizedBox(height: 14),
        const Center(
          child: Text(
            appName,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Palette.text, letterSpacing: 0.2),
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: FutureBuilder<String?>(
            future: _versionFuture,
            builder: (context, snapshot) => Text(
              snapshot.data == null ? ' ' : 'Version ${snapshot.data}',
              style: const TextStyle(fontSize: 12.5, color: Palette.faint),
            ),
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          _tagline,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13.5, height: 1.45, color: Palette.muted),
        ),

        // ---- who made it -----------------------------------------------------
        const PanelHeading('Developer'),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: Palette.raised,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Palette.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Designed and built by', style: TextStyle(fontSize: 12, color: Palette.faint)),
              const SizedBox(height: 2),
              const Text(_developer, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Palette.text)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChipButton(
                    key: const ValueKey<String>('about-github'),
                    label: 'github.com/JRufer',
                    icon: Icons.code,
                    selected: false,
                    tooltip: _githubUrl,
                    onTap: () => _open(_githubUrl),
                  ),
                  ChoiceChipButton(
                    key: const ValueKey<String>('about-website'),
                    label: 'jrufer.com',
                    icon: Icons.language,
                    selected: false,
                    tooltip: _websiteUrl,
                    onTap: () => _open(_websiteUrl),
                  ),
                  ChoiceChipButton(
                    label: 'Source code',
                    icon: Icons.folder_open_outlined,
                    selected: false,
                    tooltip: _sourceUrl,
                    onTap: () => _open(_sourceUrl),
                  ),
                ],
              ),
            ],
          ),
        ),

        // ---- licence ---------------------------------------------------------
        const PanelHeading('Licence'),
        const Text(
          '$appName is free and open-source software, released under the MIT License. $_copyright.',
          style: TextStyle(fontSize: 13, height: 1.45, color: Palette.text),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey<String>('about-mit'),
              onPressed: () => _showMitLicense(context),
              icon: const Icon(Icons.description_outlined, size: 17),
              label: const Text('MIT License'),
            ),
            OutlinedButton.icon(
              key: const ValueKey<String>('about-licences'),
              onPressed: () => _showLicences(context),
              icon: const Icon(Icons.gavel_outlined, size: 17),
              label: const Text('Open-source licences'),
            ),
          ],
        ),

        // ---- credits ---------------------------------------------------------
        const PanelHeading('Built with'),
        const Text(
          'Thank you to the people behind these projects. Tap one to visit it.',
          style: TextStyle(fontSize: 12.5, color: Palette.muted),
        ),
        for (final (section, list) in credits) ...[
          PanelHeading(section),
          for (final c in list) _CreditRow(credit: c, onTap: () => _open(c.url)),
        ],
      ],
    );
  }

  Future<void> _showMitLicense(BuildContext context) async {
    String text;
    try {
      text = await rootBundle.loadString('LICENSE');
    } catch (_) {
      text = 'MIT License\n\n$_copyright';
    }
    if (!context.mounted) return;
    await showPanel<void>(
      context,
      title: 'MIT License',
      icon: Icons.description_outlined,
      width: 620,
      builder: (context) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 22),
        child: SelectableText(
          text.trim(),
          style: const TextStyle(fontSize: 12.5, height: 1.5, color: Palette.text, fontFamily: 'monospace'),
        ),
      ),
    );
  }

  Future<void> _showLicences(BuildContext context) async {
    final version = await _versionFuture;
    if (!context.mounted) return;
    showLicensePage(
      context: context,
      applicationName: appName,
      applicationVersion: version,
      applicationIcon: Padding(
        padding: const EdgeInsets.all(12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.asset('assets/icon.png', width: 64, height: 64),
        ),
      ),
      applicationLegalese: '$_copyright\nReleased under the MIT License.',
    );
  }
}

class _CreditRow extends StatelessWidget {
  const _CreditRow({required this.credit, required this.onTap});
  final Credit credit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: credit.url,
      child: InkWell(
        onTap: onTap,
        hoverColor: Palette.hover,
        borderRadius: BorderRadius.circular(6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(credit.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: Palette.text)),
                      const SizedBox(height: 1),
                      Text(credit.what, style: const TextStyle(fontSize: 12, height: 1.35, color: Palette.muted)),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: Palette.line),
                  ),
                  child: Text(credit.licence, style: const TextStyle(fontSize: 11, color: Palette.faint)),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.open_in_new, size: 15, color: Palette.faint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
