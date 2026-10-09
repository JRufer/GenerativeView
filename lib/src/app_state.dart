import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show FocusNode, TextEditingController;

import 'core/models.dart';
import 'core/native_core.dart';
import 'core/thumb_cache.dart';

enum ViewMode { grid, focus }

@immutable
class ScanStatus {
  const ScanStatus({this.running = false, this.done = 0, this.total = 0, this.error});
  final bool running;
  final int done;
  final int total;
  final String? error;

  static const ScanStatus idle = ScanStatus();
}

/// A place to start browsing from.
class Place {
  const Place(this.name, this.path, this.kind);
  final String name;
  final String path;

  /// home | folder | drive | root
  final String kind;
}

class DirNode {
  const DirNode(this.name, this.path, this.hasChildren);
  final String name;
  final String path;
  final bool hasChildren;
}

const double minTileSize = 72;
const double maxTileSize = 520;

/// Everything the UI shows, and the operations that change it.
class AppState extends ChangeNotifier {
  AppState({
    required this.core,
    required this.thumbs,
    this.pollMs = 0,
    this.videoPlayback = false,
  }) {
    _events = core.events.listen(_onEvent);
  }

  final NativeCore core;
  final ThumbCache thumbs;
  final int pollMs;

  /// Whether a video player is available on this install.
  final bool videoPlayback;

  late final StreamSubscription<Map<String, dynamic>> _events;

  // ---------------------------------------------------------------- view

  String? folder;
  bool recursive = true;
  String sort = 'newest';
  String query = '';

  ItemList items = ItemList.empty;

  /// False until the first query for the current folder has answered.
  bool loaded = false;

  ViewMode mode = ViewMode.grid;
  int selectedIndex = -1;
  int? _selectedId;

  /// Bumped whenever the grid should scroll the selection into view.
  int revealTick = 0;

  /// Set by the grid so keyboard navigation can move by rows and pages.
  int gridColumns = 1;
  int gridRowsPerPage = 1;

  final ValueNotifier<ScanStatus> scan = ValueNotifier(ScanStatus.idle);

  // ---------------------------------------------------------------- search box

  /// Owned here so keyboard shortcuts can reach the search box from anywhere.
  final TextEditingController searchText = TextEditingController();
  final FocusNode searchFocus = FocusNode(debugLabel: 'search');

  // ---------------------------------------------------------------- layout

  /// True when the window is too narrow for panels beside the content, and
  /// they slide over it instead. Set by the home page as it lays out.
  bool narrowLayout = false;

  double tileSize = 190;
  bool leftOpen = true;
  bool rightOpen = false;
  double leftWidth = 280;
  double rightWidth = 380;
  bool prewarm = true;

  // ---------------------------------------------------------------- folders

  List<Place> places = const [];
  final Map<String, List<DirNode>> children = {};
  final Set<String> expanded = {};

  /// Bumped when the tree has been opened down to the current folder.
  int treeRevealTick = 0;

  // ---------------------------------------------------------------- internals

  int _queryTicket = 0;
  Timer? _reloadTimer;
  Timer? _queryTimer;
  bool _disposed = false;
  final Map<String, Timer> _saveTimers = {};
  final Map<String, GenInfo> _metaCache = {};

  MediaItem? get selected =>
      (selectedIndex >= 0 && selectedIndex < items.length) ? items[selectedIndex] : null;

  // ================================================================ startup

  /// Load saved settings and reopen the last folder.
  Future<void> restore({String? initialFolder}) async {
    Map<String, dynamic> saved = const {};
    try {
      saved = (await core.call('settings')) as Map<String, dynamic>;
    } catch (_) {}
    double number(String key, double fallback) => double.tryParse('${saved[key]}') ?? fallback;
    bool flag(String key, bool fallback) => saved[key] == null ? fallback : saved[key] == 'true';

    tileSize = number('tile_size', tileSize).clamp(minTileSize, maxTileSize).toDouble();
    leftWidth = number('left_width', leftWidth).clamp(200, 520).toDouble();
    rightWidth = number('right_width', rightWidth).clamp(260, 720).toDouble();
    leftOpen = flag('left_open', leftOpen);
    rightOpen = flag('right_open', rightOpen);
    recursive = flag('recursive', recursive);
    prewarm = flag('prewarm', prewarm);
    sort = (saved['sort'] as String?) ?? sort;

    await loadPlaces();
    final start = initialFolder ?? saved['folder'] as String?;
    if (start != null && start.isNotEmpty) {
      await openFolder(start, remember: initialFolder == null);
    } else {
      notifyListeners();
    }
  }

  /// Run a request whose result (and failure) we have no use for.
  void _fire(Future<dynamic> request) {
    unawaited(request.then<void>((_) {}, onError: (Object _) {}));
  }

