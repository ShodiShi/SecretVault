import 'dart:convert';
import 'dart:typed_data';

import '../models/vault_item.dart';
import '../models/vault_meta.dart';
import 'cipher.dart';
import 'kdf.dart';

class WrongPasswordException implements Exception {
  const WrongPasswordException();
  @override
  String toString() => 'Неверный мастер-пароль';
}

/// Файл зашифрован ключом, которого нет в связке (например, другое
/// устройство сменило ключ, а новый vault.meta.json ещё не пришёл).
class UnknownKeyException implements Exception {
  const UnknownKeyException(this.keyId);
  final String keyId;
  @override
  String toString() => 'Неизвестный ключ: $keyId';
}

/// Ключи данных в памяти: текущий и прежние (после смены ключа).
class Keyring {
  Keyring({required this.currentId, required this._keys});

  final String currentId;
  final Map<String, Uint8List> _keys;

  Uint8List get current => _keys[currentId]!;
  Uint8List? operator [](String keyId) => _keys[keyId];
  Iterable<String> get keyIds => _keys.keys;

  /// Затирает ключи в памяти. Dart не гарантирует, что копий не осталось
  /// (сборщик мусора может перемещать объекты), но окно уязвимости сужается.
  void wipe() {
    for (final key in _keys.values) {
      key.fillRange(0, key.length, 0);
    }
    _keys.clear();
  }
}

/// Операции уровня хранилища: создание, разблокировка, смена пароля и
/// ключа, шифрование отдельных записей.
abstract final class VaultCrypto {
  static const envelopeVersion = 1;

  static List<int> _keyAad(String vaultId, String keyId) =>
      utf8.encode('secretvault:key:v1:$vaultId:$keyId');

  static List<int> _oldKeyAad(String vaultId, String keyId) =>
      utf8.encode('secretvault:oldkey:v1:$vaultId:$keyId');

  static List<int> _itemAad(String id, String keyId) =>
      utf8.encode('secretvault:item:v1:$id:$keyId');

  static String _newKeyId() => bytesToHex(VaultCipher.randomBytes(8));

  static int _now() => DateTime.now().toUtc().millisecondsSinceEpoch;

  /// Создаёт новое хранилище: случайный ключ данных, зашифрованный ключом
  /// из мастер-пароля.
  static Future<(VaultMeta, Keyring)> create(
    String password,
    KdfParams kdf,
  ) async {
    final vaultId = newUuid();
    final keyId = _newKeyId();
    final dataKey = VaultCipher.randomBytes(VaultCipher.keyLength);
    final kek = await deriveKey(password, kdf);
    final wrapped = await VaultCipher.encrypt(
      kek,
      dataKey,
      aad: _keyAad(vaultId, keyId),
    );
    kek.fillRange(0, kek.length, 0);
    final meta = VaultMeta(
      vaultId: vaultId,
      kdf: kdf,
      keyId: keyId,
      wrappedKey: wrapped,
      updatedAt: _now(),
    );
    return (meta, Keyring(currentId: keyId, keys: {keyId: dataKey}));
  }

  /// Проверяет пароль и возвращает связку ключей.
  static Future<Keyring> unlock(VaultMeta meta, String password) async {
    final kek = await deriveKey(password, meta.kdf);
    final Uint8List dataKey;
    try {
      dataKey = await VaultCipher.decrypt(
        kek,
        meta.wrappedKey,
        aad: _keyAad(meta.vaultId, meta.keyId),
      );
    } on DecryptionException {
      throw const WrongPasswordException();
    } finally {
      kek.fillRange(0, kek.length, 0);
    }
    final keys = <String, Uint8List>{meta.keyId: dataKey};
    for (final old in meta.previousKeys) {
      try {
        keys[old.keyId] = await VaultCipher.decrypt(
          dataKey,
          old.blob,
          aad: _oldKeyAad(meta.vaultId, old.keyId),
        );
      } on DecryptionException {
        // Повреждённая запись о старом ключе не должна мешать входу.
      }
    }
    return Keyring(currentId: meta.keyId, keys: keys);
  }

