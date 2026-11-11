import 'dart:convert';

import '../models/vault_meta.dart';
import 'vault_store.dart';

/// Резервная копия — один JSON-файл: метаданные хранилища и все записи
/// в том же зашифрованном виде, в каком они лежат на диске. Открытых
/// данных в файле нет; для чтения нужен мастер-пароль, действовавший
/// на момент создания копии.
class BackupFile {
  BackupFile({
    required this.meta,
    required this.envelopes,
    required this.createdAt,
  });

  static const formatName = 'secretvault-backup';
  static const formatVersion = 1;
  static const fileExtension = 'svbackup';

  final VaultMeta meta;
  final Map<String, Map<String, dynamic>> envelopes;
  final int createdAt;

  String encode() => jsonEncode({
        'format': formatName,
        'version': formatVersion,
        'createdAt': createdAt,
        'meta': meta.toJson(),
        'items': envelopes,
      });

  static BackupFile decode(String content) {
    final Object? json;
    try {
      json = jsonDecode(content);
    } on FormatException {
      throw const FormatException('Файл не является резервной копией');
    }
    if (json is! Map<String, dynamic> || json['format'] != formatName) {
      throw const FormatException('Файл не является резервной копией');
    }
    final version = json['version'];
    if (version is! int || version > formatVersion) {
      throw const FormatException(
        'Копия создана более новой версией приложения',
      );
    }
    final meta = json['meta'];
    final items = json['items'];
    if (meta is! Map<String, dynamic> || items is! Map<String, dynamic>) {
      throw const FormatException('Резервная копия повреждена');
    }
    return BackupFile(
      meta: VaultMeta.fromJson(meta),
      envelopes: {
        for (final entry in items.entries)
          if (entry.value is Map<String, dynamic>)
            entry.key: entry.value as Map<String, dynamic>,
      },
      createdAt: json['createdAt'] is int ? json['createdAt'] as int : 0,
    );
  }

  /// Собирает копию из текущего содержимого папки хранилища.
  static Future<BackupFile> fromStore(VaultStore store, VaultMeta meta) async {
    return BackupFile(
      meta: meta,
      envelopes: await store.readEnvelopes(),
      createdAt: DateTime.now().toUtc().millisecondsSinceEpoch,
    );
  }

  /// Разворачивает копию в пустую папку (восстановление на новом устройстве).
  Future<void> restoreInto(VaultStore store) async {
    for (final entry in envelopes.entries) {
      await store.writeEnvelope(entry.key, entry.value);
    }
    // Метаданные пишем последними: пока их нет, папка не считается хранилищем.
    await store.writeMeta(meta);
  }

  static String suggestedFileName([DateTime? now]) {
    final t = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'secretvault-${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}.$fileExtension';
  }
}
