import 'package:flutter/material.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/widgets/app_alert_dialog.dart';

/// Account input goes straight to the action, never into extension settings.
Future<Map<String, dynamic>?> runExtensionActionWithForms(
  BuildContext context,
  String extensionId,
  String action,
) async {
  Map<String, dynamic>? input;
  for (var step = 0; step < 8; step++) {
    Map<String, dynamic> result;
    try {
      result = await PlatformBridge.invokeExtensionAction(
        extensionId,
        action,
        input: input,
      );
    } finally {
      input?.updateAll((_, value) => value is String ? '' : null);
      input = null;
    }
    if (!context.mounted) return null;
    final nested = result['result'];
    final payload = nested is Map ? nested : result;
    // Accept the supplied protocol while exposing a provider-neutral form API.
    final raw = payload['action_form'] ?? payload['byoa_form'];
    if (payload['success'] != true || raw == null) return result;
    final form = _AccountForm.parse(raw);
    if (form == null) {
      return {
        'success': false,
        'error': context.l10n.extensionAccountInvalidForm,
      };
    }
    input = await showAppDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _AccountFormDialog(form: form),
    );
    if (input == null) {
      if (form.cancelAction != null) {
        await PlatformBridge.invokeExtensionAction(
          extensionId,
          form.cancelAction!,
        );
      }
      return null;
    }
    action = form.submitAction;
  }
  input?.updateAll((_, value) => value is String ? '' : null);
  if (!context.mounted) return null;
  return {'success': false, 'error': context.l10n.extensionAccountRestartLogin};
}

class _AccountForm {
  const _AccountForm(
    this.submitAction,
    this.cancelAction,
    this.title,
    this.description,
    this.fields,
  );
  final String submitAction;
  final String? cancelAction;
  final String? title;
  final String? description;
  final List<Map<String, dynamic>> fields;
  static final _identifier = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$');
  static bool _action(dynamic value) =>
      value is String && _identifier.hasMatch(value);
  static bool _text(dynamic value, int max) =>
      value == null || (value is String && value.length <= max);

  static _AccountForm? parse(dynamic raw) {
    if (raw is! Map ||
        raw['version'] != 1 ||
        !_action(raw['submit_action']) ||
        (raw['cancel_action'] != null && !_action(raw['cancel_action'])) ||
        !_text(raw['title'], 256) ||
        !_text(raw['description'], 4096)) {
      return null;
    }
    final fields = raw['fields'];
    if (fields is! List || fields.isEmpty || fields.length > 12) return null;
    final validated = <Map<String, dynamic>>[];
    final keys = <String>{};
    for (final item in fields) {
      if (item is! Map || item.keys.any((key) => key is! String)) return null;
      final key = item['key'];
      if (!_action(key) ||
          !keys.add(key as String) ||
          !_text(item['label'], 256) ||
          !const {
            'string',
            'password',
            'otp',
            'number',
            'select',
          }.contains(item['type'])) {
        return null;
      }
      if (item['type'] == 'select') {
        final options = item['options'];
        if (options is! List ||
            options.isEmpty ||
            options.length > 30 ||
            options.any(
              (option) =>
                  option is! String || option.isEmpty || option.length > 256,
            ) ||
            options.toSet().length != options.length ||
            (item['default'] != null && !options.contains(item['default']))) {
          return null;
        }
      }
      validated.add(Map<String, dynamic>.from(item));
    }
    return _AccountForm(
      raw['submit_action'] as String,
      raw['cancel_action'] as String?,
      raw['title'] as String?,
      raw['description'] as String?,
      validated,
    );
  }
}

class _AccountFormDialog extends StatefulWidget {
  const _AccountFormDialog({required this.form});
  final _AccountForm form;
  @override
  State<_AccountFormDialog> createState() => _AccountFormDialogState();
}

class _AccountFormDialogState extends State<_AccountFormDialog> {
  final _controllers = <String, TextEditingController>{};
  final _choices = <String, String>{};
  final _formKey = GlobalKey<FormState>();
  @override
  void initState() {
    super.initState();
    for (final field in widget.form.fields) {
      final key = field['key'] as String;
      if (field['type'] == 'select') {
        _choices[key] =
            field['default'] as String? ??
            (field['options'] as List).first as String;
      } else {
        _controllers[key] = TextEditingController();
      }
    }
  }

  void _clear() {
    for (final controller in _controllers.values) {
      controller.clear();
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    final values = <String, dynamic>{..._choices};
    for (final field in widget.form.fields) {
      final key = field['key'] as String;
      final controller = _controllers[key];
      if (controller != null) {
        values[key] = field['type'] == 'number' && controller.text.isNotEmpty
            ? num.parse(controller.text)
            : controller.text;
      }
    }
    _clear();
    Navigator.pop(context, values);
  }

  @override
  Widget build(BuildContext context) => AppAlertDialog(
    title: Text(widget.form.title ?? context.l10n.extensionAccountTitle),
    content: SingleChildScrollView(
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.form.description != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(widget.form.description!),
              ),
            for (final field in widget.form.fields)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: field['type'] == 'select'
                    ? DropdownButtonFormField<String>(
                        initialValue: _choices[field['key']],
                        decoration: InputDecoration(
                          labelText: field['label'] as String?,
                        ),
                        items: (field['options'] as List)
                            .cast<String>()
                            .map(
                              (option) => DropdownMenuItem(
                                value: option,
                                child: Text(option),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(
                              () => _choices[field['key'] as String] = value,
                            );
                          }
                        },
                      )
                    : TextFormField(
                        controller: _controllers[field['key']],
                        obscureText:
                            field['type'] == 'password' ||
                            field['secret'] == true,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        maxLength: 4096,
                        keyboardType: field['type'] == 'number'
                            ? TextInputType.number
                            : TextInputType.text,
                        decoration: InputDecoration(
                          labelText: field['label'] as String?,
                          counterText: '',
                        ),
                        validator: (value) {
                          if (field['required'] == true &&
                              (value == null || value.isEmpty)) {
                            return context.l10n.extensionAccountRequiredValue;
                          }
                          if (field['type'] == 'number' &&
                              value != null &&
                              value.isNotEmpty &&
                              (num.tryParse(value)?.isFinite != true)) {
                            return context.l10n.extensionAccountInvalidNumber;
                          }
                          return null;
                        },
                      ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      AppDialogAction(
        onPressed: () {
          _clear();
          Navigator.pop(context);
        },
        child: Text(context.l10n.dialogCancel),
      ),
      AppDialogAction(
        filled: true,
        isDefault: true,
        onPressed: _submit,
        child: Text(context.l10n.upgradeIntroContinue),
      ),
    ],
  );
}
