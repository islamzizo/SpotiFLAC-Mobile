import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/models/settings.dart';
import 'package:spotiflac_android/providers/local_library_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/services/library_database.dart';

class _Settings extends SettingsNotifier {
  _Settings({Future<void>? ready, String path = ''})
    : _ready = ready,
      _path = path;

  final Future<void>? _ready;
  final String _path;

  @override
  AppSettings build() => const AppSettings();

  @override
  Future<void> ensureLoaded() async {
    await _ready;
    state = state.copyWith(localLibraryPath: _path);
  }
}

class _LibraryDatabase implements LibraryDatabase {
  _LibraryDatabase(this.sources);

  List<LocalLibrarySource> sources;
  Future<int> Function() count = () async => 2;
  Future<LocalLibraryLookupIndex> Function() index = () async =>
      const LocalLibraryLookupIndex(matchKeys: {'song|artist'});
  bool failSources = false;

  @override
  Future<List<LocalLibrarySource>> getSources() async {
    if (failSources) throw StateError('database is busy');
    return List.of(sources);
  }

  @override
  Future<int> getCount() => count();

  @override
  Future<LocalLibraryLookupIndex> getLookupIndex() => index();

  @override
  Future<LocalLibrarySource?> getSourceByPath(String path) async =>
      sources.where((source) => source.path == path).firstOrNull;

  @override
  Future<void> migrateLegacySource({
    required String path,
    required String displayName,
    String? bookmark,
    String? volumeId,
    bool isRemovable = false,
    bool available = true,
    DateTime? lastScannedAt,
  }) async {
    sources = [
      ...sources,
      LocalLibrarySource(
        id: LibraryDatabase.legacySourceId,
        path: path,
        displayName: displayName,
        available: available,
      ),
    ];
  }

  @override
  Future<void> updateSourceState(
    String sourceId, {
    bool? enabled,
    bool? available,
    DateTime? lastScannedAt,
    DateTime? lastSeenAt,
    String? lastScanError,
    bool clearLastScanError = false,
  }) async {
    sources = [
      for (final source in sources)
        source.id == sourceId
            ? source.copyWith(enabled: enabled, available: available)
            : source,
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 50 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory music;
  late _LibraryDatabase database;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    music = await Directory.systemTemp.createTemp('library_loading_');
    database = _LibraryDatabase([
      LocalLibrarySource(
        id: 'music',
        path: music.path,
        displayName: 'Music',
        trackCount: 2,
      ),
    ]);
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        localLibraryProvider.overrideWith(
          () => LocalLibraryNotifier(database: database),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await music.delete(recursive: true);
  });

  test(
    'upgrade waits for saved settings before migrating the old folder',
    () async {
      final ready = Completer<void>();
      container.dispose();
      database.sources = [];
      container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => _Settings(ready: ready.future, path: music.path),
          ),
          localLibraryProvider.overrideWith(
            () => LocalLibraryNotifier(database: database),
          ),
        ],
      );
      container.read(localLibraryProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(localLibraryProvider).isLoading, isTrue);
      ready.complete();
      await _waitFor(() => !container.read(localLibraryProvider).isLoading);
      expect(container.read(localLibraryProvider).loadFailed, isFalse);
      expect(
        container.read(localLibraryProvider).sources.single.path,
        music.path,
      );
      expect(
        container.read(localLibraryProvider).sources.single.id,
        LibraryDatabase.legacySourceId,
      );
    },
  );

  test(
    'saved folders appear while a large track index is still loading',
    () async {
      final pending = Completer<LocalLibraryLookupIndex>();
      database.index = () => pending.future;
      container.read(localLibraryProvider);
      await _waitFor(
        () => container.read(localLibraryProvider).sources.isNotEmpty,
      );
      final loading = container.read(localLibraryProvider);
      expect(loading.sources.single.path, music.path);
      expect(loading.isLoading, isTrue);
      pending.complete(const LocalLibraryLookupIndex());
      await _waitFor(() => !container.read(localLibraryProvider).isLoading);
      expect(container.read(localLibraryProvider).totalCount, 2);
    },
  );

  test(
    'index failure retains folders and retry recovers without reattaching',
    () async {
      database.index = () async => throw StateError('index read failed');
      container.read(localLibraryProvider);
      await _waitFor(() => !container.read(localLibraryProvider).isLoading);
      final failed = container.read(localLibraryProvider);
      expect(failed.loadFailed, isTrue);
      expect(failed.sources.single.path, music.path);
      database.index = () async => const LocalLibraryLookupIndex();
      await container.read(localLibraryProvider.notifier).reloadFromStorage();
      expect(container.read(localLibraryProvider).loadFailed, isFalse);
      expect(container.read(localLibraryProvider).totalCount, 2);
      expect(container.read(localLibraryProvider).sources.single.id, 'music');
    },
  );

  test(
    'failed reload keeps the previously loaded folders and song count',
    () async {
      container.read(localLibraryProvider);
      await _waitFor(() => !container.read(localLibraryProvider).isLoading);
      database.failSources = true;
      await container.read(localLibraryProvider.notifier).reloadFromStorage();
      final failed = container.read(localLibraryProvider);
      expect(failed.loadFailed, isTrue);
      expect(failed.totalCount, 2);
      expect(failed.sources.single.id, 'music');
      database.failSources = false;
      await container.read(localLibraryProvider.notifier).reloadFromStorage();
      expect(container.read(localLibraryProvider).loadFailed, isFalse);
    },
  );

  test('network collection survives local availability checks', () async {
    database.sources = [
      const LocalLibrarySource(
        id: 'nas',
        path: 'network://nas/Music/',
        displayName: 'NAS / Music',
        trackCount: 2,
      ),
    ];
    container.read(localLibraryProvider);
    await _waitFor(() => !container.read(localLibraryProvider).isLoading);
    await container
        .read(localLibraryProvider.notifier)
        .refreshSourceAvailability();
    final loaded = container.read(localLibraryProvider);
    expect(loaded.sources.single.available, isTrue);
    expect(loaded.sources.single.trackCount, 2);
    expect(loaded.totalCount, 2);
  });

  test('an unavailable folder remains attached instead of vanishing', () async {
    await music.delete(recursive: true);
    database.sources = [
      LocalLibrarySource(
        id: 'missing',
        path: music.path,
        displayName: 'Offline music',
        isRemovable: true,
        available: false,
      ),
    ];
    database.count = () async => 0;
    container.read(localLibraryProvider);
    await _waitFor(() => !container.read(localLibraryProvider).isLoading);
    final loaded = container.read(localLibraryProvider);
    expect(loaded.loadFailed, isFalse);
    expect(loaded.sources.single.available, isFalse);
    expect(loaded.sources.single.path, music.path);
    // Keep teardown simple after deliberately removing the storage above.
    await music.create();
  });
}
