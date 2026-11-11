import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../crypto/cipher.dart';
import '../crypto/kdf.dart';
import '../crypto/vault_crypto.dart';
import '../models/vault_item.dart';
import '../models/vault_meta.dart';
import '../storage/app_settings.dart';
import '../storage/backup.dart';
import '../storage/merge.dart';
import '../storage/vault_store.dart';

enum VaultStatus { loading, needsSetup, locked, unlocked }

/// Для импорта копии другого хранилища нужен её мастер-пароль.
class BackupPasswordRequired implements Exception {
  const BackupPasswordRequired();
}

/// Состояние приложения: открытое хранилище, расшифрованные записи в
/// памяти, блокировка и синхронизация с папкой на диске.
class VaultController extends ChangeNotifier {
  VaultController(this.settings);

  final AppSettings settings;

  VaultStatus _status = VaultStatus.loading;
  VaultStatus get status => _status;

  /// Пояснение на экране блокировки/настройки (почему мы здесь оказались).
  String? notice;

  VaultStore? _store;
  VaultMeta? _meta;
  Keyring? _keyring;

  Map<String, VaultItem> _all = {};
  List<VaultItem> _items = const [];

  /// Записи без удалённых.
  List<VaultItem> get items => _items;

  /// Файлы, которые пока не удалось прочитать (ждут синхронизации ключа).
  int unreadable = 0;

  String? get vaultPath => _store?.root.path;
  bool get isLightKdf => _meta?.kdf.isLight ?? false;

  StreamSubscription<void>? _watchSubscription;
  Timer? _reloadDebounce;
  Timer? _pollTimer;
  Timer? _idleTimer;
  int? _lastSignature;
  DateTime _lastActivity = DateTime.now();
  int _autoLockSuspended = 0;
  Future<void> _queue = Future.value();

  // ---------------------------------------------------------------- запуск

  Future<void> init() async {
    final path = settings.vaultPath;
    if (path == null) {
      _setStatus(VaultStatus.needsSetup);
      return;
    }
    final store = VaultStore(path);
    try {
      final meta = await store.readMeta();
      if (meta == null) {
        notice = 'В папке «$path» хранилище не найдено. '
            'Если оно ещё синхронизируется — подождите и выберите папку снова.';
        _setStatus(VaultStatus.needsSetup);
        return;
      }
      _store = store;
      _meta = meta;
      _setStatus(VaultStatus.locked);
    } on FormatException catch (e) {
      notice = e.message;
      _setStatus(VaultStatus.needsSetup);
    } on FileSystemException catch (e) {
      notice = 'Нет доступа к папке «$path»: ${e.osError?.message ?? e.message}';
      _setStatus(VaultStatus.needsSetup);
    }
  }

  /// Есть ли в папке уже созданное хранилище.
  Future<bool> vaultExistsAt(String path) async =>
      File(joinPath(path, VaultStore.metaFileName)).exists();

  Future<void> createVault(
    String path,
    String password, {
    bool light = false,
  }) async {
    final store = VaultStore(path);
    if (await store.readMeta() != null) {
      throw StateError('В этой папке уже есть хранилище');
    }
    final (meta, keyring) = await VaultCrypto.create(
      password,
      light ? KdfParams.light() : KdfParams.standard(),
    );
    await store.writeMeta(meta);
    await settings.setVaultPath(path);
    _store = store;
    _meta = meta;
    await _enterUnlocked(keyring);
  }

  /// Подключает уже существующее хранилище (например, пришедшее через
  /// Syncthing) и переходит к вводу пароля.
  Future<void> openExisting(String path) async {
    final store = VaultStore(path);
    final meta = await store.readMeta();
    if (meta == null) throw StateError('Хранилище в папке не найдено');
    await settings.setVaultPath(path);
    _store = store;
    _meta = meta;
    notice = null;
    _setStatus(VaultStatus.locked);
  }

  /// Разворачивает резервную копию в папку и переходит к вводу пароля.
  Future<void> restoreBackup(String path, String backupContent) async {
    final store = VaultStore(path);
    if (await store.readMeta() != null) {
      throw StateError('В этой папке уже есть хранилище');
    }
    final backup = BackupFile.decode(backupContent);
    await backup.restoreInto(store);
    await openExisting(path);
    notice = 'Копия восстановлена. Введите мастер-пароль, '
        'который действовал на момент её создания.';
    notifyListeners();
  }

  /// Отключает папку и возвращает к экрану первого запуска. Файлы не трогает.
  Future<void> forgetVault() async {
    _teardown();
    _store = null;
    _meta = null;
    notice = null;
    await settings.setVaultPath(null);
    _setStatus(VaultStatus.needsSetup);
  }

  // ------------------------------------------------- блокировка/разблокировка

