import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secret_vault/crypto/cipher.dart';
import 'package:secret_vault/crypto/kdf.dart';
import 'package:secret_vault/crypto/password_tools.dart';
import 'package:secret_vault/crypto/vault_crypto.dart';
import 'package:secret_vault/models/vault_item.dart';
import 'package:secret_vault/models/vault_meta.dart';

VaultItem sampleItem({String? id, String password = 's3cr3t-Пароль'}) =>
    VaultItem(
      id: id ?? newUuid(),
      type: ItemType.password,
      title: 'Почта',
      username: 'admin@example.com',
      password: password,
      tags: const ['работа'],
      createdAt: 1000,
      updatedAt: 2000,
    );

void main() {
  group('AES-256-GCM', () {
    final key = VaultCipher.randomBytes(32);

    test('шифрование и расшифровка возвращают исходные данные', () async {
      final data = utf8.encode('секретные данные 🔐');
      final blob = await VaultCipher.encrypt(key, data, aad: [1, 2, 3]);
      expect(blob.nonce.length, 12);
      expect(blob.cipherText.length, data.length + 16);
      expect(await VaultCipher.decrypt(key, blob, aad: [1, 2, 3]), data);
    });

    test('nonce уникален для каждого шифрования', () async {
      final nonces = <String>{};
      for (var i = 0; i < 200; i++) {
        final blob = await VaultCipher.encrypt(key, [1, 2, 3]);
        nonces.add(base64Encode(blob.nonce));
      }
      expect(nonces.length, 200);
    });

    test('одинаковый текст даёт разный шифртекст', () async {
      final a = await VaultCipher.encrypt(key, utf8.encode('same'));
      final b = await VaultCipher.encrypt(key, utf8.encode('same'));
      expect(a.cipherText, isNot(equals(b.cipherText)));
    });

    test('изменение шифртекста, nonce или AAD обнаруживается', () async {
      final blob = await VaultCipher.encrypt(key, utf8.encode('data'), aad: [7]);

      final badCt = Uint8List.fromList(blob.cipherText)..[0] ^= 1;
      await expectLater(
        VaultCipher.decrypt(
          key,
          EncryptedBlob(nonce: blob.nonce, cipherText: badCt),
          aad: [7],
        ),
        throwsA(isA<DecryptionException>()),
      );

      final badTag = Uint8List.fromList(blob.cipherText)..last ^= 1;
      await expectLater(
        VaultCipher.decrypt(
          key,
          EncryptedBlob(nonce: blob.nonce, cipherText: badTag),
          aad: [7],
        ),
        throwsA(isA<DecryptionException>()),
      );

      final badNonce = Uint8List.fromList(blob.nonce)..[0] ^= 1;
      await expectLater(
        VaultCipher.decrypt(
          key,
          EncryptedBlob(nonce: badNonce, cipherText: blob.cipherText),
          aad: [7],
        ),
        throwsA(isA<DecryptionException>()),
      );

      await expectLater(
        VaultCipher.decrypt(key, blob, aad: [8]),
        throwsA(isA<DecryptionException>()),
      );
    });

    test('чужой ключ не подходит', () async {
      final blob = await VaultCipher.encrypt(key, utf8.encode('data'));
      await expectLater(
        VaultCipher.decrypt(VaultCipher.randomBytes(32), blob),
        throwsA(isA<DecryptionException>()),
      );
    });

    test('ключ неправильной длины отвергается', () {
      expect(
        () => VaultCipher.encrypt(Uint8List(16), [1]),
        throwsArgumentError,
      );
    });

    test('блок сериализуется в JSON и обратно', () async {
      final blob = await VaultCipher.encrypt(key, utf8.encode('json'));
      final restored = EncryptedBlob.fromJson(
        jsonDecode(jsonEncode(blob.toJson())) as Map<String, dynamic>,
      );
      expect(await VaultCipher.decrypt(key, restored), utf8.encode('json'));
    });

    test('newUuid выдаёт корректный UUID v4', () {
      final pattern = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      final ids = {for (var i = 0; i < 100; i++) newUuid()};
      expect(ids.length, 100);
      expect(ids.every(pattern.hasMatch), isTrue);
    });
  });

  group('Argon2id', () {
    final salt = Uint8List.fromList(List.generate(16, (i) => i));

    test('вывод ключа детерминирован и зависит от пароля и соли', () async {
      final a = await deriveKeySync('пароль', 19456, 2, 1, salt);
      final b = await deriveKeySync('пароль', 19456, 2, 1, salt);
      final otherPassword = await deriveKeySync('пароль2', 19456, 2, 1, salt);
      final otherSalt = await deriveKeySync(
        'пароль',
        19456,
        2,
        1,
        Uint8List.fromList(List.generate(16, (i) => i + 1)),
      );
      expect(a.length, 32);
      expect(a, b);
      expect(a, isNot(equals(otherPassword)));
      expect(a, isNot(equals(otherSalt)));
    });

    test('вычисление в isolate даёт тот же ключ', () async {
      final params = KdfParams(
        memoryKiB: 19456,
        iterations: 2,
        parallelism: 1,
        salt: salt,
      );
      expect(
        await deriveKey('пароль', params),
        await deriveKeySync('пароль', 19456, 2, 1, salt),
      );
    });

    test('профили соответствуют требованиям', () {
      final standard = KdfParams.standard();
      expect(standard.memoryKiB, 64 * 1024);
      expect(standard.iterations, 3);
      expect(standard.parallelism, 1);
      expect(standard.salt.length, 16);
      final light = KdfParams.light();
      expect(light.memoryKiB, 19 * 1024);
      expect(light.iterations, 2);
      expect(standard.salt, isNot(equals(KdfParams.standard().salt)));
    });

    test('параметры слабее минимума отвергаются', () {
      final json = KdfParams.light().toJson();
      expect(KdfParams.fromJson(json).memoryKiB, 19456);
      expect(
        () => KdfParams.fromJson({...json, 'memoryKiB': 1024}),
        throwsFormatException,
      );
      expect(
        () => KdfParams.fromJson({...json, 'iterations': 1}),
        throwsFormatException,
      );
      expect(
        () => KdfParams.fromJson({...json, 'memoryKiB': 8 * 1024 * 1024}),
        throwsFormatException,
      );
      expect(
        () => KdfParams.fromJson({...json, 'alg': 'pbkdf2'}),
        throwsFormatException,
      );
    });
  });

  group('Хранилище', () {
    late VaultMeta meta;
    late Keyring keyring;

    setUpAll(() async {
      (meta, keyring) = await VaultCrypto.create('мастер', KdfParams.light());
    });

    test('разблокировка верным паролем возвращает тот же ключ', () async {
      final restored = VaultMeta.fromJson(
        jsonDecode(jsonEncode(meta.toJson())) as Map<String, dynamic>,
      );
      final unlocked = await VaultCrypto.unlock(restored, 'мастер');
      expect(unlocked.currentId, keyring.currentId);
      expect(unlocked.current, keyring.current);
    });

    test('неверный пароль отвергается', () async {
      await expectLater(
        VaultCrypto.unlock(meta, 'не тот'),
        throwsA(isA<WrongPasswordException>()),
      );
    });

    test('meta-файл не содержит ключа в открытом виде', () {
      final text = jsonEncode(meta.toJson());
      expect(text.contains(base64Encode(keyring.current)), isFalse);
      expect(text.contains('мастер'), isFalse);
    });

    test('запись шифруется и расшифровывается', () async {
      final item = sampleItem();
      final envelope = await VaultCrypto.encryptItem(item, keyring);
      final text = jsonEncode(envelope);
      expect(text.contains('Почта'), isFalse);
      expect(text.contains('admin@example.com'), isFalse);
      expect(envelope['id'], item.id);
      final back = await VaultCrypto.decryptItem(envelope, keyring);
      expect(back.toJson(), item.toJson());
    });

    test('подмена файла другой записью обнаруживается', () async {
      final a = sampleItem();
      final b = sampleItem();
      final envelopeA = await VaultCrypto.encryptItem(a, keyring);
      // Файл записи A положили под именем записи B.
      await expectLater(
        VaultCrypto.decryptItem(envelopeA, keyring, expectedId: b.id),
        throwsFormatException,
      );
      // То же, но злоумышленник поправил id в открытой части файла.
      await expectLater(
        VaultCrypto.decryptItem({...envelopeA, 'id': b.id}, keyring),
        throwsA(isA<DecryptionException>()),
      );
    });

    test('неизвестный ключ даёт UnknownKeyException', () async {
      final envelope = await VaultCrypto.encryptItem(sampleItem(), keyring);
      await expectLater(
        VaultCrypto.decryptItem({...envelope, 'kid': 'ffff'}, keyring),
        throwsA(isA<UnknownKeyException>()),
      );
    });

    test('смена пароля не требует перешифровки записей', () async {
      final envelope = await VaultCrypto.encryptItem(sampleItem(), keyring);
      final newMeta = await VaultCrypto.changePassword(meta, keyring, 'новый');
      expect(newMeta.keyId, meta.keyId);
      expect(newMeta.kdf.salt, isNot(equals(meta.kdf.salt)));

      await expectLater(
        VaultCrypto.unlock(newMeta, 'мастер'),
        throwsA(isA<WrongPasswordException>()),
      );
      final unlocked = await VaultCrypto.unlock(newMeta, 'новый');
      final back = await VaultCrypto.decryptItem(envelope, unlocked);
      expect(back.password, 's3cr3t-Пароль');
    });

    test('смена ключа: старые файлы читаются, новые шифруются новым ключом',
        () async {
      final oldEnvelope = await VaultCrypto.encryptItem(sampleItem(), keyring);
      final (newMeta, newRing) =
          await VaultCrypto.rotateKey(meta, keyring, 'новый');
      expect(newMeta.keyId, isNot(meta.keyId));
      expect(newRing.current, isNot(equals(keyring.current)));

      // Новое устройство знает только новый пароль и новый meta-файл.
      final restored = VaultMeta.fromJson(
        jsonDecode(jsonEncode(newMeta.toJson())) as Map<String, dynamic>,
      );
      final unlocked = await VaultCrypto.unlock(restored, 'новый');
      final back = await VaultCrypto.decryptItem(oldEnvelope, unlocked);
      expect(back.title, 'Почта');

      final newEnvelope = await VaultCrypto.encryptItem(back, unlocked);
      expect(newEnvelope['kid'], newMeta.keyId);
      // Старая связка новый файл прочитать не может.
      await expectLater(
        VaultCrypto.decryptItem(newEnvelope, keyring),
        throwsA(isA<UnknownKeyException>()),
      );
    });

    test('wipe затирает ключи', () async {
      final (_, ring) = await VaultCrypto.create('x', KdfParams.light());
      final bytes = ring.current;
      ring.wipe();
      expect(bytes.every((b) => b == 0), isTrue);
      expect(ring.keyIds, isEmpty);
    });
  });

  group('Модель записи', () {
    test('JSON-представление обратимо для всех типов', () {
      final items = [
        sampleItem(),
        VaultItem(
          id: newUuid(),
          type: ItemType.server,
          title: 'Прод',
          host: '10.0.0.5',
          port: 2222,
          protocol: 'SSH',
          username: 'root',
          password: 'pw',
          note: 'осторожно',
          tags: const ['prod', 'db'],
          createdAt: 1,
          updatedAt: 2,
        ),
        VaultItem(
          id: newUuid(),
          type: ItemType.note,
          title: 'API',
          note: 'token=abc\nline2',
          createdAt: 1,
          updatedAt: 2,
        ),
        VaultItem(
          id: newUuid(),
          type: ItemType.task,
          title: 'Обновить сертификат',
          note: 'до конца месяца',
          dueDate: DateTime(2026, 12, 31),
          priority: TaskPriority.high,
          done: true,
          createdAt: 1,
          updatedAt: 2,
        ),
      ];
      for (final item in items) {
        final back = VaultItem.fromJson(
          jsonDecode(jsonEncode(item.toJson())) as Map<String, dynamic>,
        );
        expect(back.toJson(), item.toJson());
        expect(back.dueDate, item.dueDate);
      }
    });

    test('команда SSH', () {
      VaultItem server({int? port, String user = 'root', String proto = 'SSH'}) =>
          VaultItem(
            id: newUuid(),
            type: ItemType.server,
            title: 's',
            host: 'example.com',
            port: port,
            protocol: proto,
            username: user,
            createdAt: 1,
            updatedAt: 1,
          );
      expect(server(port: 2222).sshCommand, 'ssh root@example.com -p 2222');
      expect(server(port: 22).sshCommand, 'ssh root@example.com');
      expect(server(user: '').sshCommand, 'ssh example.com');
      expect(server(proto: 'RDP').sshCommand, isNull);
    });

    test('tombstone не содержит секретов', () {
      final stone = sampleItem().tombstone(5000);
      expect(stone.deleted, isTrue);
      expect(stone.updatedAt, 5000);
      final text = jsonEncode(stone.toJson());
      expect(text.contains('s3cr3t'), isFalse);
      expect(text.contains('admin@example.com'), isFalse);
    });
  });

  group('Генератор и оценка паролей', () {
    test('длина и классы символов соблюдаются', () {
      for (var i = 0; i < 50; i++) {
        final p = PasswordGenerator.generate(
          const GeneratorOptions(length: 16),
        );
        expect(p.length, 16);
        expect(p, matches(RegExp(r'[a-z]')));
        expect(p, matches(RegExp(r'[A-Z]')));
        expect(p, matches(RegExp(r'[0-9]')));
        expect(p, matches(RegExp(r'[^a-zA-Z0-9]')));
      }
    });

    test('отключённые классы не используются', () {
      for (var i = 0; i < 50; i++) {
        final p = PasswordGenerator.generate(
          const GeneratorOptions(
            length: 24,
            upper: false,
            digits: false,
            symbols: false,
          ),
        );
        expect(p, matches(RegExp(r'^[a-z]{24}$')));
      }
    });

    test('пароли не повторяются', () {
      final set = {
        for (var i = 0; i < 100; i++)
          PasswordGenerator.generate(const GeneratorOptions(), random: Random.secure()),
      };
      expect(set.length, 100);
    });

    test('оценка силы растёт вместе с качеством пароля', () {
      expect(PasswordStrength.estimate('').score, 0);
      expect(PasswordStrength.estimate('qwerty').score, 0);
      expect(PasswordStrength.estimate('aaaaaaaaaaaa').score, lessThan(2));
      expect(PasswordStrength.estimate('Tr7!kq').score, lessThan(3));
      expect(
        PasswordStrength.estimate('k9#Lm2\$vQ8!xR4@zN7&b').score,
        4,
      );
      final generated = PasswordGenerator.generate(const GeneratorOptions());
      expect(PasswordStrength.estimate(generated).score, greaterThanOrEqualTo(3));
    });
  });
}
