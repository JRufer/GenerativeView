/// Renders asked for while their server was offline, kept until it is back.
///
/// Each is everything [sendRemix] needs (or, for a hires fix or a detail
/// pass, the whole plan), written to the app's own folder so it outlasts
/// the app being closed. The server is asked now and then whether it is
/// there; once it answers, what is queued for it is sent as though it had
/// just been asked for, and shows on the round button like any other run.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_state.dart';
import 'core/backends.dart';
import 'core/detail_pass.dart';
import 'core/lora_edits.dart';
import 'core/models.dart';
import 'detail_run.dart';
import 'ui/upscale_dialog.dart' show ServerUpscalePlan, startServerUpscale;

/// Whether an offline server is checked for by itself (Settings).
const String queueAutoPref = 'pref_queue_auto';

/// How often, in seconds (Settings).
const String queuePollPref = 'pref_queue_poll';
const int queuePollDefault = 60;

/// The choices Settings offers for [queuePollPref], in seconds.
const List<int> queuePollChoices = [15, 30, 60, 300, 900];

/// "15 s", "1 min", "5 min": how [seconds] between checks is said.
String everyText(int seconds) => seconds < 60 || seconds % 60 != 0 ? '$seconds s' : '${seconds ~/ 60} min';

/// One render waiting in the queue for its server.
@immutable
class QueuedRender {
  const QueuedRender({
    required this.id,
    required this.kind,
    required this.type,
    required this.label,
    required this.name,
    required this.renders,
    required this.at,
    required this.body,
    this.group,
    this.files = const [],
  });

  /// Unique, and in the order queued.
  final String id;

  /// The server it is for: `comfyui`, `invokeai` or `forge`.
  final String kind;

  /// `remix` (one [sendRemix]) or `upscale` (a [ServerUpscalePlan]).
  final String type;

  /// What it makes, as the round button's runs are labelled: `remix`,
  /// `bred`, `new`, `hires` or `detail`.
  final String label;

  /// The picture it is made from, or the first words of a new one's prompt.
  final String name;

  /// How many renders it stands for.
  final int renders;

  /// When it was queued, in microseconds.
  final int at;

  /// Queued together with the others of this name, as one run.
  final String? group;

  /// What to send, as it is kept on disk.
  final Map<String, dynamic> body;

  /// The pictures kept beside it (to start from, and masks), by file name.
  final List<String> files;

  /// "Remix of fox.png": what is waiting, as the round button's card says it.
  String get title => switch (label) {
    'hires' => 'Hires fix of $name',
    'detail' => 'Faces and hands of $name',
    'bred' => 'Breed from $name',
    'new' => 'New picture: $name',
    _ => 'Remix of $name',
  };

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'type': type,
    'label': label,
    'name': name,
    'renders': renders,
    'at': at,
    'group': group,
    'files': files,
    'body': body,
  };

  static QueuedRender? fromJson(Map<String, dynamic> j) {
    final id = j['id'], kind = j['kind'], body = j['body'];
    if (id is! String || kind is! String || body is! Map<String, dynamic>) return null;
    return QueuedRender(
      id: id,
      kind: kind,
      type: j['type'] as String? ?? 'remix',
      label: j['label'] as String? ?? 'remix',
      name: j['name'] as String? ?? '',
      renders: (j['renders'] as num?)?.toInt() ?? 1,
      at: (j['at'] as num?)?.toInt() ?? 0,
      group: j['group'] as String?,
      files: [
        for (final f in (j['files'] as List? ?? const []))
          if (f is String) f,
      ],
      body: body,
    );
  }
}

/// The queue itself: what is waiting, the checks on the servers, and the
/// sending once one is back.
class RenderQueue {
  RenderQueue(this._state, {String? dir}) : _dirPath = dir;

  final AppState _state;

  /// Where the queue is kept; null (tests) for a folder of its own that
  /// nothing is read back from.
  final String? _dirPath;
  Directory? _made;

  Directory get _dir {
    final made = _made;
    if (made != null) return made;
    final path = _dirPath;
    final dir = path == null ? Directory.systemTemp.createTempSync('gv-queue-') : Directory(path);
    if (path != null) dir.createSync(recursive: true);
    _made = dir;
    return dir;
  }

  /// What is waiting, oldest first.
  final ValueNotifier<List<QueuedRender>> queued = ValueNotifier(const []);

  /// Whether the servers are being asked just now.
  final ValueNotifier<bool> checking = ValueNotifier(false);

