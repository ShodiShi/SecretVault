import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Ошибка расшифровки: неверный ключ либо повреждённые/подменённые данные.
class DecryptionException implements Exception {
  const DecryptionException([this.message = 'Не удалось расшифровать данные']);
  final String message;
  @override
  String toString() => 'DecryptionException: $message';
}

/// Результат AES-256-GCM: nonce и шифртекст с приклеенным 16-байтным тегом.
class EncryptedBlob {
  EncryptedBlob({required this.nonce, required this.cipherText});

  final Uint8List nonce;

  /// Шифртекст + GCM-тег (последние 16 байт).
  final Uint8List cipherText;

  Map<String, dynamic> toJson() => {
        'nonce': base64Encode(nonce),
        'ct': base64Encode(cipherText),
      };

  static EncryptedBlob fromJson(Map<String, dynamic> json) {
    final nonce = json['nonce'];
    final ct = json['ct'];
    if (nonce is! String || ct is! String) {
      throw const FormatException('Некорректный зашифрованный блок');
    }
    final blob = EncryptedBlob(
      nonce: base64Decode(nonce),
      cipherText: base64Decode(ct),
    );
    if (blob.nonce.length != VaultCipher.nonceLength ||
        blob.cipherText.length < VaultCipher.tagLength) {
      throw const FormatException('Некорректный зашифрованный блок');
    }
    return blob;
  }
}

/// AES-256-GCM со случайным 96-битным nonce на каждое шифрование.
abstract final class VaultCipher {
  static const keyLength = 32;
  static const nonceLength = 12;
  static const tagLength = 16;

  static final _aes = AesGcm.with256bits();
  static final _random = Random.secure();

  /// Криптостойкие случайные байты.
  static Uint8List randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }

  static Future<EncryptedBlob> encrypt(
    Uint8List key,
    List<int> plaintext, {
    List<int> aad = const [],
  }) async {
    _checkKey(key);
    final nonce = randomBytes(nonceLength);
    final box = await _aes.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: aad,
    );
    final out = Uint8List(box.cipherText.length + tagLength)
      ..setAll(0, box.cipherText)
      ..setAll(box.cipherText.length, box.mac.bytes);
    return EncryptedBlob(nonce: nonce, cipherText: out);
  }

  static Future<Uint8List> decrypt(
    Uint8List key,
    EncryptedBlob blob, {
    List<int> aad = const [],
  }) async {
    _checkKey(key);
    final ct = blob.cipherText;
    if (blob.nonce.length != nonceLength || ct.length < tagLength) {
      throw const DecryptionException();
    }
    final split = ct.length - tagLength;
    try {
      final clear = await _aes.decrypt(
        SecretBox(
          Uint8List.sublistView(ct, 0, split),
          nonce: blob.nonce,
          mac: Mac(Uint8List.sublistView(ct, split)),
        ),
        secretKey: SecretKey(key),
        aad: aad,
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const DecryptionException();
    }
  }

  static void _checkKey(Uint8List key) {
    if (key.length != keyLength) {
      throw ArgumentError('Ключ должен быть длиной $keyLength байт');
    }
  }
}

String bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// UUID v4 из криптостойкого генератора.
String newUuid() {
  final b = VaultCipher.randomBytes(16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = bytesToHex(b);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}
