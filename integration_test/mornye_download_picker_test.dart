import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/models/settings.dart';
import 'package:spotiflac_android/providers/extension_provider.dart';
import 'package:spotiflac_android/providers/runtime_profile_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/app_snack_bar.dart';
import 'package:spotiflac_android/widgets/download_service_picker.dart';
import 'package:spotiflac_android/widgets/mornye_chrome.dart';
import 'package:spotiflac_android/widgets/mornye_context_menu.dart';
import 'package:spotiflac_android/widgets/track_detail_actions.dart';

import 'performance_probe.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => ExtensionState(
    extensions: [
      for (var source = 0; source < 4; source++)
        Extension(
          id: 'source-$source',
          name: 'source-$source',
          displayName: 'Source $source',
          version: '1.0.0',
          description: '',
          enabled: true,
          status: 'loaded',
          hasDownloadProvider: true,
          qualityOptions: [
            for (
              var quality = 0;
              quality <
                  const int.fromEnvironment(
                    'DOWNLOAD_QUALITY_COUNT',
                    defaultValue: 16,
                  );
              quality++
            )
              QualityOption(
                id: 'quality-$quality',
                label: 'Quality $quality',
                description: 'Example audio format',
              ),
          ],
        ),
    ],
  );

  @override
  void refreshEnabledExtensionHealth({bool force = false}) {}
}

void main() {
  const glassOverride = String.fromEnvironment('DOWNLOAD_GLASS_LEVEL');
  final binding = PerformanceTestBinding.ensureInitialized();
  for (final brightness in Brightness.values) {
    testWidgets(
      'download glass, source changes and queue feedback in $brightness',
      (tester) async {
        final probe = PerformanceProbe(
          binding,
          tester,
          suite: 'download_picker_${brightness.name}',
        );
        expect(ui.ImageFilter.isShaderFilterSupported, isTrue);
        final capture = GlobalKey();
        final poses = <String, Object?>{};
        late BuildContext homeContext;
        (String, String)? selection;
        void showPicker(BuildContext context) => DownloadServicePicker.show(
          context,
          trackName: 'Example track',
          artistName: 'Example artist',
          onSelect: (quality, service) {
            selection = (quality, service);
            showQueuedSnackbar(context, 3, 0);
          },
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(_Settings.new),
              extensionProvider.overrideWith(_Extensions.new),
              if (glassOverride.isNotEmpty)
                mornyeGlassLevelProvider.overrideWithValue(
                  MornyeGlassLevel.values.byName(glassOverride),
                ),
            ],
            child: MaterialApp(
              theme: MornyeTheme.build(brightness),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (_, child) => RepaintBoundary(
                key: capture,
                child: AppScaffoldMessenger(child: child!),
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) {
                    homeContext = context;
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Color(0xff76534b),
                                Color(0xff385763),
                                Color(0xff92836b),
                              ],
                            ),
                          ),
                        ),
                        Center(
                          child: TextButton(
                            onPressed: () => showPicker(context),
                            child: const Text('Open download'),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await probe.wait(const Duration(milliseconds: 600));
        Future<void> open() async {
          await tester.tap(find.text('Open download'));
          await probe.wait(const Duration(milliseconds: 500));
          expect(find.byType(DownloadServicePicker), findsOneWidget);
        }

        Future<void> close() async {
          // Exercise barrier dismissal as a user does, including the reverse
          // route transition, rather than removing the test widget tree.
          await tester.tapAt(const Offset(30, 40));
          await probe.wait(const Duration(milliseconds: 400));
          expect(find.byType(DownloadServicePicker), findsNothing);
        }

        await probe.measure(
          'first_open',
          open,
          warmup: () async {},
          repetitions: 1,
        );
        await probe.measure(
          'first_close',
          close,
          warmup: () async {},
          repetitions: 1,
        );
        await probe.measure('open_close', () async {
          await open();
          await close();
        });
        await probe.measure('context_menu_to_picker', () async {
          // The production flow pops the options menu and pushes the picker
          // immediately. Both glass routes overlap during their transitions.
          showMornyeContextMenu<void>(
            context: homeContext,
            builder: (menuContext) => MornyeContextMenu(
              quickActions: [
                MornyeMenuAction(
                  icon: Icons.download,
                  label: 'Download',
                  onPressed: () {
                    Navigator.pop(menuContext);
                    showPicker(homeContext);
                  },
                ),
              ],
              groups: const [],
            ),
          );
          await probe.wait(const Duration(milliseconds: 300));
          await tester.tap(find.text('Download'));
          await probe.wait(const Duration(milliseconds: 500));
          expect(find.byType(MornyeContextMenu), findsNothing);
          expect(find.byType(DownloadServicePicker), findsOneWidget);
          await close();
        });
        await open();
        expect(find.byType(MornyeGlassPanel), findsOneWidget);
        Future<void> savePose(String pose) async {
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(capture),
            );
            final histogram = <String, int>{};
            void visit(Layer layer) {
              histogram.update(
                layer.runtimeType.toString(),
                (count) => count + 1,
                ifAbsent: () => 1,
              );
              if (layer is ContainerLayer) {
                for (
                  var child = layer.firstChild;
                  child != null;
                  child = child.nextSibling
                ) {
                  visit(child);
                }
              }
            }

            // The retained layer is available in profile builds as well.
            // ignore: invalid_use_of_protected_member
            visit(boundary.layer!);
            poses[pose] = histogram;
            final image = await boundary.toImage(
              pixelRatio: tester.view.devicePixelRatio,
            );
            try {
              final bytes = (await image.toByteData(
                format: ui.ImageByteFormat.png,
              ))!;
              final directory = await getTemporaryDirectory();
              final file = File(
                '${directory.path}/download-${brightness.name}-$pose.png',
              );
              await file.writeAsBytes(
                bytes.buffer.asUint8List(
                  bytes.offsetInBytes,
                  bytes.lengthInBytes,
                ),
              );
              debugPrint('DOWNLOAD_GLASS_POSE: ${file.path}');
            } finally {
              image.dispose();
            }
          });
        }

        await savePose('panel');
        await probe.measure('change_sources', () async {
          for (final source in [1, 2, 3, 0]) {
            await tester.tap(find.text('Source $source'));
            await probe.wait(const Duration(milliseconds: 150));
          }
        });
        final scroll = tester.state<ScrollableState>(
          find.descendant(
            of: find.byType(DownloadServicePicker),
            matching: find.byType(Scrollable),
          ),
        );
        if (scroll.position.maxScrollExtent > 0) {
          await probe.measure('scroll_qualities', () async {
            await scroll.position.animateTo(
              scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 500),
              curve: Curves.linear,
            );
            await scroll.position.animateTo(
              0,
              duration: const Duration(milliseconds: 500),
              curve: Curves.linear,
            );
          });
        }
        await tester.tap(find.text('Quality 1'));
        await probe.wait(const Duration(milliseconds: 500));
        expect(selection, ('quality-1', 'source-0'));
        expect(find.byType(DownloadServicePicker), findsNothing);
        expect(find.byType(MornyeGlassPanel), findsOneWidget);
        await savePose('queue');
        await probe.finish(
          metadata: {
            'scope':
                'production download picker and queue feedback with fixture providers; no downloads',
            'brightness': brightness.name,
            'pose_layers': poses,
            'glass_level_override': glassOverride,
            'quality_count': const int.fromEnvironment(
              'DOWNLOAD_QUALITY_COUNT',
              defaultValue: 16,
            ),
          },
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
