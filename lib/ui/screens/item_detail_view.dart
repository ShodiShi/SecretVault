import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/vault_item.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'item_edit_screen.dart';

/// Подпись срока задачи: «Сегодня», «Завтра», «Просрочено…» или дата.
String dueLabel(DateTime due, {DateTime? now}) {
  final today = DateUtils.dateOnly(now ?? DateTime.now());
  final days = DateUtils.dateOnly(due).difference(today).inDays;
  if (days == 0) return 'Сегодня';
  if (days == 1) return 'Завтра';
  if (days == -1) return 'Вчера';
  if (days < 0) return 'Просрочено на ${-days} дн.';
  return DateFormat(due.year == today.year ? 'd MMMM' : 'd MMMM y', 'ru')
      .format(due);
}

bool isOverdue(VaultItem item, {DateTime? now}) {
  final due = item.dueDate;
  if (due == null || item.done) return false;
  return DateUtils.dateOnly(due)
      .isBefore(DateUtils.dateOnly(now ?? DateTime.now()));
}

/// Просмотр записи. [embedded] — правая панель двухпанельного режима,
/// иначе отдельная страница.
class ItemDetailView extends StatelessWidget {
  const ItemDetailView({
    super.key,
    required this.itemId,
    this.embedded = false,
    this.onClosed,
  });

  final String itemId;
  final bool embedded;

  /// Вызывается после удаления записи (в двухпанельном режиме).
  final VoidCallback? onClosed;

