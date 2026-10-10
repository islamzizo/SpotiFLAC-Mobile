import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/automix_options.dart';
import 'package:spotiflac_android/services/audio_analysis_jobs.dart';
import 'package:spotiflac_android/services/automix_effect_renderer.dart';

void main() {
  late Directory temporary;
  setUp(
    () async => temporary = await Directory.systemTemp.createTemp('mix-test-'),
  );
  tearDown(() async => temporary.delete(recursive: true));

  test('failed render and cancelled native work clean owned output', () async {
    final done = Completer<bool>();
    final started = Completer<void>();
    final renderer = AutoMixEffectRenderer(
      temporaryDirectory: () async => temporary,
      jobs: AudioAnalysisJobs<bool>(
        start: (arguments) async {
          await File(arguments.last).writeAsString('partial');
          started.complete();
          return (id: 42, completed: done.future);
        },
        cancel: (id) async {
          expect(id, 42);
          done.complete(false);
        },
      ),
    );
    final render = renderer.render(
      '/missing.flac',
      start: Duration.zero,
      duration: const Duration(seconds: 3),
      options: const AutoMixOptions(effect: AutoMixEffect.echo),
    );
    await started.future;
    renderer.cancel();
    expect(await render, isNull);
    expect(await temporary.list().toList(), isEmpty);
    renderer.dispose();
  });

  test(
    'real filters change pitch, attenuate highs, and generate delayed echoes',
    () async {
      final ffmpeg = Platform.environment['SPOTIFLAC_TEST_FFMPEG'] ?? 'ffmpeg';
      final probe = await Process.run(ffmpeg, ['-version']);
      expect(probe.exitCode, 0);
      final jobs = AudioAnalysisJobs<bool>(
        start: (arguments) async => (
          id: 1,
          completed: Process.run(
            ffmpeg,
            arguments,
          ).then((result) => result.exitCode == 0),
        ),
        cancel: (_) async {},
      );
      final renderer = AutoMixEffectRenderer(
        jobs: jobs,
        temporaryDirectory: () async => temporary,
      );
      Future<Float64List> signal(String source, AutoMixOptions options) async {
        final input = File('${temporary.path}/input.wav');
        final generated = await Process.run(ffmpeg, [
          '-y',
          '-f',
          'lavfi',
          '-i',
          source,
          '-t',
          '3',
          input.path,
        ]);
        expect(generated.exitCode, 0, reason: '${generated.stderr}');
        final tail = await renderer.render(
          input.path,
          start: Duration.zero,
          duration: const Duration(seconds: 3),
          options: options,
        );
        expect(tail, isNotNull);
        final pcm = '${temporary.path}/output.pcm';
        final decoded = await Process.run(ffmpeg, [
          '-y',
          '-i',
          tail!.path,
          '-ac',
          '1',
          '-f',
          'f64le',
          pcm,
        ]);
        expect(decoded.exitCode, 0);
        final bytes = await File(pcm).readAsBytes();
        final data = ByteData.sublistView(bytes);
        final samples = Float64List(bytes.length ~/ 8);
        for (var i = 0; i < samples.length; i++) {
          samples[i] = data.getFloat64(i * 8, Endian.little);
        }
        expect(samples.length, 48000 * 3);
        await tail.dispose();
        return samples;
      }

      final pitched = await signal(
        'sine=frequency=440:sample_rate=48000',
        const AutoMixOptions(effect: AutoMixEffect.pitch, pitchSemitones: 2),
      );
      var crossings = 0;
      for (var i = 24001; i < 72000; i++) {
        if (pitched[i - 1] <= 0 && pitched[i] > 0) crossings++;
      }
      expect(crossings, closeTo(440 * pow(2, 2 / 12), 2));
      final filtered = await signal(
        'sine=frequency=5000:sample_rate=48000',
        const AutoMixOptions(effect: AutoMixEffect.muffled),
      );
      final rms = sqrt(
        filtered
                .skip(24000)
                .take(48000)
                .fold<double>(0, (sum, value) => sum + value * value) /
            48000,
      );
      expect(rms, lessThan(0.01));
      final echo = await signal(
        "aevalsrc=if(between(t\\,0.1\\,0.101)\\,0.5\\,0):s=48000",
        const AutoMixOptions(effect: AutoMixEffect.echo),
      );
      double peak(double time) => echo
          .skip((time * 48000).round())
          .take(100)
          .fold<double>(0, (p, value) => max(p, value.abs()));
      expect(peak(0.28), greaterThan(0.05));
      expect(peak(0.46), greaterThan(0.02));
      renderer.dispose();
    },
  );
}
