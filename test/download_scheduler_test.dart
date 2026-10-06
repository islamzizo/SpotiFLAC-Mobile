import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/download_scheduler.dart';

class _Queue {
  final queued = <String>['a', 'b', 'c', 'd'];
  final started = <String>[];
  final finished = <String>[];
  final work = <String, Completer<void>>{};
  int limit = 2;
  int selections = 0;
  bool paused = false;

  DownloadScheduler<String> get scheduler => DownloadScheduler(
    queuedItems: () {
      selections++;
      return List.of(queued);
    },
    idOf: (id) => id,
    isPaused: () => paused,
    concurrency: () => limit,
    start: (id) {
      queued.remove(id);
      started.add(id);
      return (work[id] = Completer<void>()).future;
    },
    onFinished: finished.add,
  );

  void complete(String id) => work[id]!.complete();
}

void main() {
  testWidgets('fills free slots without scanning when every slot is occupied', (
    tester,
  ) async {
    final queue = _Queue();
    final run = queue.scheduler.run();
    await tester.pump();
    expect(queue.started, ['a', 'b']);
    await tester.pump(const Duration(seconds: 30));
    expect(queue.selections, 1);
    queue.complete('b');
    await tester.pump();
    expect(queue.started, ['a', 'b', 'c']);
    queue.complete('a');
    await tester.pump();
    expect(queue.started, ['a', 'b', 'c', 'd']);
    queue.complete('c');
    queue.complete('d');
    await tester.pump();
    await run;
    expect(queue.finished, ['b', 'a', 'c', 'd']);
  });

  testWidgets(
    'pause drains active downloads and leaves queued work for resume',
    (tester) async {
      final queue = _Queue();
      var done = false;
      final run = queue.scheduler.run().then((_) => done = true);
      await tester.pump();
      queue.paused = true;
      await tester.pump(const Duration(milliseconds: 250));
      queue.complete('a');
      await tester.pump();
      expect(done, false);
      expect(queue.started, ['a', 'b']);
      queue.complete('b');
      await tester.pump();
      await run;
      expect(queue.queued, ['c', 'd']);
      queue.paused = false;
      final resumed = queue.scheduler.run();
      await tester.pump();
      queue.complete('c');
      queue.complete('d');
      await tester.pump();
      await resumed;
    },
  );

  testWidgets('retry waits for its active attempt before starting again', (
    tester,
  ) async {
    final queue = _Queue();
    final run = queue.scheduler.run();
    await tester.pump();
    queue.queued.insert(0, 'a');
    queue.complete('b');
    await tester.pump();
    expect(queue.started, ['a', 'b', 'c']);
    expect(queue.queued, ['a', 'd']);
    queue.complete('a');
    await tester.pump();
    expect(queue.started, ['a', 'b', 'c', 'a']);
    queue.complete('c');
    await tester.pump();
    queue.complete('a');
    queue.complete('d');
    await tester.pump();
    await run;
  });

  testWidgets('uses live ordering and changes concurrency within the bounds', (
    tester,
  ) async {
    final queue = _Queue()..limit = 1;
    final run = queue.scheduler.run();
    await tester.pump();
    queue.queued
      ..clear()
      ..addAll(['d', 'e', 'c']);
    queue.limit = 99;
    await tester.pump(const Duration(milliseconds: 250));
    expect(queue.started, ['a', 'd', 'e']);
    queue.limit = 0;
    queue.complete('d');
    queue.complete('e');
    await tester.pump();
    expect(queue.started, ['a', 'd', 'e']);
    queue.complete('a');
    await tester.pump();
    expect(queue.started, ['a', 'd', 'e', 'c']);
    queue.complete('c');
    await tester.pump();
    await run;
  });

  testWidgets(
    'observes failure and drains other active work before returning',
    (tester) async {
      final queue = _Queue();
      var done = false;
      final error = StateError('Download failed');
      final run = queue.scheduler.run().whenComplete(() => done = true);
      final assertion = expectLater(run, throwsA(same(error)));
      await tester.pump();
      queue.work['a']!.completeError(error);
      await tester.pump();
      expect(done, false);
      expect(queue.started, ['a', 'b']);
      queue.complete('b');
      await tester.pump();
      await assertion;
      expect(queue.finished, ['a', 'b']);
      expect(queue.queued, ['c', 'd']);
    },
  );

  testWidgets(
    'synchronous task failures release their slot without a timer leak',
    (tester) async {
      final run = DownloadScheduler<String>(
        queuedItems: () => ['a'],
        idOf: (id) => id,
        isPaused: () => false,
        concurrency: () => 1,
        start: (_) => throw StateError('Startup failed'),
      ).run();
      final assertion = expectLater(run, throwsStateError);
      await tester.pump();
      await assertion;
    },
  );

  testWidgets('does not start work when the queue is already paused', (
    tester,
  ) async {
    final queue = _Queue()..paused = true;
    await queue.scheduler.run();
    expect(queue.started, isEmpty);
    expect(queue.selections, 0);
  });
}
