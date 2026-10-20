import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show TextEditingValue, TextSelection;
import 'package:flutter/widgets.dart' show FocusNode, TextEditingController;

import 'core/backends.dart' show RemixImage;
import 'core/model_download.dart';
import 'core/models.dart';
import 'core/native_core.dart';
import 'core/thumb_cache.dart';
import 'platform.dart' show PasteSource, sharedFiles;

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

/// How narrow and wide the side panels may be dragged.
const double minLeftWidth = 200;
const double maxLeftWidth = 520;
const double minRightWidth = 260;
const double maxRightWidth = 720;

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

  /// Short messages for the user ("Saved fox_up4x.png"), shown as toasts by
  /// the home page.
  final StreamController<String> _notices = StreamController.broadcast();
  Stream<String> get notices => _notices.stream;

  /// Zoom nudges from the keyboard for the picture in the focus view: one
  /// stop in (positive) or out (negative) per step.
  final StreamController<int> _zoomSteps = StreamController.broadcast();
  Stream<int> get zoomSteps => _zoomSteps.stream;

  /// Zooms the picture in the focus view [steps] stops in, or out if negative.
  void zoomFocus(int steps) {
    if (mode != ViewMode.focus || steps == 0) return;
    _zoomSteps.add(steps);
  }

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

  /// Pictures ticked for acting on together (their tile's corner box, or
  /// Ctrl-click), by id, in the order they were ticked. Only those still
  /// listed count: a search that leaves one out unticks it.
  final List<int> _checked = [];

  /// Bumped whenever the grid should scroll the selection into view.
  int revealTick = 0;

  /// Set by the grid so keyboard navigation can move by rows and pages.
  int gridColumns = 1;
  int gridRowsPerPage = 1;

  final ValueNotifier<ScanStatus> scan = ValueNotifier(ScanStatus.idle);

  /// Why the last search found nothing, when it is not that nothing
  /// matched: a look-alike search without its model, say.
  String? queryError;

  // ---------------------------------------------------------------- live

  /// Pictures that arrived while the folder was open, by id: marked on the
  /// grid until they are looked at.
  final Set<int> fresh = {};

  /// Jump to each new picture as it arrives, so the app can sit on a second
  /// screen while images are being generated.
  bool followNew = false;

  /// When the folder was opened, ms since the epoch: pictures older than
  /// that which turn up later were indexed, not made.
  int _openedAt = 0;
  Set<int>? _knownIds;
  String _knownKey = '';

  // ---------------------------------------------------------------- notes

  /// Bumped whenever ratings, flags or collections change, so what shows
  /// them reads them again.
  final ValueNotifier<int> notesTick = ValueNotifier(0);

  // ---------------------------------------------------------------- generation

  /// Where the user's generation servers are: comfyui, invokeai, forge.
  Map<String, String> backendUrls = const {};

  /// Words the spelling check should accept, added by the user.
  List<String> userWords = const [];

  /// Upscales running or just finished.
  final ValueNotifier<List<UpscaleJob>> upscales = ValueNotifier(const []);

  /// Set while an upscale model is being downloaded.
  final ValueNotifier<DownloadProgress?> upscaleDownload = ValueNotifier(null);
  ModelDownload? _upscaleDownload;

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
  Future<void>? treeRevealing;

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

  bool _fullScreen = false;

  /// The focus view's picture has the whole screen to itself: no top bar,
  /// no panels, and the system's own bars and window frame put away too.
  /// Only ever true in the focus view; leaving it, however it is left,
  /// leaves full screen as well.
  bool get fullScreen => _fullScreen && mode == ViewMode.focus;

  /// Between the focus view and full screen: a tap on the picture, or F11.
  /// From the grid, F11 opens the selected picture full screen.
  void toggleFullScreen() {
    if (mode != ViewMode.focus) {
      openFocus();
      if (mode != ViewMode.focus) return;
    }
    _fullScreen = !_fullScreen;
    notifyListeners();
  }

  /// Back from full screen to the focus view. False if not in full screen.
  bool exitFullScreen() {
    if (!fullScreen) return false;
    _fullScreen = false;
    notifyListeners();
    return true;
  }

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
    leftWidth = number('left_width', leftWidth).clamp(minLeftWidth, maxLeftWidth).toDouble();
    rightWidth = number('right_width', rightWidth).clamp(minRightWidth, maxRightWidth).toDouble();
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
        if (entry is String && entry.isNotEmpty) normalizePath(entry),
    ];
    followNew = flag('follow_new', followNew);
    backendUrls = {
      for (final kind in backendKinds)
        if ((saved['backend_$kind'] as String? ?? '').isNotEmpty)
          kind: saved['backend_$kind'] as String,
    };
    userWords = [
      for (final w in _savedList(saved['user_words']))
        if (w is String && w.isNotEmpty) w,
    ];

    await loadPlaces();
    final start = initialFolder ?? saved['folder'] as String?;
    if (start != null && start.isNotEmpty) {
      await openFolder(start, remember: initialFolder == null);
      await treeRevealing;
    } else {
      notifyListeners();
    }
    _sharedIn ??= sharedFiles.listen((paths) => unawaited(showShared(paths)));
  }

  StreamSubscription<List<String>>? _sharedIn;

  /// The picture to open in the focus view once a query lists it: the first
  /// of some shared to the app.
  String? _openWhenListed;

  /// Pictures shared to the app from another: open the folder they were put
  /// in, with the first of them in the focus view and how it was made
  /// beside it.
  Future<void> showShared(List<String> paths) async {
    if (paths.isEmpty || _disposed) return;
    final first = normalizePath(paths.first);
    final cut = first.lastIndexOf('/');
    if (cut <= 0) return;
    final dir = first.substring(0, cut);
    _openWhenListed = first;
    if (query.isNotEmpty) {
      query = '';
      searchText.clear();
    }
    if (normalizePath(folder ?? '') != dir) {
      await openFolder(dir);
    } else {
      rescan();
      await _reload();
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
    final norm = normalizePath(path);
    if (expanded.remove(norm) || expanded.remove(path)) {
      notifyListeners();
      return;
    }
    expanded.add(norm);
    notifyListeners();
    final list = await _list(norm);
    children[norm] = list;
    children[path] = list;
    if (!_disposed) notifyListeners();
  }

  /// Open the tree down to [path] so the current folder is visible in it.
  Future<void> revealInTree(String path) async {
    final target = normalizePath(path);
    Place? best;
    for (final p in places) {
      final pPath = normalizePath(p.path);
      final under =
          target == pPath ||
          target.startsWith(pPath.endsWith('/') ? pPath : '$pPath/');
      if (under && (best == null || pPath.length > best.path.length)) best = p;
    }
    if (best == null) {
      final root = target.contains('/')
          ? target.substring(0, target.indexOf('/') + 1)
          : target;
      final p = Place(root, root, 'drive');
      places.add(p);
      best = p;
    }
    var current = normalizePath(best.path);
    final rest = target
        .substring(current.length)
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    for (final segment in rest) {
      expanded.add(current);
      final list = (children[current] ?? await _list(current)).toList();
      final nextCurrent = current.endsWith('/')
          ? '$current$segment'
          : '$current/$segment';
      if (!list.any((d) => normalizePath(d.path) == normalizePath(nextCurrent))) {
        list.add(DirNode(segment, nextCurrent, true));
      }
      children[current] = list;
      current = nextCurrent;
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
    var dir = normalizePath(path.trim());
    if (dir.isEmpty) return;
    folder = dir;
    items = ItemList.empty;
    loaded = false;
    fresh.clear();
    _checked.clear();
    _knownIds = null;
    _openedAt = DateTime.now().millisecondsSinceEpoch;
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
    final rev = revealInTree(dir);
    treeRevealing = rev;
    unawaited(rev);
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
    if (status.installed && (contentSearch || lookingAlike)) {
      _fire(core.call('content_index', {'dir': dir, 'recursive': recursive}));
    }
  }

  /// Something about the folder's pictures changed: look again, but not on
  /// every single event of a burst.
  void _contentSoon() {
    if (!(contentSearch || lookingAlike) || !content.value.installed) return;
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
    if ((contentSearch || lookingAlike) && searching && done > 0) {
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

  bool isFolderPinned(String path) => pinnedFolders.contains(normalizePath(path));

  void toggleFolderPin(String path) {
    final norm = normalizePath(path);
    pinnedFolders = isFolderPinned(norm)
        ? [
            for (final p in pinnedFolders)
              if (p != norm) p,
          ]
        : [...pinnedFolders, norm];
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
    if (e['t'] == 'upscale') return _onUpscaleEvent(e);
    if (normalizePath(e['root'] as String? ?? '') !=
        normalizePath(folder ?? '')) {
      return;
    }
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
      if (!describing && !lookingAlike) {
        scan.value = ScanStatus(error: '$e');
        return;
      }
      // No model yet, most likely; the banner over the grid says what to do.
      list = ItemList.empty;
      queryError = '$e';
    }
    if (ticket != _queryTicket || _disposed) return;
    if (list.isNotEmpty) queryError = null;
    final previousIndex = selectedIndex;
    _noticeArrivals(list);
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
    if (_follow != null) {
      final index = list.indexOfId(_follow!);
      _follow = null;
      if (index >= 0) {
        selectedIndex = index;
        _selectedId = list.idAt(index);
        fresh.remove(_selectedId);
        revealTick++;
      }
    }
    if (mode == ViewMode.focus && list.isEmpty) mode = ViewMode.grid;
    final open = _openWhenListed;
    if (open != null) {
      for (var i = 0; i < list.length; i++) {
        if (normalizePath(list[i].path) != open) continue;
        _openWhenListed = null;
        selectedIndex = i;
        _selectedId = list.idAt(i);
        fresh.remove(_selectedId);
        mode = ViewMode.focus;
        if (!rightOpen) {
          rightOpen = true;
          _save('right_open', 'true');
        }
        break;
      }
    }
    if (_checked.isNotEmpty) {
      final listed = list.ids.toSet();
      _checked.retainWhere(listed.contains);
    }
    _resolveHighlight(list);
    if (_revealAfterReload) {
      _revealAfterReload = false;
      if (selectedIndex >= 0) revealTick++;
    }
    notifyListeners();
  }

  int? _follow;

  /// Mark what is new in [list] since the last answer to the same search,
  /// and, when following, pick the newest of it.
  void _noticeArrivals(ItemList list) {
    final key = '$folder|$recursive|$query|$contentSearch';
    final known = _knownIds;
    final ids = list.ids.toSet();
    if (known != null && key == _knownKey) {
      int? newest;
      int newestTime = -1;
      for (var i = 0; i < list.length; i++) {
        final id = list.idAt(i);
        if (known.contains(id)) continue;
        final item = list[i];
        // Older than the folder's opening: found, not just made.
        if (item.mtime < _openedAt - 5000) continue;
        fresh.add(id);
        if (item.mtime > newestTime) {
          newestTime = item.mtime;
          newest = id;
        }
      }
      if (followNew && newest != null) _follow = newest;
    }
    fresh.retainWhere(ids.contains);
    _knownIds = ids;
    _knownKey = key;
  }

  void toggleFollowNew() {
    followNew = !followNew;
    _save('follow_new', '$followNew');
    notifyListeners();
  }

  /// Forget which pictures are new.
  void clearFresh() {
    if (fresh.isEmpty) return;
    fresh.clear();
    notifyListeners();
  }

  /// Show the newest of the new pictures.
  void showNewest() {
    var best = -1;
    var bestTime = -1;
    for (var i = 0; i < items.length; i++) {
      if (!fresh.contains(items.idAt(i))) continue;
      final t = items[i].mtime;
      if (t > bestTime) {
        bestTime = t;
        best = i;
      }
    }
    if (best >= 0) select(best, reveal: true);
  }

  // ================================================================ selection

  void select(int index, {bool reveal = false}) {
    if (index < 0 || index >= items.length) return;
    if (index == selectedIndex && !reveal) return;
    selectedIndex = index;
    _selectedId = items.idAt(index);
    fresh.remove(_selectedId);
    if (reveal) revealTick++;
    notifyListeners();
  }

  // ---------------------------------------------------------------- ticked

  /// How many pictures are ticked.
  int get checkedCount => _checked.length;

  bool isChecked(int id) => _checked.contains(id);

  /// The ticked pictures, in the order they are listed.
  List<MediaItem> get checkedItems {
    if (_checked.isEmpty) return const [];
    final ids = _checked.toSet();
    return [
      for (var i = 0; i < items.length; i++)
        if (ids.contains(items.idAt(i))) items[i],
    ];
  }

  /// Tick [item], or untick it if it is ticked.
  void toggleChecked(MediaItem item) {
    if (!_checked.remove(item.id)) _checked.add(item.id);
    notifyListeners();
  }

  /// Tick every picture listed.
  void checkAll() {
    _checked
      ..clear()
      ..addAll(items.ids);
    notifyListeners();
  }

  void clearChecked() {
    if (_checked.isEmpty) return;
    _checked.clear();
    notifyListeners();
  }

  /// What an action on [item] should act on: every ticked picture when
  /// [item] is one of them and there is more than one, else [item] alone.
  List<MediaItem> targetsFor(MediaItem item) {
    if (_checked.length < 2 || !_checked.contains(item.id)) return [item];
    return checkedItems;
  }

  /// What a keyboard shortcut should act on: the ticked pictures when there
  /// are two or more, else the selected one.
  List<MediaItem> get keyTargets {
    if (_checked.length >= 2) return checkedItems;
    return [?selected];
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
    _fullScreen = false;
    notifyListeners();
  }

  void closeFocus() {
    if (mode != ViewMode.focus) return;
    mode = ViewMode.grid;
    _fullScreen = false;
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
    leftWidth = value.clamp(minLeftWidth, maxLeftWidth).toDouble();
    _save('left_width', leftWidth.toStringAsFixed(0), debounce: true);
    notifyListeners();
  }

  void setRightWidth(double value) {
    rightWidth = value.clamp(minRightWidth, maxRightWidth).toDouble();
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

  /// What the current folder's images were made with, and how often; only
  /// those that match [text], if given.
  Future<UsageStats> usage({String text = ''}) async {
    final dir = folder;
    if (dir == null) return UsageStats.empty;
    final json = await core.call('usage', {
      'dir': dir,
      'recursive': recursive,
      'text': text,
    });
    return UsageStats.fromJson(json as Map<String, dynamic>);
  }

  // ================================================================ notes

  /// What has been said about [item]: its stars, flag and collections.
  Future<Note> notes(MediaItem item) async =>
      Note.fromJson(await core.call('notes_get', {'path': item.path}));

  /// Change the notes of [targets] (the selection, if left out). The notes
  /// are written to a file in each picture's folder, so they go wherever
  /// the folder goes.
  Future<void> changeNotes({
    List<MediaItem>? targets,
    int? rating,
    Flag? flag,
    List<String> add = const [],
    List<String> remove = const [],
  }) async {
    final list = targets ?? [?selected];
    if (list.isEmpty) return;
    try {
      await core.call('notes_set', {
        'paths': [for (final item in list) item.path],
        'rating': ?rating,
        'flag': ?flag?.word,
        if (add.isNotEmpty) 'add': add,
        if (remove.isNotEmpty) 'remove': remove,
      });
    } catch (e) {
      _notices.add('Could not save: $e');
      return;
    }
    notesTick.value++;
    await _reload();
  }

  /// Give the selected picture (or the ticked ones, see [keyTargets])
  /// [stars]; the same number again, on all of them, clears it.
  Future<void> rateSelected(int stars, {bool toggle = false}) => rate(keyTargets, stars, toggle: toggle);

  /// Flag the selected picture (or the ticked ones); the same flag again,
  /// on all of them, clears it.
  Future<void> flagSelected(Flag flag) => setFlag(keyTargets, flag);

  /// Give [targets] [stars]; with [toggle], when they all have that many
  /// already, take them away.
  Future<void> rate(List<MediaItem> targets, int stars, {bool toggle = false}) async {
    if (targets.isEmpty) return;
    final value = toggle && targets.every((t) => t.rating == stars) ? 0 : stars;
    await changeNotes(targets: targets, rating: value);
  }

  /// Flag [targets]; when they all have that flag already, clear it.
  Future<void> setFlag(List<MediaItem> targets, Flag flag) async {
    if (targets.isEmpty) return;
    await changeNotes(targets: targets, flag: targets.every((t) => t.flag == flag) ? Flag.none : flag);
  }

  /// Every collection known, with how many pictures are in each.
  Future<List<(String, int)>> collections() async {
    try {
      final raw = await core.call('collections') as List;
      return [
        for (final c in raw)
          if (c is Map) (c['name'] as String, (c['count'] as num).toInt()),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Take every picture out of the collection [name], wherever it is, so
  /// the collection no longer exists. The pictures stay where they are.
  Future<bool> deleteCollection(String name) async {
    try {
      await core.call('collection_delete', {'name': name});
    } catch (e) {
      _notices.add('Could not delete the collection: $e');
      return false;
    }
    // Showing it would now show nothing.
    if (query.trim() == exactTerm('collection', name)) {
      applyFilter('');
    }
    notesTick.value++;
    await _reload();
    return true;
  }

  // ================================================================ files

  /// [item] was deleted or moved to the trash: drop it from the index and
  /// its folder's notes. In the grid the selection moves to its neighbour.
  Future<void> forgetFile(MediaItem item) => forgetFiles([item]);

  /// [gone] were deleted or moved to the trash, as [forgetFile].
  Future<void> forgetFiles(List<MediaItem> gone) async {
    if (gone.isEmpty) return;
    final wasSelected = gone.any((g) => g.id == selected?.id);
    final at = selectedIndex;
    for (final item in gone) {
      try {
        await core.call('forget', {'path': item.path});
      } catch (e) {
        _notices.add('Could not update the index: $e');
      }
      _checked.remove(item.id);
    }
    notesTick.value++;
    await _reload();
    if (wasSelected && selectedIndex < 0 && items.isNotEmpty) {
      select(at.clamp(0, items.length - 1).toInt());
    }
  }

  /// Save what is on the clipboard into [dir] under a name that is free
  /// there, and return its path. A file is copied byte for byte, so its
  /// generation data comes along.
  Future<String> pasteInto(String dir, PasteSource source) async {
    final String name;
    final from = source.path;
    if (from != null) {
      name = from.split(RegExp(r'[/\\]')).last;
    } else {
      final given = source.name?.trim() ?? '';
      name = given.contains('.') ? given : 'pasted-${_stamp()}.${extensionForType(source.type)}';
    }
    final target = freeFileName(dir, name);
    if (from != null) {
      await File(from).copy(target);
    } else {
      await File(target).writeAsBytes(source.bytes!, flush: true);
    }
    rescan();
    return target;
  }

  static String _stamp() {
    final d = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}-${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }

  // ================================================================ look-alikes

  /// Whether the search is for pictures that look like one.
  bool get lookingAlike => query.contains('similar:');

  /// Show the pictures that look like [item], most alike first.
  void findSimilar(MediaItem item) {
    applyFilter('similar:"${item.path.replaceAll('"', '')}"');
    unawaited(refreshContent());
  }

  // ================================================================ spelling

  /// Words of this folder's prompts that turn up more than once: its own
  /// vocabulary, which the spelling check accepts.
  Future<List<String>> vocabulary() async {
    final dir = folder;
    if (dir == null) return const [];
    try {
      final raw = await core.call('vocabulary', {
        'dir': dir,
        'recursive': recursive,
      });
      return [for (final w in raw as List) w as String];
    } catch (_) {
      return const [];
    }
  }

  void addUserWord(String word) {
    final w = word.toLowerCase();
    if (w.isEmpty || userWords.contains(w)) return;
    userWords = [...userWords, w];
    _save('user_words', jsonEncode(userWords));
  }

  // ================================================================ backends

  static const List<String> backendKinds = ['comfyui', 'invokeai', 'forge'];

  void setBackendUrl(String kind, String url) {
    final clean = url.trim().replaceFirst(RegExp(r'/+$'), '');
    backendUrls = {...backendUrls, kind: clean}..removeWhere((_, v) => v.isEmpty);
    _save('backend_$kind', clean);
    notifyListeners();
  }

  // ================================================================ remix

  /// The collection every remix made here is put in. Collections exist as
  /// soon as one picture is in them, so the first remix makes it.
  static const String remixCollection = 'Remixes';

  /// Remixes sent: those still waiting on the server, and those back whose
  /// pictures have not been gone to yet.
  final ValueNotifier<List<RemixJob>> remixes = ValueNotifier(const []);
  final List<StreamSubscription<RemixImage>> _remixSubs = [];
  int _remixIds = 0;

  /// Pictures to light up in the grid once the list holds them.
  Set<String>? _highlightPending;
  DateTime? _highlightPendingSince;

  /// The pictures being drawn attention to just now, and a number bumped
  /// each time that starts, so the grid knows to play the animation.
  Set<int> highlightIds = const {};
  int highlightTick = 0;
  Timer? _highlightTimer;

  /// Save each picture [results] brings back beside [original], as
  /// `<name>_remix1.png`, `<name>_remix2.png` and so on, saying so as each
  /// lands, and put it in the [remixCollection]. Waits in the background
  /// for as long as the app is open; how it goes shows in [remixes].
  void collectRemix(MediaItem original, Stream<RemixImage> results) {
    final cut = original.path.lastIndexOf(RegExp(r'[/\\]'));
    final dir = cut < 0 ? '.' : original.path.substring(0, cut);
    final file = original.path.substring(cut + 1);
    final dot = file.lastIndexOf('.');
    final stem = dot > 0 ? file.substring(0, dot) : file;
    final id = ++_remixIds;
    final saved = <String>[];
    var failed = false;
    var saving = Future<void>.value();
    late final StreamSubscription<RemixImage> sub;
    void finish() {
      _remixSubs.remove(sub);
      if (_disposed) return;
      final list = [...remixes.value];
      final at = list.indexWhere((j) => j.id == id);
      if (at < 0) return;
      if (saved.isEmpty) {
        // Nothing came back to go to; the notice has said why.
        if (!failed) _notices.add('The remix brought nothing back');
        list.removeAt(at);
      } else {
        list[at] = list[at].finished(saved);
      }
      remixes.value = list;
    }

    sub = results.listen(
      (image) {
        // One at a time, so two pictures never take the same name.
        saving = saving.then((_) async {
          final path = await _saveRemix(dir, stem, image);
          if (path != null) saved.add(path);
        });
      },
      onError: (Object e) {
        failed = true;
        if (!_disposed) _notices.add('Remix failed: $e');
      },
      onDone: () => saving.whenComplete(finish),
    );
    _remixSubs.add(sub);
    remixes.value = [...remixes.value, RemixJob(id, original.name)];
  }

  /// Write [image] beside the original and put it in the remix collection;
  /// answers with where it went, or null if it could not be saved.
  Future<String?> _saveRemix(String dir, String stem, RemixImage image) async {
    late final String path;
    late final String name;
    try {
      final sep = dir.contains('/') ? '/' : Platform.pathSeparator;
      final base = (dir.endsWith('/') || dir.endsWith(r'\')) ? dir : '$dir$sep';
      var n = 1;
      String next() => '${stem}_remix$n.${image.extension}';
      while (await File('$base${next()}').exists()) {
        n++;
      }
      name = next();
      path = '$base$name';
      // Written aside and renamed, so the folder watcher never sees half a
      // picture.
      final part = File('$base.$name.part');
      await part.writeAsBytes(image.bytes, flush: true);
      await part.rename(path);
    } catch (e) {
      if (!_disposed) _notices.add('Could not save the remix: $e');
      return null;
    }
    if (_disposed) return path;
    try {
      await core.call('notes_set', {
        'paths': [path],
        'add': [remixCollection],
      });
      notesTick.value++;
    } catch (e) {
      _notices.add('Saved $name, but could not add it to $remixCollection: $e');
      _rescanSoon();
      return path;
    }
    _notices.add('Saved $name');
    _rescanSoon();
    return path;
  }

  /// Show the [remixCollection], with the pictures of every remix that has
  /// come back picked out by a short animation. Those remixes are put away;
  /// any still running stay.
  ///
  /// A collection is shown within the open folder and its sub-folders, so
  /// when the new remixes are elsewhere the folder they all share is opened
  /// (and sub-folders included) so they can be seen.
  Future<void> showRemixes() async {
    final done = [for (final j in remixes.value) if (!j.running) j];
    remixes.value = [for (final j in remixes.value) if (j.running) j];
    final paths = [for (final j in done) ...j.saved];
    if (paths.isEmpty) return;
    _highlightPending = paths.toSet();
    _highlightPendingSince = DateTime.now();
    if (mode == ViewMode.focus) mode = ViewMode.grid;
    // Panels slid over the grid would hide them.
    closeOverlays();

    final dirs = {for (final p in paths) _parentOf(p)};
    var root = folder ?? dirs.first;
    for (final d in dirs) {
      root = _commonDir(root, d);
    }
    final filter = exactTerm('collection', remixCollection);
    _queryTimer?.cancel();
    query = filter;
    searchText.value = TextEditingValue(
      text: filter,
      selection: TextSelection.collapsed(offset: filter.length),
    );
    if (contentSearch) {
      contentSearch = false;
      _save('content_search', 'false');
    }
    var reopen = folder != root;
    if (!recursive && dirs.any((d) => d != root)) {
      recursive = true;
      _save('recursive', 'true');
      reopen = true;
    }
    if (reopen) {
      await openFolder(root);
    } else {
      notifyListeners();
      await _reload();
    }
    // Not indexed yet, most likely: look again for them.
    if (_highlightPending != null && !_disposed) rescan();
  }

  static String _parentOf(String path) {
    final norm = normalizePath(path);
    final cut = norm.lastIndexOf('/');
    if (cut < 0) return '.';
    if (cut == 0) return '/';
    if (cut == 2 && norm[1] == ':' && RegExp(r'^[A-Za-z]').hasMatch(norm)) {
      return norm.substring(0, 3);
    }
    return norm.substring(0, cut);
  }

  /// The deepest folder holding both [a] and [b].
  static String _commonDir(String a, String b) {
    final x = normalizePath(a).split('/');
    final y = normalizePath(b).split('/');
    var n = 0;
    while (n < x.length && n < y.length && x[n] == y[n]) {
      n++;
    }
    final common = x.take(n).join('/');
    return common.isEmpty ? '/' : common;
  }

  /// Put away the remixes that have come back, without going to them.
  void dismissDoneRemixes() {
    remixes.value = [for (final j in remixes.value) if (j.running) j];
  }

  /// Called with each new list: if it now holds the pictures waiting to be
  /// pointed out, select the first and start the animation.
  void _resolveHighlight(ItemList list) {
    final paths = _highlightPending;
    if (paths == null) return;
    final since = _highlightPendingSince;
    final waited = since == null ? Duration.zero : DateTime.now().difference(since);
    if (waited > const Duration(seconds: 15)) {
      _highlightPending = null;
      return;
    }
    final ids = <int>{};
    var first = -1;
    for (var i = 0; i < list.length; i++) {
      if (!paths.contains(list[i].path)) continue;
      ids.add(list.idAt(i));
      if (first < 0) first = i;
    }
    if (first < 0) return;
    // The rest may be a moment behind, still being indexed: wait for them a
    // little, then point out what is here.
    if (ids.length < paths.length && waited < const Duration(seconds: 4)) return;
    _highlightPending = null;
    selectedIndex = first;
    _selectedId = list.idAt(first);
    fresh.removeAll(ids);
    revealTick++;
    highlightIds = ids;
    highlightTick++;
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 2400), () {
      if (_disposed) return;
      highlightIds = const {};
      notifyListeners();
    });
  }

  // ================================================================ upscale

  /// The upscale models, whether each is here, and where they come from.
  Future<UpscaleModels> upscaleModels() async =>
      UpscaleModels.fromJson(await core.call('upscale_models') as Map<String, dynamic>);

  /// Fetch an upscale model (a few MB from the Real-ESRGAN releases).
  Future<bool> downloadUpscaleModel(UpscaleModels models, UpscaleModel model) async {
    if (_upscaleDownload != null) return false;
    final job = ModelDownload(
      source: models.source,
      directory: models.dir,
      files: [ModelFile(model.file, model.bytes)],
      onProgress: (received, total) {
        if (!_disposed) upscaleDownload.value = DownloadProgress(received, total);
      },
    );
    _upscaleDownload = job;
    upscaleDownload.value = DownloadProgress(0, job.total);
    try {
      await job.run();
      return true;
    } on DownloadCancelled {
      return false;
    } catch (e) {
      _notices.add('$e');
      return false;
    } finally {
      _upscaleDownload = null;
      if (!_disposed) upscaleDownload.value = null;
    }
  }

  void cancelUpscaleDownload() => _upscaleDownload?.cancel();

  /// Upscale [item] in the background; how it goes shows in [upscales].
  /// Upscales asked for together, waiting for the one before to finish:
  /// they run one at a time, since each uses every core.
  final List<_QueuedUpscale> _upscaleQueue = [];

  /// How many upscales are waiting their turn.
  final ValueNotifier<int> upscalesWaiting = ValueNotifier(0);

  /// Upscale each of [targets] in turn, as [startUpscale]. Videos are
  /// left out.
  Future<void> startUpscales(
    List<MediaItem> targets, {
    required String model,
    required int factor,
    required bool keepMetadata,
  }) async {
    for (final item in targets) {
      if (!item.isVideo) _upscaleQueue.add(_QueuedUpscale(item, model, factor, keepMetadata));
    }
    upscalesWaiting.value = _upscaleQueue.length;
    if (upscales.value.isEmpty) await _nextUpscale();
  }

  /// Stop the upscale running and forget those waiting.
  void cancelAllUpscales() {
    _upscaleQueue.clear();
    upscalesWaiting.value = 0;
    for (final job in upscales.value) {
      cancelUpscale(job.id);
    }
  }

  bool _startingUpscale = false;

  Future<void> _nextUpscale() async {
    if (_startingUpscale) return;
    _startingUpscale = true;
    try {
      while (_upscaleQueue.isNotEmpty && !_disposed && upscales.value.isEmpty) {
        final next = _upscaleQueue.removeAt(0);
        upscalesWaiting.value = _upscaleQueue.length;
        // One that will not start leaves the way open for the next.
        await startUpscale(next.item, model: next.model, factor: next.factor, keepMetadata: next.keepMetadata);
      }
    } finally {
      _startingUpscale = false;
    }
  }

  Future<void> startUpscale(
    MediaItem item, {
    required String model,
    required int factor,
    required bool keepMetadata,
  }) async {
    try {
      final reply = await core.call('upscale', {
        'path': item.path,
        'model': model,
        'factor': factor,
        'metadata': keepMetadata ? 'copy' : 'strip',
      });
      final job = ((reply as Map)['job'] as num).toInt();
      upscales.value = [
        ...upscales.value,
        UpscaleJob(job, item.name, factor: factor),
      ];
    } catch (e) {
      _notices.add('Could not start the upscale: $e');
    }
  }

  void cancelUpscale(int job) {
    _fire(core.call('upscale_cancel', {'job': job}));
  }

  void _onUpscaleEvent(Map<String, dynamic> e) {
    final job = (e['job'] as num?)?.toInt();
    final state = e['state'] as String? ?? '';
    final list = [...upscales.value];
    final at = list.indexWhere((j) => j.id == job);
    if (at < 0) return;
    final current = list[at];
    switch (state) {
      case 'running':
        list[at] = current.copyWith(
          done: (e['done'] as num?)?.toInt() ?? 0,
          total: (e['total'] as num?)?.toInt() ?? 0,
        );
      case 'done':
        list.removeAt(at);
        final path = e['path'] as String? ?? '';
        _notices.add('Saved ${path.split('/').last}');
        _rescanSoon();
      case 'cancelled':
        list.removeAt(at);
      default:
        list.removeAt(at);
        _notices.add('Upscale failed: ${e['error'] ?? 'unknown error'}');
    }
    upscales.value = list;
    if (list.isEmpty && _upscaleQueue.isNotEmpty) unawaited(_nextUpscale());
  }

  /// The watcher normally sees new files; on storage where it cannot, look.
  void _rescanSoon() {
    Timer(const Duration(milliseconds: 800), () {
      if (!_disposed && folder != null) rescan();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _events.cancel();
    _sharedIn?.cancel();
    _reloadTimer?.cancel();
    _queryTimer?.cancel();
    _contentTimer?.cancel();
    _download?.cancel();
    content.dispose();
    download.dispose();
    _upscaleDownload?.cancel();
    upscaleDownload.dispose();
    upscales.dispose();
    for (final sub in [..._remixSubs]) {
      sub.cancel();
    }
    remixes.dispose();
    _highlightTimer?.cancel();
    notesTick.dispose();
    _notices.close();
    _zoomSteps.close();
    for (final t in _saveTimers.values) {
      t.cancel();
    }
    scan.dispose();
    searchText.dispose();
    searchFocus.dispose();
    super.dispose();
  }
}

/// A remix sent to a server: waiting, or back with [saved] pictures.
@immutable
class RemixJob {
  const RemixJob(this.id, this.name, {this.saved = const [], this.running = true});
  final int id;

  /// The name of the picture remixed.
  final String name;

  /// Where the pictures that came back were saved.
  final List<String> saved;
  final bool running;

  RemixJob finished(List<String> saved) => RemixJob(id, name, saved: List.unmodifiable(saved), running: false);
}

/// An upscale waiting for the one before it to finish.
class _QueuedUpscale {
  const _QueuedUpscale(this.item, this.model, this.factor, this.keepMetadata);
  final MediaItem item;
  final String model;
  final int factor;
  final bool keepMetadata;
}

/// An upscale under way.
@immutable
class UpscaleJob {
  const UpscaleJob(this.id, this.name, {required this.factor, this.done = 0, this.total = 0});
  final int id;

  /// The original's file name.
  final String name;
  final int factor;

  /// Tiles done, of how many.
  final int done;
  final int total;

  double? get progress => total > 0 ? done / total : null;

  UpscaleJob copyWith({int? done, int? total}) =>
      UpscaleJob(id, name, factor: factor, done: done ?? this.done, total: total ?? this.total);
}

class UpscaleModel {
  const UpscaleModel({
    required this.id,
    required this.name,
    required this.detail,
    required this.file,
    required this.bytes,
    required this.installed,
  });
  final String id;
  final String name;
  final String detail;
  final String file;
  final int bytes;
  final bool installed;
}

class UpscaleModels {
  const UpscaleModels(this.dir, this.source, this.models);
  final String dir;
  final String source;
  final List<UpscaleModel> models;

  factory UpscaleModels.fromJson(Map<String, dynamic> j) => UpscaleModels(
    j['dir'] as String? ?? '',
    j['source'] as String? ?? '',
    [
      for (final m in (j['models'] as List? ?? const []))
        if (m is Map)
          UpscaleModel(
            id: m['id'] as String? ?? '',
            name: m['name'] as String? ?? '',
            detail: m['detail'] as String? ?? '',
            file: m['file'] as String? ?? '',
            bytes: (m['bytes'] as num?)?.toInt() ?? 0,
            installed: m['installed'] == true,
          ),
    ],
  );
}