  /// Бросает [WrongPasswordException] при неверном пароле.
  Future<void> unlock(String password) async {
    final store = _store!;
    // Перечитываем meta: пароль могли сменить на другом устройстве.
    final meta = await store.readMeta() ?? _meta!;
    final keyring = await VaultCrypto.unlock(meta, password);
    _meta = meta;
    await _enterUnlocked(keyring);
  }

  Future<void> _enterUnlocked(Keyring keyring) async {
    _keyring = keyring;
    notice = null;
    _lastActivity = DateTime.now();
    final result = await _store!.loadAll(keyring);
    _all = result.items;
    unreadable = result.unreadable;
    _rebuild();
    _lastSignature = await _store!.signature();
    _startWatching();
    _setStatus(VaultStatus.unlocked);
  }

  void lock([String? reason]) {
    if (_status != VaultStatus.unlocked) return;
    _teardown();
    notice = reason;
    _setStatus(VaultStatus.locked);
  }

  void _teardown() {
    _watchSubscription?.cancel();
    _watchSubscription = null;
    _reloadDebounce?.cancel();
    _pollTimer?.cancel();
    _idleTimer?.cancel();
    _keyring?.wipe();
    _keyring = null;
    _store?.clearCache();
    _all = {};
    _items = const [];
    unreadable = 0;
    _lastSignature = null;
  }

  // --------------------------------------------------------- автоблокировка

  /// Вызывается при любом действии пользователя.
  void touch() => _lastActivity = DateTime.now();

  /// На время системных диалогов (выбор файла, разрешения) приложение
  /// уходит в фон — блокировать его в этот момент нельзя.
  Future<T> withAutoLockSuspended<T>(Future<T> Function() action) async {
    _autoLockSuspended++;
    try {
      return await action();
    } finally {
      _autoLockSuspended--;
      touch();
    }
  }

  void _checkIdle() {
    if (_status != VaultStatus.unlocked || _autoLockSuspended > 0) return;
    final limit = Duration(minutes: settings.autoLockMinutes);
    if (DateTime.now().difference(_lastActivity) >= limit) {
      lock('Заблокировано после ${settings.autoLockMinutes} мин бездействия.');
    }
  }

  /// Приложение свернули.
  void onAppPaused() {
    if (_status != VaultStatus.unlocked || _autoLockSuspended > 0) return;
    if (Platform.isAndroid) lock();
  }

  /// Приложение снова на экране.
  void onAppResumed() {
    _checkIdle();
    if (_status == VaultStatus.unlocked) unawaited(reload());
  }

  // ------------------------------------------------------- работа с папкой

