import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:secret_vault/crypto/cipher.dart';
import 'package:secret_vault/crypto/vault_crypto.dart';
import 'package:secret_vault/models/vault_item.dart';
import 'package:secret_vault/models/vault_meta.dart';
import 'package:secret_vault/crypto/kdf.dart';
import 'package:secret_vault/storage/backup.dart';
import 'package:secret_vault/storage/merge.dart';
import 'package:secret_vault/storage/vault_store.dart';

const idA = '11111111-1111-4111-8111-111111111111';
const idB = '22222222-2222-4222-8222-222222222222';

VaultItem note(
  String id,
  String title,
  int updatedAt, {
  bool deleted = false,
}) =>
    VaultItem(
      id: id,
      type: ItemType.note,
      title: title,
      note: 'текст $title',
      createdAt: 1,
      updatedAt: updatedAt,
      deleted: deleted,
    );

Keyring newKeyring([String id = 'k1']) => Keyring(
      currentId: id,
      keys: {id: VaultCipher.randomBytes(32)},
    );

void main() {
  group('Слияние версий', () {
    test('побеждает более свежая версия', () {
      final older = note(idA, 'старая', 100);
      final newer = note(idA, 'новая', 200);
      expect(compareVersions(newer, older), greaterThan(0));
      expect(compareVersions(older, newer), lessThan(0));
      expect(pickWinner([older, newer]).title, 'новая');
      expect(pickWinner([newer, older]).title, 'новая');
    });

    test('при равном времени удаление сильнее правки', () {
      final edit = note(idA, 'правка', 100);
      final stone = note(idA, '', 100, deleted: true);
      expect(pickWinner([edit, stone]).deleted, isTrue);
      expect(pickWinner([stone, edit]).deleted, isTrue);
    });

    test('при полном равенстве времени выбор детерминирован', () {
      final x = note(idA, 'вариант X', 100);
      final y = note(idA, 'вариант Y', 100);
      expect(pickWinner([x, y]).title, pickWinner([y, x]).title);
      expect(compareVersions(x, x), 0);
    });

    test('свежая правка отменяет более старое удаление', () {
      final stone = note(idA, '', 100, deleted: true);
      final edit = note(idA, 'восстановлено', 200);
      expect(pickWinner([stone, edit]).deleted, isFalse);
    });

    test('mergeItems добавляет новые и заменяет устаревшие записи', () {
      final local = {
        idA: note(idA, 'локальная A', 100),
        idB: note(idB, 'локальная B', 300),
      };
      final result = mergeItems(local, [
        note(idA, 'входящая A', 200),
        note(idB, 'входящая B', 250),
        note('33333333-3333-4333-8333-333333333333', 'новая C', 50),
      ]);
      expect(result.items[idA]!.title, 'входящая A');
      expect(result.items[idB]!.title, 'локальная B');
      expect(result.items.length, 3);
      expect(result.changedIds, {idA, '33333333-3333-4333-8333-333333333333'});
      // Исходная карта не изменилась.
      expect(local[idA]!.title, 'локальная A');
    });

    test('слияние коммутативно: порядок устройств не важен', () {
      final device1 = [note(idA, 'с телефона', 500), note(idB, 'b1', 100)];
      final device2 = [note(idA, 'с ноутбука', 400), note(idB, 'b2', 900)];
      final r1 = mergeItems({for (final i in device1) i.id: i}, device2).items;
      final r2 = mergeItems({for (final i in device2) i.id: i}, device1).items;
      expect(
        r1.map((k, v) => MapEntry(k, v.toJson())),
        r2.map((k, v) => MapEntry(k, v.toJson())),
      );
      expect(r1[idA]!.title, 'с телефона');
      expect(r1[idB]!.title, 'b2');
    });

    test('nextUpdatedAt всегда больше предыдущего значения', () {
      expect(nextUpdatedAt(null, now: 1000), 1000);
      expect(nextUpdatedAt(500, now: 1000), 1000);
      // Часы устройства отстают: время всё равно растёт.
      expect(nextUpdatedAt(2000, now: 1000), 2001);
      expect(nextUpdatedAt(1000, now: 1000), 1001);
    });
  });

  group('Файловое хранилище', () {
    late Directory dir;
    late VaultStore store;
    late Keyring keyring;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('secretvault_test_');
      store = VaultStore(dir.path);
      keyring = newKeyring();
      await store.itemsDir.create(recursive: true);
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<File> writeConflict(VaultItem item, String suffix,
        [Keyring? ring]) async {
      final envelope = await VaultCrypto.encryptItem(item, ring ?? keyring);
      final file = File(
        joinPath(
          store.itemsDir.path,
          '${item.id}.sync-conflict-$suffix.json',
        ),
      );
      await file.writeAsString(jsonEncode(envelope));
      return file;
    }

    Future<List<String>> fileNames() async => [
          await for (final e in store.itemsDir.list()) baseName(e.path),
        ]..sort();

    test('запись и чтение', () async {
      await store.writeItem(note(idA, 'A', 100), keyring);
      await store.writeItem(note(idB, 'B', 200), keyring);
      final result = await store.loadAll(keyring);
      expect(result.items.keys.toSet(), {idA, idB});
      expect(result.items[idA]!.title, 'A');
      expect(result.unreadable, 0);
      expect(result.conflictsResolved, 0);
    });

    test('файл на диске не содержит открытого текста', () async {
      await store.writeItem(note(idA, 'СекретноеНазвание', 100), keyring);
      final raw = await store.itemFile(idA).readAsString();
      expect(raw.contains('СекретноеНазвание'), isFalse);
      expect(raw.contains(idA), isTrue);
    });

    test('атомарная запись не оставляет временных файлов', () async {
      for (var i = 0; i < 20; i++) {
        await store.writeItem(note(idA, 'версия $i', 100 + i), keyring);
      }
      expect(await fileNames(), ['$idA.json']);
      final result = await store.loadAll(keyring);
      expect(result.items[idA]!.title, 'версия 19');
    });

    test('конфликтный файл свежее: его версия остаётся, файл удаляется',
        () async {
      await store.writeItem(note(idA, 'основная', 100), keyring);
      await writeConflict(note(idA, 'из конфликта', 200), '20260101-120000-ABCDEFG');

      final result = await store.loadAll(keyring);
      expect(result.items[idA]!.title, 'из конфликта');
      expect(result.conflictsResolved, 1);
      expect(await fileNames(), ['$idA.json']);

      // Победитель записан в основной файл и читается с нуля.
      final fresh = await VaultStore(dir.path).loadAll(keyring);
      expect(fresh.items[idA]!.title, 'из конфликта');
      expect(fresh.conflictsResolved, 0);
    });

    test('конфликтный файл старее: основная версия остаётся', () async {
      await store.writeItem(note(idA, 'основная', 300), keyring);
      await writeConflict(note(idA, 'из конфликта', 200), '20260101-120000-ABCDEFG');

      final result = await store.loadAll(keyring);
      expect(result.items[idA]!.title, 'основная');
      expect(result.conflictsResolved, 1);
      expect(await fileNames(), ['$idA.json']);
    });

    test('несколько конфликтных файлов сводятся к одной версии', () async {
      await store.writeItem(note(idA, 'v1', 100), keyring);
      await writeConflict(note(idA, 'v3', 300), '20260101-120000-AAAAAAA');
      await writeConflict(note(idA, 'v2', 200), '20260102-120000-BBBBBBB');

      final result = await store.loadAll(keyring);
      expect(result.items[idA]!.title, 'v3');
      expect(result.conflictsResolved, 2);
      expect(await fileNames(), ['$idA.json']);
    });

    test('удаление в конфликтном файле побеждает более старую правку',
        () async {
      await store.writeItem(note(idA, 'правка', 100), keyring);
      await writeConflict(
        note(idA, '', 200, deleted: true),
        '20260101-120000-ABCDEFG',
      );
      final result = await store.loadAll(keyring);
      expect(result.items[idA]!.deleted, isTrue);
      expect(await fileNames(), ['$idA.json']);
    });

    test('остался только конфликтный файл: он становится основным', () async {
      await writeConflict(note(idA, 'сирота', 100), '20260101-120000-ABCDEFG');
      final result = await store.loadAll(keyring);
      expect(result.items[idA]!.title, 'сирота');
      expect(await fileNames(), ['$idA.json']);
    });

    test('повреждённый и посторонние файлы не ломают загрузку', () async {
      await store.writeItem(note(idA, 'A', 100), keyring);
      await store.itemFile(idB).writeAsString('{ это не json');
      await File(joinPath(store.itemsDir.path, 'readme.txt'))
          .writeAsString('посторонний файл');

      final result = await store.loadAll(keyring);
      expect(result.items.keys, [idA]);
      expect(result.unreadable, 1);
      // Нечитаемый файл не удаляется.
      expect(await store.itemFile(idB).exists(), isTrue);
    });

    test('файл с чужим ключом не удаляется и не перезаписывается', () async {
      final foreign = newKeyring('k-other');
      await store.writeItem(note(idA, 'новый ключ', 500), foreign);
      await writeConflict(note(idA, 'старая', 100), '20260101-120000-ABCDEFG');
      final before = await store.itemFile(idA).readAsString();

      final result = await VaultStore(dir.path).loadAll(keyring);
      expect(result.unreadable, 1);
      expect(result.items[idA]!.title, 'старая');
      expect(await store.itemFile(idA).readAsString(), before);
      expect((await fileNames()).length, 2);
    });

    test('записи со старым ключом перешифровываются текущим', () async {
      await store.writeItem(note(idA, 'A', 100), keyring);
      final rotated = Keyring(
        currentId: 'k2',
        keys: {
          'k2': VaultCipher.randomBytes(32),
          'k1': Uint8List.fromList(keyring.current),
        },
      );
      final result = await VaultStore(dir.path).loadAll(rotated);
      expect(result.items[idA]!.title, 'A');

      final envelope = jsonDecode(await store.itemFile(idA).readAsString())
          as Map<String, dynamic>;
      expect(envelope['kid'], 'k2');
      // Только новым ключом файл теперь и читается.
      final onlyNew = Keyring(
        currentId: 'k2',
        keys: {'k2': Uint8List.fromList(rotated.current)},
      );
      final again = await VaultStore(dir.path).loadAll(onlyNew);
      expect(again.items[idA]!.title, 'A');
      expect(again.unreadable, 0);
    });

    test('отпечаток папки меняется при изменении файлов', () async {
      final empty = await store.signature();
      await store.writeItem(note(idA, 'A', 100), keyring);
      final one = await store.signature();
      expect(one, isNot(empty));
      expect(await store.signature(), one);
      await store.writeItem(note(idB, 'B', 100), keyring);
      expect(await store.signature(), isNot(one));
    });

    test('резервная копия: экспорт и восстановление в пустую папку', () async {
      final (meta, ring) = await VaultCrypto.create('мастер', KdfParams.light());
      await store.writeMeta(meta);
      await store.writeItem(note(idA, 'A', 100), ring);
      await store.writeItem(note(idB, '', 200, deleted: true), ring);

      final backup = await BackupFile.fromStore(store, meta);
      final encoded = backup.encode();
      expect(encoded.contains('текст A'), isFalse);

      final target = await Directory.systemTemp.createTemp('secretvault_rst_');
      addTearDown(() => target.delete(recursive: true));
      final restoredStore = VaultStore(target.path);
      await BackupFile.decode(encoded).restoreInto(restoredStore);

      final restoredMeta = await restoredStore.readMeta();
      expect(restoredMeta, isA<VaultMeta>());
      final unlocked = await VaultCrypto.unlock(restoredMeta!, 'мастер');
      final result = await restoredStore.loadAll(unlocked);
      expect(result.items[idA]!.title, 'A');
      expect(result.items[idB]!.deleted, isTrue);
    });

    test('посторонний файл не принимается за резервную копию', () {
      expect(() => BackupFile.decode('привет'), throwsFormatException);
      expect(() => BackupFile.decode('{"format":"other"}'), throwsFormatException);
    });
  });
}
