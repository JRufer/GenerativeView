import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/backends.dart' show backendNames;
import '../render_queue.dart';
import '../theme.dart';

/// How the queue's checks are said: when the next one comes, or where to
/// ask for one.
String _checksText(AppState state, String name) => state.renderQueue.automatic
    ? 'The app looks for $name every ${everyText(state.renderQueue.every.inSeconds)} while it is open'
    : 'Checking by itself is off in Settings, so $name is only looked for when you ask';

/// The server [kind] did not answer: ask whether what was about to be sent
/// ([renders] of them) should wait in the render queue for it. True to
/// queue; Esc, "Not now" or a tap outside give false.
Future<bool> offerToQueue(BuildContext context, AppState state, String kind, {int renders = 1}) async {
  final name = backendNames[kind] ?? kind;
  final what = renders == 1 ? 'this render' : 'these $renders renders';
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey<String>('queue-offer'),
      backgroundColor: Palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Palette.line),
      ),
      icon: const Icon(Icons.cloud_off_outlined, color: Palette.accent),
      title: Text('$name is not online', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Palette.text)),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Text(
          'Add $what to the queue? ${renders == 1 ? 'It starts' : 'They start'} as soon as $name is back. '
          '${_checksText(state, name)}. The round button at the bottom right shows what is queued.',
          style: const TextStyle(fontSize: 13.5, height: 1.4, color: Palette.muted),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey<String>('queue-offer-no'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          key: const ValueKey<String>('queue-offer-yes'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Add to queue'),
        ),
      ],
    ),
  );
  return yes ?? false;
}

/// The line shown once [renders] are queued for the server [kind]: short,
/// as a toast is.
String queuedText(String kind, int renders) =>
    'Queued ${renders == 1 ? '1 render' : '$renders renders'} for ${backendNames[kind] ?? kind}';
