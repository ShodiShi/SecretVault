import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../crypto/vault_crypto.dart';
import '../../state/vault_controller.dart';
import '../../storage/app_settings.dart';
import '../../storage/backup.dart';
import '../widgets/common.dart';

/// Настройки: оформление, безопасность, папка, резервные копии.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on FileSystemException catch (e) {
      _snack('Ошибка файла: ${e.osError?.message ?? e.message}', error: true);
    } on FormatException catch (e) {
      _snack(e.message, error: true);
    } on StateError catch (e) {
      _snack(e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String message, {bool error = false}) {
    if (mounted) showSnack(context, message, error: error);
  }

  Future<void> _export() => _run(() async {
        final controller = VaultScope.read(context);
        final bytes = await controller.exportBackup();
        final saved = await controller.withAutoLockSuspended(
          () => FilePicker.saveFile(
            dialogTitle: 'Сохранить резервную копию',
            fileName: BackupFile.suggestedFileName(),
            bytes: bytes,
          ),
        );
        if (saved != null) _snack('Резервная копия сохранена');
      });

  Future<void> _import() => _run(() async {
        final controller = VaultScope.read(context);
        final file = await controller.withAutoLockSuspended(
          () => FilePicker.pickFile(dialogTitle: 'Файл резервной копии'),
        );
        if (file == null) return;
        final content = utf8.decode(await file.readAsBytes());
        String? password;
        while (true) {
          try {
            final changed =
                await controller.importBackup(content, password: password);
            _snack(
              changed == 0
                  ? 'В копии нет записей новее текущих'
                  : 'Добавлено или обновлено записей: $changed',
            );
            return;
          } on BackupPasswordRequired {
            if (!mounted) return;
            password = await _askBackupPassword(wrong: false);
          } on WrongPasswordException {
            if (!mounted) return;
            password = await _askBackupPassword(wrong: true);
          }
          if (password == null) return;
        }
      });

  Future<String?> _askBackupPassword({required bool wrong}) {
    return showDialog<String>(
      context: context,
      builder: (_) => _BackupPasswordDialog(wrong: wrong),
    );
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

  Future<void> _changePassword() async {
    final done = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ChangePasswordDialog(),
    );
    if (done == true) _snack('Мастер-пароль изменён');
  }

  @override
  Widget build(BuildContext context) {
    final controller = VaultScope.of(context);
    final settings = controller.settings;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Настройки'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: _busy
              ? const LinearProgressIndicator(minHeight: 3)
              : const SizedBox(height: 3),
        ),
      ),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                const _Header('Оформление'),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<ThemeMode>(
                        segments: const [
                          ButtonSegment(
                            value: ThemeMode.dark,
                            icon: Icon(Icons.dark_mode_rounded),
                            label: Text('Тёмная'),
                          ),
                          ButtonSegment(
                            value: ThemeMode.light,
                            icon: Icon(Icons.light_mode_rounded),
                            label: Text('Светлая'),
                          ),
                          ButtonSegment(
                            value: ThemeMode.system,
                            icon: Icon(Icons.brightness_auto_rounded),
                            label: Text('Системная'),
                          ),
                        ],
                        selected: {settings.themeMode},
                        onSelectionChanged: (value) =>
                            settings.setThemeMode(value.first),
                      ),
                    ),
                  ),
                ),
                const _Header('Безопасность'),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.timer_outlined),
                        title: const Text('Автоблокировка при бездействии'),
                        subtitle: Text(
                          Platform.isAndroid
                              ? 'Также блокируется при сворачивании'
                              : 'Ctrl+L — заблокировать сразу',
                        ),
                        trailing: DropdownButton<int>(
                          value: settings.autoLockMinutes,
                          underline: const SizedBox.shrink(),
                          borderRadius: BorderRadius.circular(14),
                          onChanged: (value) {
                            if (value != null) {
                              settings.setAutoLockMinutes(value);
                            }
                          },
                          items: [
                            for (final m in {
                              ...AppSettings.autoLockChoices,
                              settings.autoLockMinutes,
                            }.toList()
                              ..sort())
                              DropdownMenuItem(
                                value: m,
                                child: Text('$m мин'),
                              ),
                          ],
                        ),
                      ),
                      ListTile(
                        leading: const Icon(Icons.password_rounded),
                        title: const Text('Сменить мастер-пароль'),
                        subtitle: Text(
                          controller.isLightKdf
                              ? 'Argon2id, облегчённый профиль (19 МиБ, t=2)'
                              : 'Argon2id, 64 МиБ, t=3',
                        ),
                        onTap: _busy ? null : _changePassword,
                      ),
                      ListTile(
                        leading: const Icon(Icons.lock_rounded),
                        title: const Text('Заблокировать сейчас'),
                        onTap: () => controller.lock(),
                      ),
                    ],
                  ),
                ),
                const _Header('Хранилище'),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.folder_rounded),
                        title: const Text('Папка'),
                        subtitle: SelectableText(controller.vaultPath ?? '—'),
                      ),
                      ListTile(
                        leading: const Icon(Icons.sync_rounded),
                        title: const Text('Перечитать папку'),
                        subtitle: Text('Записей: ${controller.items.length}'),
                        onTap: _busy
                            ? null
                            : () => _run(() async {
                                  await controller.reload();
                                  _snack('Данные обновлены');
                                }),
                      ),
                      ListTile(
                        leading: const Icon(Icons.drive_file_move_rounded),
                        title: const Text('Выбрать другую папку'),
                        onTap: _busy ? null : _changeFolder,
                      ),
                    ],
                  ),
                ),
                const _Header('Резервная копия'),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.upload_file_rounded),
                        title: const Text('Экспорт в один файл'),
                        subtitle: const Text(
                          'Файл .svbackup зашифрован; для восстановления '
                          'нужен мастер-пароль',
                        ),
                        onTap: _busy ? null : _export,
                      ),
                      ListTile(
                        leading: const Icon(Icons.download_rounded),
                        title: const Text('Импорт из файла'),
                        subtitle: const Text(
                          'Записи объединяются: побеждает более свежая версия',
                        ),
                        onTap: _busy ? null : _import,
                      ),
                    ],
                  ),
                ),
                const _Header('О приложении'),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'SecretVault не выходит в сеть: нет телеметрии, сетевых '
                      'запросов и загружаемых шрифтов. Данные лежат в папке '
                      'в зашифрованном виде (AES-256-GCM), синхронизацию '
                      'папки выполняет Syncthing.\n\n'
                      'Горячие клавиши: Ctrl+F — поиск, Ctrl+N — новая '
                      'запись, Ctrl+L — блокировка, Ctrl+S — сохранить.',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 20, 12, 8),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _BackupPasswordDialog extends StatefulWidget {
  const _BackupPasswordDialog({required this.wrong});

  final bool wrong;

  @override
  State<_BackupPasswordDialog> createState() => _BackupPasswordDialogState();
}

