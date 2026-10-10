import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/providers/download_queue_provider.dart';
import 'package:spotiflac_android/providers/library_browse_provider.dart';
import 'package:spotiflac_android/screens/downloaded_album_screen.dart';
import 'package:spotiflac_android/screens/spotify_account_screen.dart';
import 'package:spotiflac_android/screens/local_album_screen.dart';
import 'package:spotiflac_android/services/album_completeness.dart';
import 'package:spotiflac_android/services/downloaded_embedded_cover_resolver.dart';
import 'package:spotiflac_android/services/library_database.dart';
import 'package:spotiflac_android/utils/nav_bar_inset.dart';
import 'package:spotiflac_android/widgets/app_bottom_sheet.dart';
import 'package:spotiflac_android/widgets/app_search_field.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';
import 'package:spotiflac_android/widgets/cached_cover_image.dart';
import 'package:spotiflac_android/widgets/library_search_results.dart';

enum MornyeLibraryPage { overview, albums, artists }

class MornyeLibraryScreen extends ConsumerStatefulWidget {
  const MornyeLibraryScreen({
    super.key,
    required this.onOpenSection,
    this.page = MornyeLibraryPage.overview,
    this.artist,
  });

  final ValueChanged<String> onOpenSection;
  final MornyeLibraryPage page;
  final String? artist;

  @override
  ConsumerState<MornyeLibraryScreen> createState() =>
      _MornyeLibraryScreenState();
}

