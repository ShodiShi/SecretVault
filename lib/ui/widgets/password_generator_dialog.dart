import 'package:flutter/material.dart';

import '../../crypto/password_tools.dart';
import '../theme.dart';
import 'common.dart';

/// Диалог генератора паролей. Возвращает выбранный пароль или null.
Future<String?> showPasswordGenerator(BuildContext context) =>
    showDialog<String>(
      context: context,
      builder: (_) => const _GeneratorDialog(),
    );

class _GeneratorDialog extends StatefulWidget {
  const _GeneratorDialog();

  @override
  State<_GeneratorDialog> createState() => _GeneratorDialogState();
}

class _GeneratorDialogState extends State<_GeneratorDialog> {
  GeneratorOptions _options = const GeneratorOptions();
  late String _password = PasswordGenerator.generate(_options);

  void _update(GeneratorOptions options) {
    setState(() {
      _options = options;
      _password = PasswordGenerator.generate(options);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Генератор паролей'),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: SelectableText(
                          _password,
                          key: ValueKey(_password),
                          style: monoStyle.copyWith(fontSize: 16),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Сгенерировать заново',
                      icon: const Icon(Icons.refresh_rounded),
                      onPressed: () => _update(_options),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              StrengthBar(password: _password),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('Длина'),
                  Expanded(
                    child: Slider(
                      value: _options.length.toDouble(),
                      min: 8,
                      max: 64,
                      divisions: 56,
                      label: '${_options.length}',
                      onChanged: (v) =>
                          _update(_options.copyWith(length: v.round())),
                    ),
                  ),
                  SizedBox(
                    width: 28,
                    child: Text(
                      '${_options.length}',
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Заглавные буквы (A–Z)'),
                value: _options.upper,
                onChanged: (v) => _update(_options.copyWith(upper: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Цифры (2–9)'),
                value: _options.digits,
                onChanged: (v) => _update(_options.copyWith(digits: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Символы (!@#\$…)'),
                value: _options.symbols,
                onChanged: (v) => _update(_options.copyWith(symbols: v)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        TextButton(
          onPressed: () => copyValue(context, _password, 'Пароль'),
          child: const Text('Копировать'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _password),
          child: const Text('Использовать'),
        ),
      ],
    );
  }
}