  void _save(String key, String value, {bool debounce = false}) {
    void write() => _fire(core.call('set_setting', {'key': key, 'value': value}));

    _saveTimers.remove(key)?.cancel();
    if (debounce) {
      _saveTimers[key] = Timer(const Duration(milliseconds: 400), write);
    } else {
      write();
    }
  }

  // ================================================================ folders

  Future<void> loadPlaces() async {
    try {
      final raw = (await core.call('roots')) as List;
      places = [
        for (final p in raw)
          if (p is Map) Place(p['name'] as String, p['path'] as String, p['kind'] as String),
      ];
    } catch (_) {
      places = const [];
    }
    if (!_disposed) notifyListeners();
  }

  Future<List<DirNode>> _list(String path) async {
    try {
      final raw = (await core.call('list_dirs', {'path': path})) as List;
      return [
        for (final d in raw)
          if (d is Map) DirNode(d['name'] as String, d['path'] as String, d['has_sub'] as bool? ?? false),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> toggleExpanded(String path) async {
    if (expanded.remove(path)) {
      notifyListeners();
      return;
    }
    expanded.add(path);
    notifyListeners();
    children[path] = await _list(path);
    if (!_disposed) notifyListeners();
  }

  /// Open the tree down to [path] so the current folder is visible in it.
  Future<void> revealInTree(String path) async {
    Place? best;
    for (final p in places) {
      final under = path == p.path || path.startsWith(p.path.endsWith('/') ? p.path : '${p.path}/');
      if (under && (best == null || p.path.length > best.path.length)) best = p;
    }
    if (best == null) return;
    var current = best.path;
    final rest = path.substring(current.length).split('/').where((s) => s.isNotEmpty).toList();
    for (final segment in rest) {
      expanded.add(current);
      children[current] ??= await _list(current);
      current = current.endsWith('/') ? '$current$segment' : '$current/$segment';
    }
    // ...and open the folder itself, so its sub-folders are one tap away.
    final own = await _list(current);
    children[current] = own;
    if (own.isNotEmpty) expanded.add(current);
    treeRevealTick++;
    if (!_disposed) notifyListeners();
  }

  /// Show a folder. The index answers at once with what it already knows;
  /// the core then scans for changes and tells us when to refresh.
  Future<void> openFolder(String path, {bool remember = true}) async {
    var dir = path.trim();
    while (dir.length > 1 && dir.endsWith('/')) {
      dir = dir.substring(0, dir.length - 1);
    }
    if (dir.isEmpty) return;
    folder = dir;
    items = ItemList.empty;
    loaded = false;
    selectedIndex = -1;
    _selectedId = null;
    mode = ViewMode.grid;
    scan.value = const ScanStatus(running: true);
    thumbs.retryFailed();
    notifyListeners();
    if (remember) _save('folder', dir);
    try {
      await core.call('set_folder', {'dir': dir, 'recursive': recursive, 'poll_ms': pollMs});
    } catch (e) {
      scan.value = ScanStatus(error: '$e');
    }
    unawaited(revealInTree(dir));
    await _reload();
  }

  void setRecursive(bool value) {
    if (recursive == value) return;
    recursive = value;
    _save('recursive', '$value');
    final dir = folder;
    if (dir != null) {
      openFolder(dir);
    } else {
      notifyListeners();
    }
  }

  void setSort(String value) {
    if (sort == value) return;
    sort = value;
    _save('sort', value);
    notifyListeners();
    _reload();
  }

  /// Update the search text; the query runs after a short typing pause.
  void setQuery(String value) {
    if (query == value) return;
    query = value;
    _queryTimer?.cancel();
    _queryTimer = Timer(const Duration(milliseconds: 90), _reload);
    notifyListeners();
  }

  void rescan() {
    thumbs.retryFailed();
    _fire(core.call('rescan'));
  }

  // ================================================================ items

  void _onEvent(Map<String, dynamic> e) {
    if (e['root'] != folder) return;
    switch (e['t']) {
      case 'changed':
        // Coalesce bursts (a scan reports every few hundred files).
        _reloadTimer ??= Timer(const Duration(milliseconds: 120), () {
          _reloadTimer = null;
          _reload();
        });
      case 'scan':
        final state = e['state'] as String? ?? '';
        final done = (e['done'] as num?)?.toInt() ?? 0;
        final total = (e['total'] as num?)?.toInt() ?? 0;
        if (state == 'error') {
          scan.value = ScanStatus(error: e['error'] as String? ?? 'Could not read this folder');
        } else if (state == 'done') {
          scan.value = ScanStatus.idle;
          if (prewarm) _warm();
        } else {
          scan.value = ScanStatus(running: true, done: done, total: total);
        }
    }
  }

  void _warm() {
    final dir = folder;
    if (dir == null) return;
    _fire(core.call('warm', {'dir': dir, 'recursive': recursive, 'sort': sort}));
  }

  Future<void> _reload() async {
    final dir = folder;
    if (dir == null || _disposed) return;
    final ticket = ++_queryTicket;
    final ItemList list;
    try {
      list = ItemList.parse(await core.query(dir: dir, recursive: recursive, text: query, sort: sort));
    } catch (e) {
      if (ticket == _queryTicket && !_disposed) {
        scan.value = ScanStatus(error: '$e');
      }
      return;
    }
    if (ticket != _queryTicket || _disposed) return;
    final previousIndex = selectedIndex;
    items = list;
    loaded = true;
    final id = _selectedId;
    if (id != null) {
      var index = list.indexOfId(id);
      if (index < 0 && mode == ViewMode.focus && list.isNotEmpty) {
        // The image on screen was removed: stay where we were in the list.
        index = previousIndex.clamp(0, list.length - 1).toInt();
        _selectedId = list.idAt(index);
      }
      selectedIndex = index;
      if (index < 0) _selectedId = null;
    } else {
      selectedIndex = -1;
    }
    if (mode == ViewMode.focus && list.isEmpty) mode = ViewMode.grid;
    notifyListeners();
  }

  // ================================================================ selection

  void select(int index, {bool reveal = false}) {
    if (index < 0 || index >= items.length) return;
    if (index == selectedIndex && !reveal) return;
    selectedIndex = index;
    _selectedId = items.idAt(index);
    if (reveal) revealTick++;
    notifyListeners();
  }

  void clearSelection() {
    if (selectedIndex < 0) return;
    selectedIndex = -1;
    _selectedId = null;
    notifyListeners();
  }

  /// Move the selection, clamped to the list. Used by keyboard navigation.
  void move(int delta) {
    if (items.isEmpty) return;
    final from = selectedIndex < 0 ? (delta > 0 ? -1 : items.length) : selectedIndex;
    final to = (from + delta).clamp(0, items.length - 1).toInt();
    select(to, reveal: true);
  }

  void openFocus([int? index]) {
    final i = index ?? selectedIndex;
    if (i < 0 || i >= items.length) return;
    selectedIndex = i;
    _selectedId = items.idAt(i);
    mode = ViewMode.focus;
    notifyListeners();
  }

  void closeFocus() {
    if (mode != ViewMode.focus) return;
    mode = ViewMode.grid;
    revealTick++;
    notifyListeners();
  }

  // ================================================================ layout

  void setTileSize(double value) {
    final v = value.clamp(minTileSize, maxTileSize).toDouble();
    if (v == tileSize) return;
    tileSize = v;
    _save('tile_size', v.toStringAsFixed(0), debounce: true);
    notifyListeners();
  }

  void toggleLeft() {
    leftOpen = !leftOpen;
    _save('left_open', '$leftOpen');
    notifyListeners();
  }

  void toggleRight() {
    rightOpen = !rightOpen;
    _save('right_open', '$rightOpen');
    notifyListeners();
  }

  void closePanels() {
    if (!leftOpen && !rightOpen) return;
    if (leftOpen) _save('left_open', 'false');
    if (rightOpen) _save('right_open', 'false');
    leftOpen = false;
    rightOpen = false;
    notifyListeners();
  }

  void setLeftWidth(double value) {
    leftWidth = value.clamp(200, 520).toDouble();
    _save('left_width', leftWidth.toStringAsFixed(0), debounce: true);
    notifyListeners();
  }

  void setRightWidth(double value) {
    rightWidth = value.clamp(260, 720).toDouble();
    _save('right_width', rightWidth.toStringAsFixed(0), debounce: true);
    notifyListeners();
  }

  // ================================================================ metadata

  /// Full generation metadata for an item, read from the file itself.
  Future<GenInfo> metadata(MediaItem item) async {
    final key = '${item.path}/${item.mtime}/${item.size}';
    final hit = _metaCache.remove(key);
    if (hit != null) {
      _metaCache[key] = hit;
      return hit;
    }
    final json = await core.call('meta', {'path': item.path});
    final info = GenInfo.fromJson(json as Map<String, dynamic>);
    _metaCache[key] = info;
    if (_metaCache.length > 64) _metaCache.remove(_metaCache.keys.first);
    return info;
  }

  @override
  void dispose() {
    _disposed = true;
    _events.cancel();
    _reloadTimer?.cancel();
    _queryTimer?.cancel();
    for (final t in _saveTimers.values) {
      t.cancel();
    }
    scan.dispose();
    searchText.dispose();
    searchFocus.dispose();
    super.dispose();
  }
}
