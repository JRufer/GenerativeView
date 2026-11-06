/// The detail pass, run on the pictures a remix or hires fix brings back,
/// or on a picture already made: each picture's faces and hands are found
/// on the device, each region cut out and enlarged in the core, redrawn on
/// the server as an ordinary image to image job, and put back with a soft
/// edge. A picture with nothing to fix goes on as it came.
library;

import 'dart:async';
import 'dart:io';

import 'app_state.dart';
import 'core/backends.dart';
import 'core/detail_pass.dart';
import 'core/models.dart' show GenInfo, MediaItem;
import 'core/piece_prompts.dart';

/// [ticket], with the detail pass run on each picture it brings back before
/// that picture is handed on. Each region is redrawn with the parts of
/// [prompt] that hold in it (see [piecePrompts], with [DetailPass.extra]
/// added) and [negative]. Regions that mostly cover one of [skip] are left
/// alone.
RemixTicket withDetailPass(
  RemixTicket ticket,
  AppState state, {
  required String kind,
  required String base,
  required GenInfo info,
  required String prompt,
  required String negative,
  required DetailPass pass,
  List<DetailRegion> skip = const [],
}) {
  final out = <RemixTicket>[];
  var stopped = false;
  Stream<RemixImage> results() async* {
    await for (final image in ticket.results) {
      if (stopped) return;
      yield await _fix(image, state, kind: kind, base: base, info: info, prompt: prompt, negative: negative, pass: pass, skip: skip, sent: out, stopped: () => stopped);
    }
  }

  return RemixTicket(
    pass.on ? '${ticket.message}, with faces and hands redrawn' : ticket.message,
    ticket.count,
    results(),
    kind: ticket.kind,
    base: ticket.base,
    jobs: ticket.jobs,
    finished: ticket.finished,
    remaining: ticket.remaining,
    stop: () {
      stopped = true;
      ticket.stop();
      for (final t in out) {
        t.stop();
        unawaited(cancelRemix(kind, base, t.jobs).catchError((Object _) {}));
      }
    },
  );
}

/// A ticket bringing back the picture at [path] as it is: to run the
/// detail pass on a picture already made.
Future<RemixTicket> pictureTicket(String path) async {
  final bytes = await File(path).readAsBytes();
  return RemixTicket('', 1, Stream.value(RemixImage(bytes)));
}

/// Whether [a] mostly covers [b].
bool _overlaps(DetailRegion a, DetailRegion b) {
  final both = a.box.intersect(b.box);
  if (both.width <= 0 || both.height <= 0) return false;
  final inter = both.width * both.height;
  final union = a.box.width * a.box.height + b.box.width * b.box.height - inter;
  return union > 0 && inter / union > 0.3;
}

Future<RemixImage> _fix(
  RemixImage image,
  AppState state, {
  required String kind,
  required String base,
  required GenInfo info,
  required String prompt,
  required String negative,
  required DetailPass pass,
  required List<DetailRegion> skip,
  required List<RemixTicket> sent,
  required bool Function() stopped,
}) async {
  final finder = state.regionFinder;
  if (!pass.on || finder == null) return image;
  final dir = await Directory.systemTemp.createTemp('gv-detail-');
  try {
    final picture = '${dir.path}/picture.${image.extension}';
    await File(picture).writeAsBytes(image.bytes, flush: true);
    if (!finder.model.installed) await finder.download();
    final found = [
      for (final r in await finder.find(picture))
        if (pass.wants(r.kind) && !skip.any((s) => s.kind == r.kind && _overlaps(s, r))) r,
    ];
    if (found.isEmpty || stopped()) return image;
    final crops = (await state.core.call('detail_crop', {
      'path': picture,
      'boxes': [for (final r in found) [r.box.left, r.box.top, r.box.right, r.box.bottom]],
      'side': detailSide,
      'dir': dir.path,
    }) as List)
        .cast<Map<String, dynamic>>();
    // Each face or hand is asked for as one, with only the phrases seen
    // around it: the whole prompt would draw its subject into every hand.
    final prompts = await piecePrompts(
      state.core.call,
      path: picture,
      prompt: prompt,
      boxes: [
        for (final c in crops) [c['x'] as num, c['y'] as num, (c['x'] as num) + (c['w'] as num), (c['y'] as num) + (c['h'] as num)],
      ],
      kinds: [for (final r in found) r.kind],
      extra: pass.extra,
    );
    final seed = int.tryParse(info.seed.trim());
    final tickets = await Future.wait([
      for (var i = 0; i < crops.length; i++)
        File(crops[i]['path'] as String).readAsBytes().then((bytes) => sendRemix(
              kind,
              base,
              Remix(
                info: info,
                prompt: prompts[i],
                negative: pieceNegative(negative, kind: found[i].kind),
                seed: seed ?? 0,
                randomSeed: seed == null,
                count: 1,
                width: crops[i]['sent_w'] as int,
                height: crops[i]['sent_h'] as int,
                init: ImageInput(image: bytes, strength: pass.strength),
              ),
            )),
    ]);
    sent.addAll(tickets);
    final back = await Future.wait([
      for (var i = 0; i < tickets.length; i++)
        tickets[i].results.first.then((r) async {
          final path = '${dir.path}/done-$i.${r.extension}';
          await File(path).writeAsBytes(r.bytes, flush: true);
          return path;
        }),
    ]);
    if (stopped()) return image;
    final dest = '${dir.path}/fixed.png';
    await state.core.call('detail_paste', {
      'path': picture,
      'dest': dest,
      'pieces': [
        for (var i = 0; i < crops.length; i++)
          {'path': back[i], 'x': crops[i]['x'], 'y': crops[i]['y'], 'w': crops[i]['w'], 'h': crops[i]['h']},
      ],
    });
    return RemixImage(await File(dest).readAsBytes());
  } catch (e) {
    // The picture itself is still worth keeping; say what went wrong.
    state.notice('Faces and hands were not redrawn: $e');
    return image;
  } finally {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// The detail pass on the picture at [path] (the original itself, or an
/// upscale of it), sent to the server [kind] and saved as the original's
/// name with `_detail1`, with the upscales. A line to say what was sent.
Future<String?> runDetailOn(
  AppState state,
  MediaItem original,
  String path, {
  required String kind,
  required DetailPass pass,
  List<DetailRegion> skip = const [],
}) async {
  final name = backendNames[kind] ?? kind;
  final base = state.backendUrls[kind] ?? '';
  if (base.isEmpty) throw StateError('$name is no longer set up');
  final info = await state.remakeRecipe(original);
  if (info == null) throw StateError('it has no prompt to redraw faces and hands with');
  final ticket = await pictureTicket(path);
  state.collectRemix(
    original,
    withDetailPass(ticket, state, kind: kind, base: base, info: info, prompt: info.prompt, negative: info.negative, pass: pass, skip: skip),
    label: 'detail',
  );
  return 'Faces and hands of ${original.name}: being redrawn on $name';
}
