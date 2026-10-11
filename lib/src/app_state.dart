import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show TextEditingValue, TextSelection;
import 'package:flutter/widgets.dart' show FocusNode, TextEditingController;

import 'core/model_download.dart';
import 'core/models.dart';
import 'core/native_core.dart';
import 'core/thumb_cache.dart';

enum ViewMode { grid, focus }

@immutable
class ScanStatus {
  const ScanStatus({
    this.running = false,
    this.done = 0,
    this.total = 0,
    this.error,
  });
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

/// A search kept for later, a tap away under the search box.
@immutable
class PinnedSearch {
  const PinnedSearch(this.query, {this.content = false});
  final String query;

  /// A description of what the pictures show, rather than metadata to match.
  final bool content;

  Map<String, Object?> toJson() => {'q': query, if (content) 'content': true};

  static PinnedSearch? fromJson(Object? json) {
    final query = json is Map ? json['q'] : json;
    if (query is! String || query.trim().isEmpty) return null;
    return PinnedSearch(
      query.trim(),
      content: json is Map && json['content'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PinnedSearch && other.query == query && other.content == content;

  @override
  int get hashCode => Object.hash(query, content);
}

/// How far a download of the content-search model has come.
@immutable
class DownloadProgress {
  const DownloadProgress(this.received, this.total);
  final int received;
  final int total;
}

class DirNode {
  const DirNode(this.name, this.path, this.hasChildren);
  final String name;
  final String path;
  final bool hasChildren;
}

const double minTileSize = 72;
const double maxTileSize = 520;

/// How much of the height the metadata panel may take as a footer.
const double minBottomShare = 0.15;
const double maxBottomShare = 0.7;

/// Everything the UI shows, and the operations that change it.
class AppState extends ChangeNotifier {
  AppState({
    required this.core,
    required this.thumbs,
    this.pollMs = 0,
    this.videoPlayback = false,
    this.modelSource,
    this.modelFiles,
    this.contentBar,
  }) {
    _events = core.events.listen(_onEvent);
  }

  final NativeCore core;
  final ThumbCache thumbs;
  final int pollMs;

  /// Whether a video player is available on this install.
  final bool videoPlayback;

  /// Where to fetch the content-search model from, and what its files are,
  /// in place of what the core says. For tests, which serve a small model
  /// from this machine.
  final String? modelSource;
  final List<ModelFile>? modelFiles;

  /// How well a picture has to fit a description to count as a match, in
  /// place of the core's own bar. For tests, whose stand-in model sees
  /// nothing in particular in any picture.
  double? contentBar;

  late final StreamSubscription<Map<String, dynamic>> _events;

  // ---------------------------------------------------------------- view

  String? folder;
  bool recursive = true;
  String sort = 'newest';

  /// The order of search results: 'relevance' (best match first), or any
  /// of the orders [sort] takes.
  String searchSort = 'relevance';
  String query = '';

  /// Whether something is being searched for.
  bool get searching => query.trim().isNotEmpty;

  /// The order the grid is in right now.
  String get activeSort => searching ? searchSort : sort;

  /// Whether the search box describes what the pictures show (content
  /// search) rather than text to find in their metadata.
  bool contentSearch = false;

  /// Whether content search has its model, and how far it has got with the
  /// current folder's pictures.
  final ValueNotifier<ContentStatus> content = ValueNotifier(
    const ContentStatus(),
  );

  /// Set while the model is being downloaded.
  final ValueNotifier<DownloadProgress?> download = ValueNotifier(null);

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

  /// True when the window is taller than it is wide. The metadata panel then
  /// sits under the content as a footer instead of beside (or over) it. Set
  /// by the home page as it lays out.
  bool portraitLayout = false;

  double tileSize = 190;
  bool leftOpen = true;
  bool rightOpen = false;
  double leftWidth = 280;
  double rightWidth = 380;

  /// The metadata panel's height as a footer, as a share of the space under
  /// the top bar.
  double bottomShare = 0.36;
  bool prewarm = true;

  /// Grid tiles either crop each image to fill its square or shrink it to
  /// fit whole.
  bool cropTiles = true;

  // ---------------------------------------------------------------- folders

  List<Place> places = const [];
  final Map<String, List<DirNode>> children = {};
  final Set<String> expanded = {};

  /// Bumped when the tree has been opened down to the current folder.
  int treeRevealTick = 0;

  // ---------------------------------------------------------------- pins

  /// Searches and folders the user has pinned, in the order they pinned them.
  List<PinnedSearch> pinnedSearches = const [];
  List<String> pinnedFolders = const [];

  /// Whether the folder panel's "Pinned" section is showing its contents.
  bool pinsOpen = true;

  // ---------------------------------------------------------------- internals

  int _queryTicket = 0;

  /// Scroll the grid to the selection once the next query has answered.
  bool _revealAfterReload = false;
  Timer? _reloadTimer;
  Timer? _queryTimer;
  Timer? _contentTimer;
  ModelDownload? _download;
  bool _disposed = false;
  final Map<String, Timer> _saveTimers = {};
  final Map<String, GenInfo> _metaCache = {};

  MediaItem? get selected =>
      (selectedIndex >= 0 && selectedIndex < items.length)
      ? items[selectedIndex]
      : null;

  /// The folder panel is showing, slid over the content.
  bool get leftFloats => leftOpen && narrowLayout && mode != ViewMode.focus;

  /// The metadata panel is open as a slide-over rather than docked beside or
  /// under the content.
  bool get rightFloats => rightOpen && narrowLayout && !portraitLayout;

  // ================================================================ startup

  /// Load saved settings and reopen the last folder.
  Future<void> restore({String? initialFolder}) async {
    Map<String, dynamic> saved = const {};
    try {
      saved = (await core.call('settings')) as Map<String, dynamic>;
    } catch (_) {}
    double number(String key, double fallback) =>
        double.tryParse('${saved[key]}') ?? fallback;
    bool flag(String key, bool fallback) =>
        saved[key] == null ? fallback : saved[key] == 'true';

    tileSize = number(
      'tile_size',
      tileSize,
    ).clamp(minTileSize, maxTileSize).toDouble();
    leftWidth = number('left_width', leftWidth).clamp(200, 520).toDouble();
    rightWidth = number('right_width', rightWidth).clamp(260, 720).toDouble();
    bottomShare = number(
      'bottom_share',
      bottomShare,
    ).clamp(minBottomShare, maxBottomShare).toDouble();
    leftOpen = flag('left_open', leftOpen);
    rightOpen = flag('right_open', rightOpen);
    recursive = flag('recursive', recursive);
    prewarm = flag('prewarm', prewarm);
    cropTiles = flag('crop_tiles', cropTiles);
    sort = (saved['sort'] as String?) ?? sort;
    searchSort = (saved['search_sort'] as String?) ?? searchSort;
    pinsOpen = flag('pins_open', pinsOpen);
    contentSearch = flag('content_search', contentSearch);
    pinnedSearches = [
      for (final entry in _savedList(saved['pinned_searches']))
        ?PinnedSearch.fromJson(entry),
    ];
    pinnedFolders = [
      for (final entry in _savedList(saved['pinned_folders']))
        if (entry is String && entry.isNotEmpty) entry,
    ];

    await loadPlaces();
    final start = initialFolder ?? saved['folder'] as String?;
    if (start != null && start.isNotEmpty) {
      await openFolder(start, remember: initialFolder == null);
    } else {
      notifyListeners();
    }
  }

  /// A list saved as JSON text; empty if it is missing or unreadable.
  static List<Object?> _savedList(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded : const [];
    } on FormatException {
      return const [];
    }
  }

  /// Run a request whose result (and failure) we have no use for.
  void _fire(Future<dynamic> request) {
    unawaited(request.then<void>((_) {}, onError: (Object _) {}));
  }

  void _save(String key, String value, {bool debounce = false}) {
    void write() =>
        _fire(core.call('set_setting', {'key': key, 'value': value}));

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
          if (p is Map)
            Place(
              p['name'] as String,
              p['path'] as String,
              p['kind'] as String,
            ),
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
          if (d is Map)
            DirNode(
              d['name'] as String,
              d['path'] as String,
              d['has_sub'] as bool? ?? false,
            ),
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
      final under =
          path == p.path ||
          path.startsWith(p.path.endsWith('/') ? p.path : '${p.path}/');
      if (under && (best == null || p.path.length > best.path.length)) best = p;
    }
    if (best == null) return;
    var current = best.path;
    final rest = path
        .substring(current.length)
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    for (final segment in rest) {
      expanded.add(current);
      children[current] ??= await _list(current);
      current = current.endsWith('/')
          ? '$current$segment'
          : '$current/$segment';
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
      await core.call('set_folder', {
        'dir': dir,
        'recursive': recursive,
        'poll_ms': pollMs,
      });
    } catch (e) {
      scan.value = ScanStatus(error: '$e');
    }
    unawaited(revealInTree(dir));
    await _reload();
    if (contentSearch) unawaited(refreshContent());
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

  /// Choose the order of the grid: of search results while something is
  /// being searched for, of the folder otherwise. The two are remembered
  /// apart, so searches can stay best match first.
  void setSort(String value) {
    if (searching) {
      if (searchSort == value) return;
      searchSort = value;
      _save('search_sort', value);
    } else {
      if (sort == value || value == 'relevance') return;
      sort = value;
      _save('sort', value);
    }
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

  /// Search for [text] at once, as if it had just been typed. [content]
  /// says which kind of search it is; left out, the kind stays as it is.
  void applySearch(String text, {bool? content}) {
    searchText.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _queryTimer?.cancel();
    final kind = content ?? contentSearch;
    if (query != text || kind != contentSearch) {
      query = text;
      if (kind != contentSearch) {
        _setContentSearch(kind);
      } else {
        _reload();
      }
    }
    notifyListeners();
  }

  /// Show only the images that match [text], which replaces whatever was
  /// being searched for. Leaves the focus view, and puts away a metadata
  /// panel that is lying over the grid, so the result is in sight.
  void applyFilter(String text) {
    if (mode == ViewMode.focus) mode = ViewMode.grid;
    if (rightFloats) {
      rightOpen = false;
      _save('right_open', 'false');
    }
    _revealAfterReload = query != text || contentSearch;
    revealTick++;
    // Filters are written in the metadata search's own language.
    applySearch(text, content: false);
  }

  // ================================================================ content

  /// Switch the search box between finding text in the metadata and
  /// describing what the pictures show.
  void toggleContentSearch() {
    _setContentSearch(!contentSearch);
    notifyListeners();
  }

  void _setContentSearch(bool value) {
    contentSearch = value;
    _save('content_search', '$value');
    _reload();
    if (value) unawaited(refreshContent());
  }

  /// Ask the core where content search stands for this folder, and have it
  /// look at whatever pictures it has not seen yet.
  Future<void> refreshContent() async {
    final dir = folder;
    if (dir == null || _disposed) return;
    final ContentStatus status;
    try {
      final json = await core.call('content_status', {
        'dir': dir,
        'recursive': recursive,
      });
      status = ContentStatus.fromJson(json as Map<String, dynamic>);
    } catch (e) {
      if (!_disposed) content.value = ContentStatus(known: true, error: '$e');
      return;
    }
    if (_disposed || dir != folder) return;
    content.value = status;
    if (status.installed && contentSearch) {
      _fire(core.call('content_index', {'dir': dir, 'recursive': recursive}));
    }
  }

  /// Something about the folder's pictures changed: look again, but not on
  /// every single event of a burst.
  void _contentSoon() {
    if (!contentSearch || !content.value.installed) return;
    _contentTimer?.cancel();
    _contentTimer = Timer(const Duration(milliseconds: 1200), refreshContent);
  }

  void _onContentEvent(Map<String, dynamic> e) {
    final state = e['state'] as String? ?? '';
    final done = (e['done'] as num?)?.toInt() ?? 0;
    final todo = (e['total'] as num?)?.toInt() ?? 0;
    final before = content.value;
    switch (state) {
      case 'indexing':
        content.value = before.copyWith(
          indexing: true,
          done: done,
          todo: todo,
          error: () => null,
        );
      case 'done':
        content.value = before.copyWith(indexing: false, done: 0, todo: 0);
        // The counts moved on: fetch them, without starting another pass.
        if (done > 0) unawaited(_recount());
      case 'no_model':
        content.value = before.copyWith(installed: false, indexing: false);
      case 'error':
        content.value = before.copyWith(
          indexing: false,
          error: () => e['error'] as String? ?? 'Content search failed',
        );
    }
    // More pictures looked at can mean better answers to what is typed.
    if (contentSearch && query.trim().isNotEmpty && done > 0) {
      _reloadTimer ??= Timer(const Duration(milliseconds: 900), () {
        _reloadTimer = null;
        _reload();
      });
    }
  }

  Future<void> _recount() async {
    final dir = folder;
    if (dir == null || _disposed) return;
    try {
      final json = await core.call('content_status', {
        'dir': dir,
        'recursive': recursive,
      });
      final status = ContentStatus.fromJson(json as Map<String, dynamic>);
      if (_disposed || dir != folder) return;
      content.value = content.value.copyWith(embedded: status.embedded);
    } catch (_) {}
  }

  /// Fetch the content-search model. Progress shows in [download]; when it
  /// is done the folder's pictures start being looked at.
  Future<void> downloadModel() async {
    if (_download != null) return;
    final status = content.value;
    if (status.modelDir.isEmpty) return;
    final files =
        modelFiles ??
        [for (final (name, bytes) in status.files) ModelFile(name, bytes)];
    var shown = -1;
    final job = ModelDownload(
      source: modelSource ?? status.source,
      directory: status.modelDir,
      files: files,
      onProgress: (received, total) {
        // A step of the bar at a time, not every packet.
        final step = total <= 0 ? 0 : received * 200 ~/ total;
        if (step == shown || _disposed) return;
        shown = step;
        download.value = DownloadProgress(received, total);
      },
    );
    _download = job;
    download.value = DownloadProgress(0, job.total);
    content.value = status.copyWith(error: () => null);
    try {
      await job.run();
    } on DownloadCancelled {
      // Nothing to say: it was asked for.
    } catch (e) {
      if (!_disposed) content.value = content.value.copyWith(error: () => '$e');
    } finally {
      _download = null;
      if (!_disposed) download.value = null;
    }
    if (_disposed) return;
    await refreshContent();
    if (contentSearch) unawaited(_reload());
  }

  void cancelDownload() => _download?.cancel();

  void rescan() {
    thumbs.retryFailed();
    _fire(core.call('rescan'));
  }

  // ================================================================ pins

  /// The search in the box right now, as a pin.
  PinnedSearch get currentSearch =>
      PinnedSearch(query.trim(), content: contentSearch);

  bool isSearchPinned(PinnedSearch search) => pinnedSearches.contains(search);

  void pinSearch(PinnedSearch search) {
    if (search.query.isEmpty || isSearchPinned(search)) return;
    pinnedSearches = [...pinnedSearches, search];
    _savePinnedSearches();
  }

  void unpinSearch(PinnedSearch search) {
    if (!isSearchPinned(search)) return;
    pinnedSearches = [
      for (final p in pinnedSearches)
        if (p != search) p,
    ];
    _savePinnedSearches();
  }

  void _savePinnedSearches() {
    _save('pinned_searches', jsonEncode(pinnedSearches));
    notifyListeners();
  }

  bool isFolderPinned(String path) => pinnedFolders.contains(path);

  void toggleFolderPin(String path) {
    pinnedFolders = isFolderPinned(path)
        ? [
            for (final p in pinnedFolders)
              if (p != path) p,
          ]
        : [...pinnedFolders, path];
    _save('pinned_folders', jsonEncode(pinnedFolders));
    notifyListeners();
  }

  void togglePins() {
    pinsOpen = !pinsOpen;
    _save('pins_open', '$pinsOpen');
    notifyListeners();
  }

  // ================================================================ items

  void _onEvent(Map<String, dynamic> e) {
    if (e['root'] != folder) return;
    switch (e['t']) {
      case 'content':
        _onContentEvent(e);
      case 'changed':
        _contentSoon();
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
          scan.value = ScanStatus(
            error: e['error'] as String? ?? 'Could not read this folder',
          );
        } else if (state == 'done') {
          scan.value = ScanStatus.idle;
          if (prewarm) _warm();
          _contentSoon();
        } else {
          scan.value = ScanStatus(running: true, done: done, total: total);
        }
    }
  }

  void _warm() {
    final dir = folder;
    if (dir == null) return;
    _fire(
      core.call('warm', {'dir': dir, 'recursive': recursive, 'sort': sort}),
    );
  }

  Future<void> _reload() async {
    final dir = folder;
    if (dir == null || _disposed) return;
    final ticket = ++_queryTicket;
    final describing = contentSearch && searching;
    ItemList list;
    try {
      list = ItemList.parse(
        describing
            ? await core.contentQuery(
                dir: dir,
                recursive: recursive,
                text: query,
                sort: searchSort,
                bar: contentBar,
              )
            : await core.query(
                dir: dir,
                recursive: recursive,
                text: query,
                sort: activeSort,
                then: sort,
              ),
      );
    } catch (e) {
      if (ticket != _queryTicket || _disposed) return;
      if (!describing) {
        scan.value = ScanStatus(error: '$e');
        return;
      }
      // No model yet, most likely; the banner over the grid says what to do.
      list = ItemList.empty;
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
    if (_revealAfterReload) {
      _revealAfterReload = false;
      if (selectedIndex >= 0) revealTick++;
    }
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
    final from = selectedIndex < 0
        ? (delta > 0 ? -1 : items.length)
        : selectedIndex;
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

  void toggleCrop() {
    cropTiles = !cropTiles;
    _save('crop_tiles', '$cropTiles');
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

  /// Close whichever panels are slid over the content. A docked metadata
  /// panel stays where it is.
  void closeOverlays() {
    if (!narrowLayout) return;
    final right = rightFloats;
    if (!leftOpen && !right) return;
    if (leftOpen) {
      leftOpen = false;
      _save('left_open', 'false');
    }
    if (right) {
      rightOpen = false;
      _save('right_open', 'false');
    }
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

  void setBottomShare(double value) {
    bottomShare = value.clamp(minBottomShare, maxBottomShare).toDouble();
    _save('bottom_share', bottomShare.toStringAsFixed(3), debounce: true);
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

  /// What the current folder's images were made with, and how often.
  Future<UsageStats> usage() async {
    final dir = folder;
    if (dir == null) return UsageStats.empty;
    final json = await core.call('usage', {
      'dir': dir,
      'recursive': recursive,
    });
    return UsageStats.fromJson(json as Map<String, dynamic>);
  }

  @override
  void dispose() {
    _disposed = true;
    _events.cancel();
    _reloadTimer?.cancel();
    _queryTimer?.cancel();
    _contentTimer?.cancel();
    _download?.cancel();
    content.dispose();
    download.dispose();
    for (final t in _saveTimers.values) {
      t.cancel();
    }
    scan.dispose();
    searchText.dispose();
    searchFocus.dispose();
    super.dispose();
  }
}
