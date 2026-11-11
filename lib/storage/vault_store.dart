import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../crypto/cipher.dart';
import '../crypto/vault_crypto.dart';
import '../models/vault_item.dart';
import '../models/vault_meta.dart';
import 'merge.dart';

String joinPath(String a, String b) =>
    a.endsWith(Platform.pathSeparator) || a.endsWith('/')
        ? '$a$b'
        : '$a${Platform.pathSeparator}$b';

String baseName(String path) {
  final i = path.lastIndexOf(RegExp(r'[\\/]'));
  return i < 0 ? path : path.substring(i + 1);
}

class LoadResult {
  LoadResult({
    required this.items,
    required this.unreadable,
    required this.conflictsResolved,
  });

  /// Все записи, включая tombstone: id → запись.
  final Map<String, VaultItem> items;

  /// Файлы, которые не удалось прочитать (неизвестный ключ, повреждение).
  final int unreadable;

  /// Сколько конфликтных файлов Syncthing разобрано и удалено.
  final int conflictsResolved;
}

class _Cached {
  _Cached(this.modified, this.length, this.item, this.keyId);
  final DateTime modified;
  final int length;
  final VaultItem item;
  final String keyId;
}

class _Version {
  _Version(this.file, this.isConflict, this.item, this.keyId);
  final File file;
  final bool isConflict;
  final VaultItem item;
  final String keyId;
}

/// Хранилище — обычная папка: `vault.meta.json` и `items/<uuid>.json`.
/// О Syncthing класс ничего не знает, он лишь аккуратно работает с файлами:
/// пишет атомарно и разбирает файлы `*.sync-conflict-*`.
class VaultStore {
  VaultStore(String path) : root = Directory(path);

  static const metaFileName = 'vault.meta.json';
  static const itemsDirName = 'items';

  static final _itemFilePattern = RegExp(
    r'^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'
    r'(\.sync-conflict-[A-Za-z0-9-]+)?\.json$',
  );

  final Directory root;
  final Map<String, _Cached> _cache = {};

  File get metaFile => File(joinPath(root.path, metaFileName));
  Directory get itemsDir => Directory(joinPath(root.path, itemsDirName));
  File itemFile(String id) => File(joinPath(itemsDir.path, '$id.json'));