  Timer? _timer;
  Duration? _timerEvery;
  bool _disposed = false;
  int _lastId = 0;

  /// Whether an offline server is checked for without being asked.
  bool get automatic => _state.prefFlag(queueAutoPref, true);

  /// How long between those checks.
  Duration get every =>
      Duration(seconds: _state.prefNumber(queuePollPref, queuePollDefault.toDouble()).round().clamp(5, 3600).toInt());

  /// How many renders are waiting, all told.
  int get renders => queued.value.fold<int>(0, (n, e) => n + e.renders);

  /// A name for several queued together, to show and cancel as one run.
  String newGroup() => 'g${_newId()}';

  int _newId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    _lastId = now > _lastId ? now : _lastId + 1;
    return _lastId;
  }

  // ------------------------------------------------------------ adding

  /// Queue [remix] for the server [kind]. What comes back is saved beside
  /// the picture at [path] (called [name]) or, for a new picture, in [dir];
  /// with [detail], faces and hands are redrawn on it first. [label] as
  /// for [AppState.collectRemix]; [group] from [newGroup].
  void addRemix(
    String kind,
    Remix remix, {
    String? path,
    String? name,
    String? dir,
    String label = 'remix',
    String? group,
    DetailPass? detail,
  }) {
    final at = _newId();
    final files = <String>[];
    String keep(Uint8List bytes, String what) {
      final file = '$at-$what.png';
      File('${_dir.path}/$file').writeAsBytesSync(bytes, flush: true);
      files.add(file);
      return file;
    }

    try {
      _add(QueuedRender(
        id: '$at',
        kind: kind,
        type: 'remix',
        label: label,
        name: name ?? AppState.newPictureStem(remix.prompt),
        renders: remix.count < 1 ? 1 : remix.count,
        at: at,
        group: group,
        files: files,
        body: {
          'remix': _remixJson(remix, keep),
          'path': path,
          'name': name,
          'dir': dir,
          if (detail != null && detail.on) 'detail': detailPassJson(detail),
        },
      ));
    } catch (_) {
      // Not queued after all: nothing of it is left lying about.
      _deleteFiles('$at', files);
      rethrow;
    }
  }

  /// Queue a hires fix or a detail pass: all of [plan], upscale here
  /// included, which is only made once the server is there to take it.
  void addUpscale(ServerUpscalePlan plan) {
    final at = _newId();
    final first = plan.items.isEmpty ? '' : plan.items.first.name;
    final more = plan.items.length - 1;
    _add(QueuedRender(
      id: '$at',
      kind: plan.server,
      type: 'upscale',
      label: plan.refine ? 'hires' : 'detail',
      name: more > 0 ? '$first and $more more' : first,
      renders: plan.items.isEmpty ? 1 : plan.items.length,
      at: at,
      body: plan.toJson(),
    ));
  }

  void _add(QueuedRender entry) {
    // Through JSON and back, so one just queued is no different from one
    // read at the next start.
    final text = jsonEncode(entry.toJson());
    File('${_dir.path}/${entry.id}.json').writeAsStringSync(text, flush: true);
    final stored = QueuedRender.fromJson(jsonDecode(text) as Map<String, dynamic>);
    if (stored == null) return;
    _set([...queued.value, stored]);
  }

  // ------------------------------------------------------------ cancelling

  /// Take [ids] out of the queue: they are never sent.
  void cancel(Iterable<String> ids) {
    final gone = ids.toSet();
    final left = <QueuedRender>[];
    for (final e in queued.value) {
      if (gone.contains(e.id)) {
        _deleteFiles(e.id, e.files);
      } else {
        left.add(e);
      }
    }
    _set(left);
  }

  /// Empty the queue.
  void cancelAll() => cancel([for (final e in queued.value) e.id]);

  void _remove(QueuedRender entry) => cancel([entry.id]);

  void _deleteFiles(String id, List<String> files) {
    for (final name in ['$id.json', ...files]) {
      try {
        File('${_dir.path}/$name').deleteSync();
      } catch (_) {
        // Never written, or already gone.
      }
    }
  }

  void _set(List<QueuedRender> list) {
    if (_disposed) return;
    queued.value = List.unmodifiable(list);
    reschedule();
  }

  // ------------------------------------------------------------ checking

  /// Start or stop the checks, to suit what is queued and the settings.
  void reschedule() {
    if (_disposed) return;
    final wanted = queued.value.isNotEmpty && automatic ? every : null;
    if (wanted == _timerEvery && (wanted == null) == (_timer == null)) return;
    _timer?.cancel();
    _timer = null;
    _timerEvery = wanted;
    if (wanted != null) _timer = Timer.periodic(wanted, (_) => unawaited(check()));
  }

  /// The app is on screen again: timers may not have run meanwhile.
  void appResumed() {
    if (queued.value.isNotEmpty && automatic) unawaited(check());
  }

  /// Ask each server with something queued whether it is there, and send
  /// what is queued for those that are. With [asked] (the user pressed
  /// "Check now") it says so when nothing could be sent; either way it says
  /// what was started.
  Future<void> check({bool asked = false}) async {
    if (_disposed || checking.value || queued.value.isEmpty) return;
    checking.value = true;
    var started = 0;
    final offline = <String>{};
    final batches = <String, String>{};
    try {
      for (final kind in {for (final e in queued.value) e.kind}) {
        final base = _state.backendUrls[kind] ?? '';
        if (base.isEmpty) {
          offline.add(kind);
          continue;
        }
        try {
          await probeBackend(kind, base);
        } catch (_) {
          offline.add(kind);
          continue;
        }
        for (final entry in [...queued.value.where((e) => e.kind == kind)]) {
          if (_disposed) return;
          // Cancelled while the ones before it were being sent.
          if (!queued.value.any((e) => e.id == entry.id)) continue;
          try {
            if (await _start(entry, base, batches)) started += entry.renders;
            _remove(entry);
          } on BackendOffline {
            // Gone again: this and the rest wait for the next check.
            offline.add(kind);
            break;
          } catch (e) {
            // Not something waiting will mend: it is not tried again.
            _remove(entry);
            final text = '${entry.title} was queued, but could not be started: $e';
            if (!_disposed) {
              _state.problems.value = [..._state.problems.value, text];
              _state.notice(text);
            }
          }
        }
      }
    } finally {
      for (final batch in batches.values) {
        _state.closeRemixBatch(batch);
      }
      if (!_disposed) checking.value = false;
    }
    if (_disposed) return;
    // Short, as toasts are: what is still waiting shows on the round button.
    if (started > 0) {
      _state.notice('Started $started queued render${started == 1 ? '' : 's'}');
    } else if (asked && queued.value.isNotEmpty) {
      final names = [for (final k in offline) backendNames[k] ?? k].join(' and ');
      _state.notice('$names ${offline.length == 1 ? 'is' : 'are'} still offline');
    }
  }

  /// Send [entry] to its server at [base]. False if it was cancelled while
  /// being sent, and so stopped again.
  Future<bool> _start(QueuedRender entry, String base, Map<String, String> batches) async {
    if (entry.type == 'upscale') {
      await startServerUpscale(_state, ServerUpscalePlan.fromJson(entry.body));
      return true;
    }
    final body = entry.body;
    final remix = _remixFrom(body['remix'] as Map<String, dynamic>);
    var ticket = await sendRemix(entry.kind, base, remix);
    if (_disposed || !queued.value.any((e) => e.id == entry.id)) {
      ticket.stop();
      unawaited(cancelRemix(entry.kind, base, ticket.jobs).catchError((Object _) {}));
      return false;
    }
    final pass = body['detail'] is Map<String, dynamic> ? detailPassFromJson(body['detail'] as Map<String, dynamic>) : null;
    if (pass != null && pass.on) {
      ticket = withDetailPass(ticket, _state, kind: entry.kind, base: base, info: remix.info, prompt: remix.prompt, negative: remix.negative, pass: pass);
    }
    final group = entry.group;
    final batch = group == null ? null : batches.putIfAbsent(group, _state.openRemixBatch);
    final path = body['path'] as String?;
    if (path != null) {
      _state.collectRemixAt(path, body['name'] as String? ?? entry.name, ticket, label: entry.label, batch: batch);
    } else {
      _state.collectNew(body['dir'] as String? ?? _state.folder ?? '.', remix.prompt, ticket, batch: batch);
    }
    return true;
  }

  // ------------------------------------------------------------ keeping

  /// Read back what was queued when the app last closed, and look for its
  /// servers straight away.
  void restore() {
    final path = _dirPath;
    if (path == null || _disposed) return;
    final found = <QueuedRender>[];
    final others = <File>[];
    try {
      final dir = Directory(path);
      if (!dir.existsSync()) return;
      for (final file in dir.listSync().whereType<File>()) {
        if (!file.path.endsWith('.json')) {
          others.add(file);
          continue;
        }
        try {
          final j = jsonDecode(file.readAsStringSync());
          final entry = j is Map<String, dynamic> ? QueuedRender.fromJson(j) : null;
          if (entry != null) found.add(entry);
        } catch (_) {
          // Half written when the app was stopped: not one to send.
        }
      }
    } on FileSystemException {
      return;
    }
    // Pictures whose render is no longer queued.
    final kept = {for (final e in found) ...e.files};
    for (final file in others) {
      if (kept.contains(file.uri.pathSegments.last)) continue;
      try {
        file.deleteSync();
      } catch (_) {}
    }
    if (found.isEmpty) return;
    found.sort((a, b) => a.at.compareTo(b.at));
    _set(found);
    if (automatic) unawaited(check());
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    queued.dispose();
    checking.dispose();
  }

  // ------------------------------------------------------------ as JSON

  Map<String, Object?> _remixJson(Remix r, String Function(Uint8List bytes, String what) keep) {
    final init = r.init;
    final mask = init?.mask, keepMask = init?.keepMask;
    return {
      'info': r.info.toJson(),
      'prompt': r.prompt,
      'negative': r.negative,
      'negative_optional': r.negativeOptional,
      'seed': r.seed,
      'random_seed': r.randomSeed,
      'count': r.count,
      'width': r.width,
      'height': r.height,
      'steps': r.steps,
      'cfg': r.cfg,
      'loras': r.loras == null
          ? null
          : [
              for (final c in r.loras!)
                {
                  'name': c.original.name,
                  'weight': c.original.weight,
                  'weight_clip': c.original.weightClip,
                  'hash': c.original.hash,
                  'on': c.enabled,
                  'set': c.weight,
                },
            ],
      'init': init == null
          ? null
          : {
              'image': keep(init.image, 'init'),
              'strength': init.strength,
              'mask': mask == null ? null : keep(mask, 'mask'),
              'keep_mask': keepMask == null ? null : keep(keepMask, 'keep'),
            },
    };
  }

  Remix _remixFrom(Map<String, dynamic> j) {
    double? number(Object? v) => v is num ? v.toDouble() : null;
    Uint8List? read(Object? file) => file is String ? File('${_dir.path}/$file').readAsBytesSync() : null;
    final init = j['init'];
    final loras = j['loras'];
    return Remix(
      info: GenInfo.fromJson(j['info'] as Map<String, dynamic>),
      prompt: j['prompt'] as String? ?? '',
      negative: j['negative'] as String? ?? '',
      negativeOptional: j['negative_optional'] == true,
      seed: (j['seed'] as num?)?.toInt() ?? 0,
      randomSeed: j['random_seed'] == true,
      count: (j['count'] as num?)?.toInt() ?? 1,
      width: (j['width'] as num?)?.toInt() ?? 1024,
      height: (j['height'] as num?)?.toInt() ?? 1024,
      steps: (j['steps'] as num?)?.toInt(),
      cfg: number(j['cfg']),
      loras: loras is! List
          ? null
          : [
              for (final l in loras)
                if (l is Map<String, dynamic>)
                  LoraChoice(
                    LoraRef(l['name'] as String? ?? '', number(l['weight']), number(l['weight_clip']), l['hash'] as String? ?? ''),
                    enabled: l['on'] != false,
                    weight: number(l['set']),
                  ),
            ],
      init: init is! Map<String, dynamic>
          ? null
          : ImageInput(
              image: read(init['image'])!,
              strength: number(init['strength']) ?? 0.6,
              mask: read(init['mask']),
              keepMask: read(init['keep_mask']),
            ),
    );
  }
}

/// A detail pass, as it is kept in the queue.
Map<String, Object?> detailPassJson(DetailPass pass) => {
  'faces': pass.faces,
  'hands': pass.hands,
  'strength': pass.strength,
  'extra': pass.extra,
  'skipped': pass.skipped.toList(),
};

DetailPass detailPassFromJson(Map<String, dynamic> j) => DetailPass(
  faces: j['faces'] == true,
  hands: j['hands'] == true,
  strength: (j['strength'] as num?)?.toDouble() ?? defaultDetailStrength,
  extra: j['extra'] as String? ?? '',
  skipped: {
    for (final i in (j['skipped'] as List? ?? const []))
      if (i is num) i.toInt(),
  },
);