  /// Смена мастер-пароля без перешифровки записей: ключ данных остаётся
  /// прежним, меняется только его «обёртка». Затрагивает один файл.
  static Future<VaultMeta> changePassword(
    VaultMeta meta,
    Keyring keyring,
    String newPassword,
  ) async {
    final kdf = meta.kdf.withNewSalt();
    final kek = await deriveKey(newPassword, kdf);
    final wrapped = await VaultCipher.encrypt(
      kek,
      keyring.current,
      aad: _keyAad(meta.vaultId, meta.keyId),
    );
    kek.fillRange(0, kek.length, 0);
    return VaultMeta(
      vaultId: meta.vaultId,
      kdf: kdf,
      keyId: meta.keyId,
      wrappedKey: wrapped,
      previousKeys: meta.previousKeys,
      updatedAt: _now(),
    );
  }

  /// Смена пароля с новым ключом данных. Прежние ключи сохраняются
  /// зашифрованными новым ключом, чтобы ещё не перешифрованные файлы
  /// оставались читаемыми; сами записи перешифровывает хранилище.
  static Future<(VaultMeta, Keyring)> rotateKey(
    VaultMeta meta,
    Keyring keyring,
    String newPassword,
  ) async {
    final kdf = meta.kdf.withNewSalt();
    final keyId = _newKeyId();
    final dataKey = VaultCipher.randomBytes(VaultCipher.keyLength);
    final kek = await deriveKey(newPassword, kdf);
    final wrapped = await VaultCipher.encrypt(
      kek,
      dataKey,
      aad: _keyAad(meta.vaultId, keyId),
    );
    kek.fillRange(0, kek.length, 0);

    final keys = <String, Uint8List>{keyId: dataKey};
    final previous = <WrappedOldKey>[];
    for (final oldId in keyring.keyIds) {
      final oldKey = Uint8List.fromList(keyring[oldId]!);
      keys[oldId] = oldKey;
      previous.add(
        WrappedOldKey(
          keyId: oldId,
          blob: await VaultCipher.encrypt(
            dataKey,
            oldKey,
            aad: _oldKeyAad(meta.vaultId, oldId),
          ),
        ),
      );
    }
    final newMeta = VaultMeta(
      vaultId: meta.vaultId,
      kdf: kdf,
      keyId: keyId,
      wrappedKey: wrapped,
      previousKeys: previous,
      updatedAt: _now(),
    );
    return (newMeta, Keyring(currentId: keyId, keys: keys));
  }

  /// Шифрует запись текущим ключом и возвращает содержимое файла записи.
  static Future<Map<String, dynamic>> encryptItem(
    VaultItem item,
    Keyring keyring,
  ) async {
    final blob = await VaultCipher.encrypt(
      keyring.current,
      utf8.encode(jsonEncode(item.toJson())),
      aad: _itemAad(item.id, keyring.currentId),
    );
    return {
      'v': envelopeVersion,
      'id': item.id,
      'kid': keyring.currentId,
      ...blob.toJson(),
    };
  }

  /// Идентификатор ключа, которым зашифрован файл записи.
  static String envelopeKeyId(Map<String, dynamic> envelope) {
    final kid = envelope['kid'];
    if (kid is! String) throw const FormatException('Некорректный файл записи');
    return kid;
  }

  /// Расшифровывает файл записи. [expectedId] — идентификатор из имени
  /// файла: защищает от подмены одного файла другим.
  static Future<VaultItem> decryptItem(
    Map<String, dynamic> envelope,
    Keyring keyring, {
    String? expectedId,
  }) async {
    final version = envelope['v'];
    final id = envelope['id'];
    if (version is! int || version > envelopeVersion || id is! String) {
      throw const FormatException('Некорректный файл записи');
    }
    if (expectedId != null && id != expectedId) {
      throw const FormatException('Идентификатор записи не совпадает с файлом');
    }
    final kid = envelopeKeyId(envelope);
    final key = keyring[kid];
    if (key == null) throw UnknownKeyException(kid);
    final clear = await VaultCipher.decrypt(
      key,
      EncryptedBlob.fromJson(envelope),
      aad: _itemAad(id, kid),
    );
    final json = jsonDecode(utf8.decode(clear));
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Некорректная запись');
    }
    final item = VaultItem.fromJson(json);
    if (item.id != id) {
      throw const FormatException('Идентификатор записи не совпадает с файлом');
    }
    return item;
  }
}
