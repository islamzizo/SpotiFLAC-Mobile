import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// Run on dedicated emulators with --keep-app-running: `flutter drive` otherwise
/// uninstalls the app when it finishes. Use --profile on Android and --debug on
/// iOS simulators. SPOTIFLAC_PERFORMANCE_REPORT selects the host JSON output;
/// the aggregate target is integration_test/mornye_performance_test.dart.
Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    final output = File(
      Platform.environment['SPOTIFLAC_PERFORMANCE_REPORT'] ??
          '/tmp/spotiflac-performance.json',
    );
    await output.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
    );
    stdout.writeln('Performance report: ${output.path}');
  },
);
