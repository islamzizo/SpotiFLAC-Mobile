import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/l10n/app_localizations.dart';
import 'package:spotiflac_android/utils/extension_action_forms.dart';

void main() {
  const channel = MethodChannel('com.zarz.spotiflac/backend');
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  Future<void> showHost(
    WidgetTester tester,
    Future<void> Function(BuildContext) action,
  ) {
    return tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => action(context),
              child: const Text('Connect'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('password form submits transient input and clears its text', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if ((call.arguments as Map)['arguments_json'] != null) {
            return '{"success":true,"state":"active"}';
          }
          return '{"success":true,"action_form":{"version":1,"title":"Account login",'
              '"submit_action":"loginAccount","fields":[{"key":"password",'
              '"label":"Password","type":"password","required":true,"secret":true}]}}';
        });
    Map<String, dynamic>? result;
    await showHost(tester, (context) async {
      result = await runExtensionActionWithForms(
        context,
        'example.account',
        'loginAccount',
      );
    });
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextFormField>(find.byType(TextFormField));
    final controller = field.controller!;
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isTrue,
    );
    await tester.enterText(find.byType(TextFormField), 'fixture-password');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(result!['state'], 'active');
    expect(controller.text, isEmpty);
    expect(calls.map((call) => call.method), [
      'invokeExtensionAction',
      'invokeExtensionAction',
    ]);
    expect(
      (calls.last.arguments as Map)['arguments_json'],
      contains('fixture-password'),
    );
  });

  testWidgets('malformed forms fail without opening a dialog', (tester) async {
    for (final fields in [
      [
        {'key': 'code', 'type': 'otp', 'label': 42},
      ],
      [
        {
          'key': 'region',
          'type': 'select',
          'options': ['one', 'one'],
        },
      ],
      [
        {
          'key': 'region',
          'type': 'select',
          'options': ['one', 42],
        },
      ],
      [
        {'key': 'code', 'type': 'otp'},
        {'key': 'code', 'type': 'otp'},
      ],
    ]) {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls++;
            return jsonEncode({
              'success': true,
              'action_form': {
                'version': 1,
                'submit_action': 'loginAccount',
                'fields': fields,
              },
            });
          });
      Map<String, dynamic>? result;
      await showHost(tester, (context) async {
        result = await runExtensionActionWithForms(
          context,
          'example.account',
          'loginAccount',
        );
      });
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(result!['success'], isFalse);
      expect(find.byType(TextFormField), findsNothing);
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('password and OTP are sent as separate transient actions', (
    tester,
  ) async {
    final inputs = <Map<String, dynamic>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map;
          final raw = args['arguments_json'];
          if (raw != null) {
            inputs.add(
              Map<String, dynamic>.from(
                (jsonDecode(raw as String) as List).single as Map,
              ),
            );
          }
          if (args['action'] == 'submitCode') {
            return '{"success":true,"state":"active"}';
          }
          final otp = raw != null;
          return jsonEncode({
            'success': true,
            'action_form': {
              'version': 1,
              'submit_action': otp ? 'submitCode' : 'loginAccount',
              'fields': [
                {
                  'key': otp ? 'code' : 'password',
                  'type': otp ? 'otp' : 'password',
                  'secret': true,
                },
              ],
            },
          });
        });
    Map<String, dynamic>? result;
    await showHost(tester, (context) async {
      result = await runExtensionActionWithForms(
        context,
        'example.account',
        'loginAccount',
      );
    });
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'fixture-secret');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
      isEmpty,
    );
    await tester.enterText(find.byType(TextFormField), 'A12345');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(inputs, [
      {'password': 'fixture-secret'},
      {'code': 'A12345'},
    ]);
    expect(result!['state'], 'active');
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelled OTP form cancels auth without submitting its code', (
    tester,
  ) async {
    final actions = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map;
          actions.add(args['action'] as String);
          expect(args.containsKey('arguments_json'), isFalse);
          if (args['action'] == 'cancelAccountAuth') return '{"success":true}';
          return '{"success":true,"byoa_form":{"version":1,"title":"OTP",'
              '"submit_action":"submitAccountOTP","cancel_action":"cancelAccountAuth",'
              '"fields":[{"key":"code","label":"Code","type":"otp","secret":true}]}}';
        });
    await showHost(tester, (context) async {
      await runExtensionActionWithForms(
        context,
        'example.account',
        'submitAccountOTP',
      );
    });
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '123456');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(actions, ['submitAccountOTP', 'cancelAccountAuth']);
  });
}
