import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../crypto/vault_crypto.dart';
import '../widgets/common.dart';
import 'setup_screen.dart';

/// Экран блокировки: ввод мастер-пароля.
class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key});

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen>
    with SingleTickerProviderStateMixin {
  final _password = TextEditingController();
  late final _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _shake.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_busy || _password.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await VaultScope.read(context).unlock(_password.text);
    } on WrongPasswordException {
      _fail('Неверный мастер-пароль');
    } on FormatException catch (e) {
      _fail(e.message);
    } on FileSystemException catch (e) {
      _fail('Нет доступа к папке хранилища: ${e.osError?.message ?? e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() => _error = message);
    _password.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _password.text.length,
    );
    _shake.forward(from: 0);
  }

  Future<void> _changeFolder() async {
    final controller = VaultScope.read(context);
    final ok = await confirmDialog(
      context,
      title: 'Выбрать другую папку?',
      message: 'Приложение отключится от текущей папки. Файлы хранилища '
          'останутся на месте, их можно будет подключить снова.',
      confirmLabel: 'Отключить',
    );
    if (ok) await controller.forgetVault();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = VaultScope.of(context);
    final notice = controller.notice;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: Appear(child: AppLogo())),
                  const SizedBox(height: 24),
                  Text(
                    'Хранилище заблокировано',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    controller.vaultPath ?? '',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  if (notice != null) ...[
                    const SizedBox(height: 16),
                    NoticeBanner(text: notice),
                  ],
                  const SizedBox(height: 28),
                  AnimatedBuilder(
                    animation: _shake,
                    builder: (context, child) => Transform.translate(
                      offset: Offset(
                        sin(_shake.value * pi * 6) * 8 * (1 - _shake.value),
                        0,
                      ),
                      child: child,
                    ),
                    child: SecretTextField(
                      controller: _password,
                      label: 'Мастер-пароль',
                      autofocus: true,
                      enabled: !_busy,
                      errorText: _error,
                      onSubmitted: (_) => _unlock(),
                    ),
                  ),
                  const SizedBox(height: 18),
                  GradientButton(
                    label: 'Разблокировать',
                    icon: Icons.lock_open_rounded,
                    busy: _busy,
                    onPressed: _unlock,
                  ),
                  if (_busy) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Вычисляем ключ…',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: _busy ? null : _changeFolder,
                    child: const Text('Другая папка'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
