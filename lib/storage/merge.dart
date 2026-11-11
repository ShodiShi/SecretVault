import 'dart:convert';

import '../models/vault_item.dart';

/// Сравнивает две версии одной записи. Результат > 0 — побеждает [a],
/// < 0 — побеждает [b], 0 — версии идентичны.
///
/// Правило: выигрывает более свежий `updatedAt`. При равенстве времени
/// удаление сильнее правки, а дальше сравнивается содержимое — чтобы все
/// устройства независимо друг от друга выбрали одну и ту же версию.
int compareVersions(VaultItem a, VaultItem b) {
  if (a.updatedAt != b.updatedAt) return a.updatedAt.compareTo(b.updatedAt);
  if (a.deleted != b.deleted) return a.deleted ? 1 : -1;
  return jsonEncode(a.toJson()).compareTo(jsonEncode(b.toJson()));
}

/// Выбирает победителя из нескольких версий одной записи.
VaultItem pickWinner(Iterable<VaultItem> versions) =>
    versions.reduce((a, b) => compareVersions(a, b) >= 0 ? a : b);

class MergeResult {
  MergeResult(this.items, this.changedIds);

  /// Итоговое состояние: id → запись.
  final Map<String, VaultItem> items;

  /// Записи, которые появились или были заменены входящей версией.
  final Set<String> changedIds;
}

/// Сливает входящие записи в локальные по правилу «свежая версия побеждает».
MergeResult mergeItems(
  Map<String, VaultItem> local,
  Iterable<VaultItem> incoming,
) {
  final result = Map<String, VaultItem>.of(local);
  final changed = <String>{};
  for (final item in incoming) {
    final existing = result[item.id];
    if (existing == null || compareVersions(item, existing) > 0) {
      result[item.id] = item;
      changed.add(item.id);
    }
  }
  return MergeResult(result, changed);
}

/// Время для новой версии записи: текущее, но строго больше предыдущего —
/// правка не должна проиграть самой себе, если часы устройства отстают.
int nextUpdatedAt(int? previous, {int? now}) {
  final current = now ?? DateTime.now().toUtc().millisecondsSinceEpoch;
  if (previous == null || current > previous) return current;
  return previous + 1;
}