class _MornyeLibraryScreenState extends ConsumerState<MornyeLibraryScreen> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  Timer? _debounce;
  bool _showSearch = false;
  String _query = '';
  late String _sort;
  static const int _pageSize = 40;
  String? _completeness;
  List<LibraryBrowseEntry> _rows = const [];
  bool _loading = true;

  bool get _overview => widget.page == MornyeLibraryPage.overview;
  bool get _artists => widget.page == MornyeLibraryPage.artists;
  LibraryBrowseRequest get _request => (
    artists: _artists,
    artist: widget.artist,
    search: _query,
    sort: _sort,
    limit: _pageSize,
    completeness: _completeness,
  );

  @override
  void initState() {
    super.initState();
    _sort = _overview ? 'latest' : 'a-z';
    _scroll.addListener(_loadMore);
  }

  void _loadMore() {
    if (!mounted ||
        !_scroll.hasClients ||
        _scroll.position.extentAfter >= 500) {
      return;
    }
    final request = _request;
    final current = ref.read(libraryBrowseProvider(request));
    if (!current.hasValue) return;
    final state = current.requireValue;
    if (!state.hasMore || state.isLoadingMore) return;
    unawaited(ref.read(libraryBrowseProvider(request).notifier).loadMore());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _searchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || _query == value.trim()) return;
      setState(() {
        _query = value.trim();
        _rows = const [];
      });
    });
  }

  void _openPage(MornyeLibraryPage page, {String? artist}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: MornyeLibraryScreen(
            page: page,
            artist: artist,
            onOpenSection: widget.onOpenSection,
          ),
        ),
      ),
    );
  }

  Future<void> _openAlbum(LibraryBrowseEntry entry) async {
    if (entry.source != 'local') {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DownloadedAlbumScreen(
            albumName: entry.name,
            artistName: entry.artist,
            coverUrl: entry.cover,
          ),
        ),
      );
      return;
    }
    final rows = await LibraryDatabase.instance.getQueueLocalAlbumTracksByKey(
      entry.key,
    );
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LocalAlbumScreen(
          albumName: entry.name,
          artistName: entry.artist,
          coverPath: entry.cover,
          tracks: rows.map(LocalLibraryItem.fromJson).toList(growable: false),
        ),
      ),
    );
  }

  Future<void> _chooseCompleteness() async {
    final selected = await showAppBottomSheet<String>(
      context: context,
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(sheetContext.l10n.libraryFilterAll),
            trailing: _completeness == null ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(sheetContext, 'all'),
          ),
          ListTile(
            title: Text(sheetContext.l10n.libraryFilterIncompleteAlbums),
            trailing: _completeness == incompleteAlbumFilter
                ? const Icon(Icons.check)
                : null,
            onTap: () => Navigator.pop(sheetContext, incompleteAlbumFilter),
          ),
          ListTile(
            title: Text(sheetContext.l10n.libraryAlbumCompletenessUnknown),
            trailing: _completeness == unknownAlbumCompletenessFilter
                ? const Icon(Icons.check)
                : null,
            onTap: () =>
                Navigator.pop(sheetContext, unknownAlbumCompletenessFilter),
          ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    setState(() {
      _completeness = selected == 'all' ? null : selected;
      _rows = const [];
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _chooseSort() async {
    final selected = await showAppBottomSheet<String>(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final option in [
            ('a-z', context.l10n.searchSortTitleAZ),
            ('latest', context.l10n.libraryRecentlyAdded),
          ])
            ListTile(
              title: Text(option.$2),
              trailing: _sort == option.$1 ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, option.$1),
            ),
        ],
      ),
    );
    if (!mounted || selected == null || selected == _sort) return;
    setState(() {
      _sort = selected;
      _rows = const [];
    });
    _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final searchingLibrary = _overview && _query.isNotEmpty;
    final AsyncValue<LibraryBrowseState> result = searchingLibrary
        ? const AsyncData<LibraryBrowseState>(
            LibraryBrowseState([], hasMore: false),
          )
        : ref.watch(libraryBrowseProvider(_request));
    _loading = result.isLoading;
    if (result.hasValue) _rows = result.requireValue.entries;
    final title =
        widget.artist ??
        (_overview
            ? context.l10n.navLibrary
            : _artists
            ? context.l10n.searchArtists
            : context.l10n.searchAlbums);
    final actions = <Widget>[
      IconButton(
        tooltip: context.l10n.librarySearchHint,
        icon: const Icon(Icons.search),
        onPressed: () => setState(() => _showSearch = !_showSearch),
      ),
      if (_overview)
        Consumer(
          builder: (context, ref, _) {
            final count = ref.watch(
              downloadQueueLookupProvider.select(
                (s) => s.notCompletedItemIds.length,
              ),
            );
            return TextButton.icon(
              onPressed: () => widget.onOpenSection('downloads'),
              icon: Badge(
                isLabelVisible: count > 0,
                label: Text('$count'),
                child: const Icon(Icons.downloading_outlined),
              ),
              label: Text(context.l10n.libraryDownloads),
            );
          },
        )
      else if (!_artists) ...[
        IconButton(
          tooltip: context.l10n.libraryFilterTitle,
          icon: const Icon(Icons.filter_list),
          onPressed: _chooseCompleteness,
        ),
        IconButton(
          tooltip: context.l10n.searchSortTitle,
          icon: const Icon(Icons.sort),
          onPressed: _chooseSort,
        ),
      ],
    ];
    return RefreshIndicator(
      onRefresh: () async {
        if (searchingLibrary) return;
        ref.invalidate(libraryBrowseProvider(_request));
        await ref.read(libraryBrowseProvider(_request).future);
      },
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (_overview)
            AppSliverHeader.tabRoot(title: title, actions: actions)
          else
            AppSliverHeader.page(title: title, actions: actions),
          if (_showSearch)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                child: AppSearchField(
                  controller: _search,
                  autofocus: true,
                  hintText: context.l10n.librarySearchHint,
                  clearTooltip: context.l10n.dialogClear,
                  onChanged: _searchChanged,
                  onClear: () {
                    _search.clear();
                    _searchChanged('');
                  },
                ),
              ),
            ),
          if (searchingLibrary)
            LibrarySearchResults(
              query: _query,
              onOpenArtist: (artist) =>
                  _openPage(MornyeLibraryPage.albums, artist: artist),
            ),
          if (!searchingLibrary) ...[
            if (_overview && _query.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                sliver: SliverList.list(
                  children: [
                    for (final category in [
                      (
                        Icons.queue_music,
                        context.l10n.searchPlaylists,
                        () => widget.onOpenSection('playlists'),
                      ),
                      (
                        Icons.music_note,
                        'Spotify Playlists',
                        () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const SpotifyAccountScreen(),
                          ),
                        ),
                      ),
                      (
                        Icons.mic_none,
                        context.l10n.searchArtists,
                        () => _openPage(MornyeLibraryPage.artists),
                      ),
                      (
                        Icons.album_outlined,
                        context.l10n.searchAlbums,
                        () => _openPage(MornyeLibraryPage.albums),
                      ),
                      (
                        Icons.music_note_outlined,
                        context.l10n.searchSongs,
                        () => widget.onOpenSection('all'),
                      ),
                    ]) ...[
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        minVerticalPadding: 12,
                        leading: Icon(
                          category.$1,
                          color: colors.primary,
                          size: 28,
                        ),
                        title: Text(
                          category.$2,
                          style: const TextStyle(fontSize: 22),
                        ),
                        trailing: Icon(
                          Icons.chevron_right,
                          color: colors.onSurfaceVariant,
                        ),
                        onTap: category.$3,
                      ),
                      const Divider(height: 1, indent: 48),
                    ],
                  ],
                ),
              ),
            if (_overview)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                  child: Text(
                    _query.isEmpty
                        ? context.l10n.libraryRecentlyAdded
                        : context.l10n.searchAlbums,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            if (_rows.isNotEmpty)
              if (_artists)
                SliverList.builder(
                  itemCount: _rows.length,
                  itemBuilder: (context, index) {
                    final entry = _rows[index];
                    return Column(
                      children: [
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 8,
                          ),
                          leading: ClipOval(
                            child: SizedBox.square(
                              dimension: 56,
                              child: _LibraryBrowseArtwork(entry: entry),
                            ),
                          ),
                          title: Text(entry.artist),
                          subtitle: Text(
                            context.l10n.queueTrackCount(entry.trackCount),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openPage(
                            MornyeLibraryPage.albums,
                            artist: entry.artist,
                          ),
                        ),
                        const Divider(height: 1, indent: 96, endIndent: 24),
                      ],
                    );
                  },
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  sliver: SliverLayoutBuilder(
                    builder: (context, constraints) {
                      final columns = (constraints.crossAxisExtent / 200)
                          .floor()
                          .clamp(2, 6);
                      final width =
                          (constraints.crossAxisExtent - 20 * (columns - 1)) /
                          columns;
                      final textHeight =
                          MediaQuery.textScalerOf(context).scale(16) * 3.2 + 24;
                      return SliverGrid.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: 20,
                          mainAxisSpacing: 16,
                          mainAxisExtent: width + textHeight,
                        ),
                        itemCount: _rows.length,
                        itemBuilder: (context, index) {
                          final entry = _rows[index];
                          final completeness = _completeness == null
                              ? null
                              : entry.completeness;
                          return Semantics(
                            button: true,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _openAlbum(entry),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  AspectRatio(
                                    aspectRatio: 1,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: _LibraryBrowseArtwork(
                                        entry: entry,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    entry.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 16),
                                  ),
                                  Text(
                                    entry.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                  if (completeness != null) ...[
                                    const SizedBox(height: 4),
                                    Tooltip(
                                      message: completeness.status == 'unknown' ||
                                              completeness.expected == null
                                          ? context.l10n.libraryAlbumCompletenessUnknown
                                          : context.l10n.libraryAlbumMissingTracks(
                                              completeness.present,
                                              completeness.expected!,
                                              (completeness.expected! -
                                                      completeness.present)
                                                  .clamp(0, completeness.expected!)
                                                  .toInt(),
                                            ),
                                      child: Text(
                                        completeness.badge,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: colors.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
            if (result.hasError)
              SliverToBoxAdapter(
                child: Center(
                  child: TextButton.icon(
                    onPressed: () =>
                        ref.invalidate(libraryBrowseProvider(_request)),
                    icon: const Icon(Icons.refresh),
                    label: Text(context.l10n.dialogRetry),
                  ),
                ),
              )
            else if (_loading)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator.adaptive()),
                ),
              )
            else if (_rows.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text(context.l10n.libraryEmptyCollection)),
              ),
          ],
          const NavBarSliverSpacer(),
        ],
      ),
    );
  }
}

class _LibraryBrowseArtwork extends StatefulWidget {
  const _LibraryBrowseArtwork({required this.entry});
  final LibraryBrowseEntry entry;

  @override
  State<_LibraryBrowseArtwork> createState() => _LibraryBrowseArtworkState();
}

class _LibraryBrowseArtworkState extends State<_LibraryBrowseArtwork> {
  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final embedded = entry.cover?.isNotEmpty == true
        ? null
        : DownloadedEmbeddedCoverResolver.resolve(
            entry.samplePath,
            onChanged: () {
              if (mounted) setState(() {});
            },
          );
    Widget fallback(BuildContext context) => ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.album_outlined,
          size: 40,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
    final cover = entry.cover?.isNotEmpty == true ? entry.cover! : embedded;
    return cover == null
        ? fallback(context)
        : LocalOrNetworkCoverImage(url: cover, placeholder: fallback);
  }
}
