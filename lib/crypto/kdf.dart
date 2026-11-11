import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'cipher.dart';

/// Параметры Argon2id. Хранятся в vault.meta.json в открытом виде.
class KdfParams {
  const KdfParams({
    required this.memoryKiB,
    required this.iterations,
    required this.parallelism,
    required this.salt,
  });

  /// Рекомендуемый профиль: 64 MiB, t=3, p=1.
  static const standardMemoryKiB = 64 * 1024;
  static const standardIterations = 3;

  /// Минимум OWASP для слабых телефонов: 19 MiB, t=2, p=1.
  static const lightMemoryKiB = 19 * 1024;
  static const lightIterations = 2;

  static const saltLength = 16;

  final int memoryKiB;
  final int iterations;
  final int parallelism;
  final Uint8List salt;

  factory KdfParams.standard() => KdfParams(
        memoryKiB: standardMemoryKiB,
        iterations: standardIterations,
        parallelism: 1,
        salt: VaultCipher.randomBytes(saltLength),
      );

  factory KdfParams.light() => KdfParams(
        memoryKiB: lightMemoryKiB,
        iterations: lightIterations,
        parallelism: 1,
        salt: VaultCipher.randomBytes(saltLength),
      );

  /// Те же параметры стоимости, но новая соль (для смены пароля).
  KdfParams withNewSalt() => KdfParams(
        memoryKiB: memoryKiB,
        iterations: iterations,
        parallelism: parallelism,
        salt: VaultCipher.randomBytes(saltLength),
      );

  bool get isLight => memoryKiB < standardMemoryKiB;

  Map<String, dynamic> toJson() => {
        'alg': 'argon2id',
        'memoryKiB': memoryKiB,
        'iterations': iterations,
        'parallelism': parallelism,
        'salt': base64Encode(salt),
      };

  /// Разбирает и проверяет параметры. Границы защищают от подброшенного
  /// meta-файла, который либо ослабляет KDF, либо требует гигабайты памяти.
  static KdfParams fromJson(Map<String, dynamic> json) {
    if (json['alg'] != 'argon2id') {
      throw const FormatException('Неподдерживаемый алгоритм KDF');
    }
    final memory = json['memoryKiB'];
    final iterations = json['iterations'];
    final parallelism = json['parallelism'];
    final salt = json['salt'];
    if (memory is! int ||
        iterations is! int ||
        parallelism is! int ||
        salt is! String) {
      throw const FormatException('Некорректные параметры KDF');
    }
    final saltBytes = base64Decode(salt);
    if (memory < lightMemoryKiB ||
        memory > 1024 * 1024 ||
        iterations < 2 ||
        iterations > 16 ||
        parallelism < 1 ||
        parallelism > 4 ||
        saltBytes.length < 16 ||
        saltBytes.length > 64) {
      throw const FormatException('Параметры KDF вне допустимых границ');
    }
    return KdfParams(
      memoryKiB: memory,
      iterations: iterations,
      parallelism: parallelism,
      salt: saltBytes,
    );
  }
}

/// Выводит 32-байтный ключ из мастер-пароля в отдельном isolate,
/// чтобы интерфейс не замирал на время вычисления Argon2id.
Future<Uint8List> deriveKey(String password, KdfParams params) {
  final memory = params.memoryKiB;
  final iterations = params.iterations;
  final parallelism = params.parallelism;
  final salt = Uint8List.fromList(params.salt);
  return Isolate.run(
    () => deriveKeySync(password, memory, iterations, parallelism, salt),
  );
}

/// То же, но в текущем isolate (используется из тестов и из [deriveKey]).
Future<Uint8List> deriveKeySync(
  String password,
  int memoryKiB,
  int iterations,
  int parallelism,
  Uint8List salt,
) async {
  final algorithm = Argon2id(
    memory: memoryKiB,
    iterations: iterations,
    parallelism: parallelism,
    hashLength: VaultCipher.keyLength,
  );
  final key = await algorithm.deriveKey(
    secretKey: SecretKey(utf8.encode(password)),
    nonce: salt,
  );
  return Uint8List.fromList(await key.extractBytes());
}
