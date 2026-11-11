import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../storage/app_settings.dart';
import '../../storage/vault_store.dart';
import '../widgets/common.dart';

/// Выдано ли приложению право работать с папкой: на Android запрашивает
/// «Доступ ко всем файлам», затем проверяет запись пробным файлом.
Future<bool> ensureFolderAccess(BuildContext context, String path) async {
  final controller = VaultScope.read(context);
  if (Platform.isAndroid) {
    await controller.withAutoLockSuspended(() async {
      if (await Permission.manageExternalStorage.isGranted) return;
      final status = await Permission.manageExternalStorage.request();
      if (!status.isGranted) await Permission.storage.request();
    });
  }
  try {
    final dir = Directory(path);
    await dir.create(recursive: true);
    final probe = File(joinPath(path, '.access-check.tmp'));
    await probe.writeAsString('ok', flush: true);
    await probe.delete();
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Первый запуск: выбор папки, затем создание мастер-пароля либо
/// подключение уже существующего хранилища.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _path = TextEditingController(text: AppSettings.defaultVaultPath());
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _folderReady = false;
  bool _light = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _path.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String get _folder => _path.text.trim();

  Future<void> _pickFolder() async {
    final controller = VaultScope.read(context);
    final picked = await controller.withAutoLockSuspended(
      () => FilePicker.getDirectoryPath(
        dialogTitle: 'Папка хранилища SecretVault',
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _path.text = picked;
        _error = null;
      });
    }
  }

  Future<bool> _checkAccess() async {
    if (_folder.isEmpty) {
      setState(() => _error = 'Укажите папку хранилища');
      return false;
    }
    final ok = await ensureFolderAccess(context, _folder);
    if (!mounted) return false;
    if (!ok) {
      setState(() {
        _error = Platform.isAndroid
            ? 'Нет доступа к папке. Разрешите приложению «Доступ ко всем '
                'файлам» в настройках Android и повторите.'
            : 'Нет доступа к папке. Выберите другую.';
      });
    }
    return ok;
  }

  Future<void> _continue() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await _checkAccess()) return;
      if (!mounted) return;
      final controller = VaultScope.read(context);
      if (await controller.vaultExistsAt(_folder)) {
        await controller.openExisting(_folder);
      } else if (mounted) {
        setState(() => _folderReady = true);
      }
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on FileSystemException catch (e) {
      if (mounted) setState(() => _error = 'Ошибка доступа: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final password = _password.text;
    if (password.length < 8) {
      setState(() => _error = 'Мастер-пароль должен быть не короче 8 символов');
      return;
    }
    if (password != _confirm.text) {
      setState(() => _error = 'Пароли не совпадают');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await VaultScope.read(context)
          .createVault(_folder, password, light: _light);
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on FileSystemException catch (e) {
      if (mounted) setState(() => _error = 'Ошибка записи: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final controller = VaultScope.read(context);
    setState(() => _error = null);
    try {
      if (!await _checkAccess()) return;
      final file = await controller.withAutoLockSuspended(
        () => FilePicker.pickFile(dialogTitle: 'Файл резервной копии'),
      );
      if (file == null) return;
      setState(() => _busy = true);
      final content = utf8.decode(await file.readAsBytes());
      await controller.restoreBackup(_folder, content);
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on FileSystemException catch (e) {
      if (mounted) setState(() => _error = 'Ошибка записи: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notice = VaultScope.of(context).notice;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: Appear(child: AppLogo())),
                  const SizedBox(height: 24),
                  Text(
                    'SecretVault',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Пароли, серверы, заметки и задачи — в зашифрованной '
                    'папке, которая синхронизируется между вашими устройствами.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  if (notice != null) ...[
                    const SizedBox(height: 16),
                    _Banner(text: notice, icon: Icons.info_outline_rounded),
                  ],
                  const SizedBox(height: 28),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: _folderReady
                          ? _buildPasswordStep(theme)
                          : _buildFolderStep(theme),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    _Banner(
                      text: _error!,
                      icon: Icons.error_outline_rounded,
                      error: true,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFolderStep(ThemeData theme) {
    return Column(
      key: const ValueKey('folder'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Шаг 1. Папка хранилища', style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        TextField(
          controller: _path,
          enabled: !_busy,
          decoration: InputDecoration(
            labelText: 'Путь к папке',
            suffixIcon: IconButton(
              tooltip: 'Выбрать папку',
              icon: const Icon(Icons.folder_open_rounded),
              onPressed: _busy ? null : _pickFolder,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Эту папку должен синхронизировать Syncthing. Если хранилище уже '
          'создано на другом устройстве, дождитесь окончания синхронизации — '
          'приложение найдёт его и попросит мастер-пароль.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        GradientButton(
          label: 'Продолжить',
          icon: Icons.arrow_forward_rounded,
          busy: _busy,
          onPressed: _continue,
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _busy ? null : _restore,
          icon: const Icon(Icons.settings_backup_restore_rounded),
          label: const Text('Восстановить из резервной копии'),
        ),
      ],
    );
  }

  Widget _buildPasswordStep(ThemeData theme) {
    return Column(
      key: const ValueKey('password'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Назад к выбору папки',
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _folderReady = false;
                        _error = null;
                      }),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                'Шаг 2. Мастер-пароль',
                style: theme.textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SecretTextField(
          controller: _password,
          label: 'Мастер-пароль',
          autofocus: true,
          enabled: !_busy,
          textInputAction: TextInputAction.next,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),
        StrengthBar(password: _password.text),
        const SizedBox(height: 14),
        SecretTextField(
          controller: _confirm,
          label: 'Повторите пароль',
          enabled: !_busy,
          onSubmitted: (_) => _create(),
        ),
        const SizedBox(height: 10),
        Text(
          'Пароль нельзя восстановить: без него данные не расшифровать. '
          'Запишите его и храните отдельно от устройств.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 18),
        Text('Защита от перебора (Argon2id)', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Стандартная · 64 МБ')),
            ButtonSegment(value: true, label: Text('Облегчённая · 19 МБ')),
          ],
          selected: {_light},
          onSelectionChanged:
              _busy ? null : (v) => setState(() => _light = v.first),
        ),
        const SizedBox(height: 6),
        Text(
          _light
              ? 'Минимум OWASP. Выбирайте, только если телефон слабый и '
                  'разблокировка со стандартной защитой занимает слишком долго.'
              : 'Рекомендуется. Разблокировка занимает около секунды на '
                  'ноутбуке и несколько секунд на телефоне.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        GradientButton(
          label: 'Создать хранилище',
          icon: Icons.lock_rounded,
          busy: _busy,
          onPressed: _create,
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.icon, this.error = false});

  final String text;
  final IconData icon;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background =
        error ? scheme.errorContainer : scheme.secondaryContainer;
    final foreground =
        error ? scheme.onErrorContainer : scheme.onSecondaryContainer;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: foreground, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(color: foreground))),
        ],
      ),
    );
  }
}

/// Информационная плашка (используется и на экране блокировки).
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({super.key, required this.text, this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => _Banner(
        text: text,
        icon: error ? Icons.error_outline_rounded : Icons.info_outline_rounded,
        error: error,
      );
}