  Future<void> _delete(BuildContext context, VaultItem item) async {
    final controller = VaultScope.read(context);
    final navigator = Navigator.of(context);
    final ok = await confirmDialog(
      context,
      title: 'Удалить запись?',
      message: '«${item.title}» будет удалена на всех устройствах после '
          'синхронизации. Отменить удаление нельзя.',
      confirmLabel: 'Удалить',
      destructive: true,
    );
    if (!ok) return;
    await controller.delete(item.id);
    if (embedded) {
      onClosed?.call();
    } else {
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = VaultScope.of(context).itemById(itemId);
    if (item == null) {
      final placeholder = Center(
        child: Text(
          'Запись удалена',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
      return embedded
          ? placeholder
          : Scaffold(appBar: AppBar(), body: placeholder);
    }

    final actions = [
      IconButton(
        tooltip: 'Изменить',
        icon: const Icon(Icons.edit_rounded),
        onPressed: () => openEditor(context, item, isNew: false),
      ),
      IconButton(
        tooltip: 'Удалить',
        icon: const Icon(Icons.delete_outline_rounded),
        onPressed: () => _delete(context, item),
      ),
      const SizedBox(width: 8),
    ];
    final body = _DetailBody(key: ValueKey(item.id), item: item);

    if (embedded) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 8, 0),
            child: Row(
              children: [
                Text(
                  typeLabel(item.type),
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: AppColors.forType(item.type),
                      ),
                ),
                const Spacer(),
                ...actions,
              ],
            ),
          ),
          Expanded(child: body),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(typeLabel(item.type)), actions: actions),
      body: body,
    );
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({super.key, required this.item});

  final VaultItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final updated = DateTime.fromMillisecondsSinceEpoch(item.updatedAt);

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TypeAvatar(type: item.type, size: 56),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        item.title,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          decoration: item.type == ItemType.task && item.done
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Изменено ${DateFormat('d MMMM y, HH:mm', 'ru').format(updated)}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (item.tags.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final tag in item.tags)
                    Chip(
                      label: Text(tag),
                      avatar: const Icon(Icons.sell_outlined, size: 14),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            ...switch (item.type) {
              ItemType.password => _password(context),
              ItemType.server => _server(context),
              ItemType.note => _note(context),
              ItemType.task => _task(context),
            },
          ],
        ),
      ),
    );
  }

  List<Widget> _password(BuildContext context) => [
        if (item.username.isNotEmpty)
          _Field(label: 'Логин', value: item.username, sensitive: false),
        if (item.password.isNotEmpty)
          _Field(label: 'Пароль', value: item.password, secret: true),
        if (item.url.isNotEmpty)
          _Field(label: 'URL', value: item.url, sensitive: false),
        if (item.note.isNotEmpty)
          _Field(label: 'Заметка', value: item.note, multiline: true),
      ];

  List<Widget> _server(BuildContext context) {
    final ssh = item.sshCommand;
    return [
      _Field(
        label: '${item.protocol} · адрес',
        value: item.endpoint,
        mono: true,
        sensitive: false,
      ),
      if (item.username.isNotEmpty)
        _Field(label: 'Логин', value: item.username, sensitive: false),
      if (item.password.isNotEmpty)
        _Field(label: 'Пароль', value: item.password, secret: true),
      if (ssh != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: FilledButton.tonalIcon(
            onPressed: () =>
                copyValue(context, ssh, 'Команда SSH', sensitive: false),
            icon: const Icon(Icons.terminal_rounded),
            label: Text(
              ssh,
              style: monoStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      if (item.note.isNotEmpty)
        _Field(label: 'Заметка', value: item.note, multiline: true),
    ];
  }

  List<Widget> _note(BuildContext context) => [
        _Field(
          label: 'Текст',
          value: item.note,
          secret: true,
          multiline: true,
          mono: true,
        ),
      ];

  List<Widget> _task(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final due = item.dueDate;
    final overdue = isOverdue(item);
    return [
      Card(
        child: SwitchListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(item.done ? 'Выполнено' : 'Не выполнено'),
          secondary: Icon(
            item.done
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded,
            color: item.done ? AppColors.forType(ItemType.task) : null,
          ),
          value: item.done,
          onChanged: (v) =>
              VaultScope.read(context).save(item.copyWith(done: v)),
        ),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          Chip(
            avatar: Icon(
              Icons.flag_rounded,
              size: 16,
              color: AppColors.forPriority(item.priority),
            ),
            label: Text('Приоритет: ${priorityLabel(item.priority).toLowerCase()}'),
          ),
          Chip(
            avatar: Icon(
              Icons.event_rounded,
              size: 16,
              color: overdue ? scheme.error : null,
            ),
            label: Text(
              due == null
                  ? 'Без срока'
                  : '${dueLabel(due)} · ${DateFormat('d MMM y', 'ru').format(due)}',
              style: overdue ? TextStyle(color: scheme.error) : null,
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      if (item.note.isNotEmpty)
        _Field(
          label: 'Описание',
          value: item.note,
          multiline: true,
          sensitive: false,
        ),
    ];
  }
}

/// Поле записи: подпись, значение, кнопки «показать» и «копировать».
class _Field extends StatefulWidget {
  const _Field({
    required this.label,
    required this.value,
    this.secret = false,
    this.multiline = false,
    this.mono = false,
    this.sensitive = true,
  });

  final String label;
  final String value;

  /// Скрывать значение точками, пока пользователь не попросит показать.
  final bool secret;
  final bool multiline;
  final bool mono;

  /// Стирать значение из буфера обмена через 30 секунд после копирования.
  final bool sensitive;

  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hidden = widget.secret && !_revealed;
    final style = (widget.mono || widget.secret
            ? monoStyle.merge(theme.textTheme.bodyLarge)
            : theme.textTheme.bodyLarge)
        ?.copyWith(height: 1.4);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => copyValue(
            context,
            widget.value,
            widget.label,
            sensitive: widget.sensitive,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
            child: Row(
              crossAxisAlignment: widget.multiline && !hidden
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.label,
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 4),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        layoutBuilder: (current, previous) => Stack(
                          alignment: Alignment.topLeft,
                          children: [...previous, ?current],
                        ),
                        child: hidden
                            ? Text(
                                '••••••••••••',
                                key: const ValueKey('hidden'),
                                style: style?.copyWith(letterSpacing: 2),
                              )
                            : SelectableText(
                                widget.value,
                                key: const ValueKey('shown'),
                                style: style,
                              ),
                      ),
                    ],
                  ),
                ),
                if (widget.secret)
                  IconButton(
                    tooltip: _revealed ? 'Скрыть' : 'Показать',
                    icon: Icon(
                      _revealed
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                    ),
                    onPressed: () => setState(() => _revealed = !_revealed),
                  ),
                IconButton(
                  tooltip: 'Копировать',
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: () => copyValue(
                    context,
                    widget.value,
                    widget.label,
                    sensitive: widget.sensitive,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