class _BackupPasswordDialogState extends State<_BackupPasswordDialog> {
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (_password.text.isNotEmpty) Navigator.pop(context, _password.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Пароль резервной копии'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Копия зашифрована другим ключом. Введите мастер-пароль, '
              'который действовал при её создании.',
            ),
            const SizedBox(height: 16),
            SecretTextField(
              controller: _password,
              label: 'Мастер-пароль копии',
              autofocus: true,
              errorText: widget.wrong ? 'Пароль не подошёл' : null,
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Импортировать')),
      ],
    );
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();

  bool _rotate = false;
  bool _busy = false;
  String? _currentError;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _currentError = null;
      _error = null;
    });
    if (_next.text.length < 8) {
      setState(() => _error = 'Новый пароль должен быть не короче 8 символов');
      return;
    }
    if (_next.text != _confirm.text) {
      setState(() => _error = 'Пароли не совпадают');
      return;
    }
    final controller = VaultScope.read(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      await controller.changePassword(
        _current.text,
        _next.text,
        rotateKey: _rotate,
      );
      navigator.pop(true);
    } on WrongPasswordException {
      if (mounted) setState(() => _currentError = 'Неверный текущий пароль');
    } on FileSystemException catch (e) {
      if (mounted) {
        setState(() => _error = 'Ошибка записи: ${e.osError?.message ?? e.message}');
      }
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AlertDialog(
      title: const Text('Смена мастер-пароля'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SecretTextField(
                controller: _current,
                label: 'Текущий пароль',
                autofocus: true,
                enabled: !_busy,
                errorText: _currentError,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              SecretTextField(
                controller: _next,
                label: 'Новый пароль',
                enabled: !_busy,
                textInputAction: TextInputAction.next,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              StrengthBar(password: _next.text),
              const SizedBox(height: 12),
              SecretTextField(
                controller: _confirm,
                label: 'Новый пароль ещё раз',
                enabled: !_busy,
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _rotate,
                onChanged:
                    _busy ? null : (v) => setState(() => _rotate = v ?? false),
                title: const Text('Перешифровать все записи новым ключом'),
                subtitle: const Text(
                  'Нужно, если старый пароль мог быть скомпрометирован. '
                  'Перед этим дождитесь синхронизации всех устройств.',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: scheme.error)),
              ],
              if (_busy) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('Сменить'),
        ),
      ],
    );
  }
}
