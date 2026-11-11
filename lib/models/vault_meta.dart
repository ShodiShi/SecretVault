import '../crypto/cipher.dart';
import '../crypto/kdf.dart';

/// Старый ключ данных, зашифрованный текущим ключом. Нужен, чтобы после
/// полной смены ключа можно было прочитать файлы, которые ещё не
/// перешифрованы (например, не успели синхронизироваться).
class WrappedOldKey {
  WrappedOldKey({required this.keyId, required this.blob});

  final String keyId;
  final EncryptedBlob blob;

  Map<String, dynamic> toJson() => {'keyId': keyId, ...blob.toJson()};

  static WrappedOldKey fromJson(Map<String, dynamic> json) {
    final keyId = json['keyId'];
    if (keyId is! String) throw const FormatException('Некорректный ключ');
    return WrappedOldKey(keyId: keyId, blob: EncryptedBlob.fromJson(json));
  }
}

/// Содержимое vault.meta.json. Секретов в открытом виде здесь нет.
class VaultMeta {
  VaultMeta({
    required this.vaultId,
    required this.kdf,
    required this.keyId,
    required this.wrappedKey,
    this.previousKeys = const [],
    required this.updatedAt,
  });

  static const formatName = 'secretvault';
  static const formatVersion = 1;

  final String vaultId;
  final KdfParams kdf;

  /// Идентификатор текущего ключа данных.
  final String keyId;

  /// Ключ данных, зашифрованный ключом из мастер-пароля. GCM-тег этого
  /// блока одновременно служит проверкой правильности пароля.
  final EncryptedBlob wrappedKey;

  final List<WrappedOldKey> previousKeys;
  final int updatedAt;

  Map<String, dynamic> toJson() => {
        'format': formatName,
        'version': formatVersion,
        'vaultId': vaultId,
        'kdf': kdf.toJson(),
        'keyId': keyId,
        'wrappedKey': wrappedKey.toJson(),
        if (previousKeys.isNotEmpty)
          'previousKeys': [for (final k in previousKeys) k.toJson()],
        'updatedAt': updatedAt,
      };

  static VaultMeta fromJson(Map<String, dynamic> json) {
    if (json['format'] != formatName) {
      throw const FormatException('Это не файл хранилища SecretVault');
    }
    final version = json['version'];
    if (version is! int || version > formatVersion) {
      throw const FormatException(
        'Хранилище создано более новой версией приложения',
      );
    }
    final vaultId = json['vaultId'];
    final keyId = json['keyId'];
    final kdf = json['kdf'];
    final wrapped = json['wrappedKey'];
    if (vaultId is! String ||
        keyId is! String ||
        kdf is! Map<String, dynamic> ||
        wrapped is! Map<String, dynamic>) {
      throw const FormatException('Файл хранилища повреждён');
    }
    final previous = json['previousKeys'];
    return VaultMeta(
      vaultId: vaultId,
      kdf: KdfParams.fromJson(kdf),
      keyId: keyId,
      wrappedKey: EncryptedBlob.fromJson(wrapped),
      previousKeys: previous is List
          ? [
              for (final k in previous.whereType<Map<String, dynamic>>())
                WrappedOldKey.fromJson(k),
            ]
          : const [],
      updatedAt: json['updatedAt'] is int ? json['updatedAt'] as int : 0,
    );
  }
}