  /// Читает метаданные; null, если хранилища в папке ещё нет.
  Future<VaultMeta?> readMeta() async {
    final file = metaFile;
    if (!await file.exists()) return null;
    final json = jsonDecode(await file.readAsString());
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Файл хранилища повреждён');
    }
    return VaultMeta.fromJson(json);
  }

  Future<void> writeMeta(VaultMeta meta) async {
    await itemsDir.create(recursive: true);
    await atomicWrite(metaFile, _encoder.convert(meta.toJson()));
  }

  /// Шифрует запись текущим ключом и атомарно записывает её файл.
  Future<void> writeItem(VaultItem item, Keyring keyring) async {
    final envelope = await VaultCrypto.encryptItem(item, keyring);
    await writeEnvelope(item.id, envelope);
    await _remember(itemFile(item.id), item, keyring.currentId);
  }

  /// Записывает уже зашифрованную запись как есть (восстановление из бэкапа).
  Future<void> writeEnvelope(String id, Map<String, dynamic> envelope) async {
    await atomicWrite(itemFile(id), jsonEncode(envelope));
  }

  /// Зашифрованное содержимое основных файлов записей (для бэкапа).
  Future<Map<String, Map<String, dynamic>>> readEnvelopes() async {
    final result = <String, Map<String, dynamic>>{};
    if (!await itemsDir.exists()) return result;
    await for (final entity in itemsDir.list()) {
      if (entity is! File) continue;
      final match = _itemFilePattern.firstMatch(baseName(entity.path));
      if (match == null || match.group(2) != null) continue;
      try {
        final json = jsonDecode(await entity.readAsString());
        if (json is Map<String, dynamic>) result[match.group(1)!] = json;
      } on FormatException {
        // Повреждённый файл в бэкап не попадает.
      } on FileSystemException {
        // Файл исчез во время чтения (его заменил Syncthing).
      }
    }
    return result;
  }

  /// Читает все записи, разрешает конфликты Syncthing (свежая версия
  /// остаётся в основном файле, лишние файлы удаляются) и перешифровывает
  /// записи, зашифрованные прежним ключом.
  Future<LoadResult> loadAll(Keyring keyring) async {
    final items = <String, VaultItem>{};
    var unreadable = 0;
    var conflictsResolved = 0;
    if (!await itemsDir.exists()) {
      _cache.clear();
      return LoadResult(items: items, unreadable: 0, conflictsResolved: 0);
    }

    final groups = <String, List<(File, bool)>>{};
    final seen = <String>{};
    await for (final entity in itemsDir.list()) {
      if (entity is! File) continue;
      final name = baseName(entity.path);
      if (name.endsWith('.tmp')) {
        await _removeStaleTemp(entity);
        continue;
      }
      final match = _itemFilePattern.firstMatch(name);
      if (match == null) continue;
      seen.add(name);
      groups
          .putIfAbsent(match.group(1)!, () => [])
          .add((entity, match.group(2) != null));
    }
    _cache.removeWhere((name, _) => !seen.contains(name));

    for (final MapEntry(key: id, value: files) in groups.entries) {
      final versions = <_Version>[];
      var foreignKey = false;
      for (final (file, isConflict) in files) {
        try {
          versions.add(await _readVersion(file, isConflict, id, keyring));
        } on UnknownKeyException {
          unreadable++;
          foreignKey = true;
        } on DecryptionException {
          unreadable++;
        } on FormatException {
          unreadable++;
        } on FileSystemException {
          // Файл исчез или занят — будет прочитан при следующем обновлении.
        }
      }
      if (versions.isEmpty) continue;

      final winner = pickWinner(versions.map((v) => v.item));
      final source = versions.firstWhere((v) => identical(v.item, winner));
      items[id] = winner;
      // Одна из версий зашифрована ещё не известным нам ключом (другое
      // устройство сменило ключ, а новый meta-файл не дошёл). Она может
      // оказаться свежее, поэтому ничего не перезаписываем и не удаляем.
      if (foreignKey) continue;
      try {
        if (source.isConflict || source.keyId != keyring.currentId) {
          await writeItem(winner, keyring);
        }
        for (final version in versions.where((v) => v.isConflict)) {
          await version.file.delete();
          _cache.remove(baseName(version.file.path));
          conflictsResolved++;
        }
      } on FileSystemException {
        // Нет прав или файл занят: версия-победитель всё равно показывается,
        // а уборка повторится при следующей загрузке.
      }
    }
    return LoadResult(
      items: items,
      unreadable: unreadable,
      conflictsResolved: conflictsResolved,
    );
  }

  Future<_Version> _readVersion(
    File file,
    bool isConflict,
    String id,
    Keyring keyring,
  ) async {
    final name = baseName(file.path);
    final stat = await file.stat();
    final cached = _cache[name];
    if (cached != null &&
        cached.modified == stat.modified &&
        cached.length == stat.size &&
        keyring[cached.keyId] != null) {
      return _Version(file, isConflict, cached.item, cached.keyId);
    }
    final json = jsonDecode(await file.readAsString());
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Некорректный файл записи');
    }
    final item = await VaultCrypto.decryptItem(json, keyring, expectedId: id);
    final keyId = VaultCrypto.envelopeKeyId(json);
    _cache[name] = _Cached(stat.modified, stat.size, item, keyId);
    return _Version(file, isConflict, item, keyId);
  }

  Future<void> _remember(File file, VaultItem item, String keyId) async {
    try {
      final stat = await file.stat();
      _cache[baseName(file.path)] =
          _Cached(stat.modified, stat.size, item, keyId);
    } on FileSystemException {
      _cache.remove(baseName(file.path));
    }
  }

  Future<void> _removeStaleTemp(File file) async {
    try {
      final age = DateTime.now().difference((await file.stat()).modified);
      if (age > const Duration(hours: 1)) await file.delete();
    } on FileSystemException {
      // Не критично.
    }
  }

  /// Сбрасывает расшифрованные записи из памяти (при блокировке).
  void clearCache() => _cache.clear();

  /// События изменения папки хранилища (без временных файлов).
  Stream<void> watch() {
    final controller = StreamController<void>();
    final subscriptions = <StreamSubscription<FileSystemEvent>>[];
    void listen(Directory dir) {
      try {
        subscriptions.add(
          dir.watch().listen(
            (event) {
              if (!event.path.endsWith('.tmp')) controller.add(null);
            },
            onError: (Object _) {},
          ),
        );
      } on FileSystemException {
        // Наблюдение недоступно — останутся опрос и ручное обновление.
      } on UnsupportedError {
        // То же самое.
      }
    }

    controller.onListen = () {
      listen(root);
      listen(itemsDir);
    };
    controller.onCancel = () async {
      for (final s in subscriptions) {
        await s.cancel();
      }
    };
    return controller.stream;
  }

  /// Дешёвый отпечаток состояния папки для периодического опроса там,
  /// где события файловой системы ненадёжны (общая память Android).
  Future<int> signature() async {
    var hash = 0;
    Future<void> add(File file) async {
      try {
        final stat = await file.stat();
        if (stat.type == FileSystemEntityType.notFound) return;
        hash ^= Object.hash(
          baseName(file.path),
          stat.size,
          stat.modified.millisecondsSinceEpoch,
        );
      } on FileSystemException {
        // Пропускаем.
      }
    }

    await add(metaFile);
    try {
      if (await itemsDir.exists()) {
        await for (final entity in itemsDir.list()) {
          if (entity is File && !entity.path.endsWith('.tmp')) {
            await add(entity);
          }
        }
      }
    } on FileSystemException {
      // Пропускаем.
    }
    return hash;
  }

  static const _encoder = JsonEncoder.withIndent('  ');

  /// Атомарная запись: временный файл в той же папке, затем rename.
  /// Читатель (в том числе Syncthing) видит либо старую, либо новую версию.
  static Future<void> atomicWrite(File target, String content) async {
    await target.parent.create(recursive: true);
    final suffix = bytesToHex(VaultCipher.randomBytes(4));
    final temp = File('${target.path}.$suffix.tmp');
    try {
      await temp.writeAsString(content, flush: true);
      // На Windows rename может временно не пройти, если файл в этот момент
      // читает Syncthing или антивирус, — повторяем несколько раз.
      for (var attempt = 0;; attempt++) {
        try {
          await temp.rename(target.path);
          break;
        } on FileSystemException {
          if (attempt >= 5) rethrow;
          await Future<void>.delayed(Duration(milliseconds: 40 * (attempt + 1)));
        }
      }
    } catch (_) {
      try {
        if (await temp.exists()) await temp.delete();
      } on FileSystemException {
        // Останется временный файл; он будет убран при загрузке.
      }
      rethrow;
    }
  }
}