  void _startWatching() {
    final store = _store!;
    _watchSubscription = store.watch().listen((_) => _scheduleReload());
    _pollTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      if (_status != VaultStatus.unlocked) return;
      final signature = await store.signature();
      if (signature != _lastSignature) _scheduleReload();
    });
    _idleTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _checkIdle(),
    );
  }

  void _scheduleReload() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 600), reload);
  }

  /// Выполняет операции с файлами строго по очереди.
  Future<T> _exclusive<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Перечитывает папку: подхватывает изменения с других устройств.
  Future<void> reload() => _exclusive(() async {
        final store = _store;
        final keyring = _keyring;
        if (_status != VaultStatus.unlocked || store == null || keyring == null) {
          return;
        }
        try {
          final meta = await store.readMeta();
          if (meta != null) {
            if (meta.keyId != keyring.currentId) {
              lock('Ключ хранилища изменён на другом устройстве. '
                  'Введите актуальный мастер-пароль.');
              return;
            }
            _meta = meta;
          }
          final result = await store.loadAll(keyring);
          if (!identical(_keyring, keyring)) return;
          // Слияние, а не замена: запись не должна пропасть из списка, если
          // её файл в этот момент был занят Syncthing.
          final merged = mergeItems(_all, result.items.values);
          final changed =
              merged.changedIds.isNotEmpty || unreadable != result.unreadable;
          _all = merged.items;
          unreadable = result.unreadable;
          _lastSignature = await store.signature();
          if (changed) {
            _rebuild();
            notifyListeners();
          }
        } on FileSystemException {
          // Папка временно недоступна — попробуем при следующем событии.
        } on FormatException {
          // Meta-файл в процессе замены — попробуем позже.
        }
      });

  void _rebuild() {
    _items = List.unmodifiable(_all.values.where((i) => !i.deleted));
  }

  // ------------------------------------------------------------- записи

  VaultItem? itemById(String? id) {
    if (id == null) return null;
    final item = _all[id];
    return item == null || item.deleted ? null : item;
  }

  /// Все теги, отсортированные по алфавиту.
  List<String> get allTags {
    final tags = <String>{};
    for (final item in _items) {
      tags.addAll(item.tags);
    }
    return tags.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// Заготовка новой записи заданного типа.
  VaultItem draft(ItemType type) {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    return VaultItem(
      id: newUuid(),
      type: type,
      title: '',
      port: type == ItemType.server ? 22 : null,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Сохраняет новую или изменённую запись; возвращает сохранённую версию.
  Future<VaultItem> save(VaultItem item) => _exclusive(() async {
        final keyring = _requireKeyring();
        final stamped = item.copyWith(
          updatedAt: nextUpdatedAt(_all[item.id]?.updatedAt),
          deleted: false,
        );
        await _store!.writeItem(stamped, keyring);
        _all[stamped.id] = stamped;
        _rebuild();
        notifyListeners();
        return stamped;
      });

  /// Удаление: запись заменяется tombstone, файл остаётся для синхронизации.
  Future<void> delete(String id) => _exclusive(() async {
        final keyring = _requireKeyring();
        final existing = _all[id];
        if (existing == null) return;
        final stone = existing.tombstone(nextUpdatedAt(existing.updatedAt));
        await _store!.writeItem(stone, keyring);
        _all[id] = stone;
        _rebuild();
        notifyListeners();
      });

  Keyring _requireKeyring() {
    final keyring = _keyring;
    if (keyring == null || _status != VaultStatus.unlocked) {
      throw StateError('Хранилище заблокировано');
    }
    return keyring;
  }

  // ------------------------------------------------------- мастер-пароль

  /// Меняет мастер-пароль. При [rotateKey] дополнительно создаётся новый
  /// ключ данных и все записи перешифровываются.
  Future<void> changePassword(
    String currentPassword,
    String newPassword, {
    bool rotateKey = false,
  }) async {
    _requireKeyring();
    // Проверяем текущий пароль.
    (await VaultCrypto.unlock(_meta!, currentPassword)).wipe();
    await _exclusive(() async {
      final keyring = _requireKeyring();
      final store = _store!;
      if (!rotateKey) {
        final meta = await VaultCrypto.changePassword(
          _meta!,
          keyring,
          newPassword,
        );
        await store.writeMeta(meta);
        _meta = meta;
        return;
      }
      final (meta, newRing) = await VaultCrypto.rotateKey(
        _meta!,
        keyring,
        newPassword,
      );
      // Сначала meta: в нём лежат и старые ключи, поэтому любое устройство
      // с новым паролем прочитает файлы на любой стадии перешифровки.
      await store.writeMeta(meta);
      _meta = meta;
      _keyring = newRing;
      keyring.wipe();
      store.clearCache();
      // loadAll перешифровывает всё, что зашифровано не текущим ключом.
      final result = await store.loadAll(newRing);
      _all = mergeItems(_all, result.items.values).items;
      unreadable = result.unreadable;
      _lastSignature = await store.signature();
      _rebuild();
      notifyListeners();
    });
  }

  // ------------------------------------------------------ резервные копии

  /// Содержимое файла резервной копии (всё в зашифрованном виде).
  Future<Uint8List> exportBackup() => _exclusive(() async {
        _requireKeyring();
        final backup = await BackupFile.fromStore(_store!, _meta!);
        return Uint8List.fromList(utf8.encode(backup.encode()));
      });

  /// Сливает резервную копию с текущим хранилищем (свежая версия
  /// побеждает). Возвращает число добавленных/обновлённых записей.
  /// Бросает [BackupPasswordRequired], если копия от другого хранилища
  /// или старого ключа и нужен её пароль.
  Future<int> importBackup(String content, {String? password}) async {
    final backup = BackupFile.decode(content);
    final current = _requireKeyring();

    final needsOwnKeys = backup.envelopes.values.any((envelope) {
      final kid = envelope['kid'];
      return kid is! String || current[kid] == null;
    });
    Keyring? backupRing;
    if (needsOwnKeys || backup.meta.vaultId != _meta!.vaultId) {
      if (password == null) throw const BackupPasswordRequired();
      backupRing = await VaultCrypto.unlock(backup.meta, password);
    }

    try {
      return await _exclusive(() async {
        final keyring = _requireKeyring();
        final incoming = <VaultItem>[];
        for (final entry in backup.envelopes.entries) {
          try {
            incoming.add(
              await VaultCrypto.decryptItem(
                entry.value,
                backupRing ?? keyring,
                expectedId: entry.key,
              ),
            );
          } on Exception {
            // Повреждённую запись копии пропускаем.
          }
        }
        final merged = mergeItems(_all, incoming);
        for (final id in merged.changedIds) {
          await _store!.writeItem(merged.items[id]!, keyring);
        }
        _all = merged.items;
        _rebuild();
        notifyListeners();
        return merged.changedIds.length;
      });
    } finally {
      backupRing?.wipe();
    }
  }

  void _setStatus(VaultStatus value) {
    _status = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }
}
