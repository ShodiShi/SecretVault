import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/vault_item.dart';
import '../../state/vault_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'item_detail_view.dart';
import 'item_edit_screen.dart';
import 'settings_screen.dart';

enum _Section {
  all('Все', Icons.grid_view_rounded, null),
  passwords('Пароли', Icons.key_rounded, ItemType.password),
  servers('Серверы', Icons.dns_rounded, ItemType.server),
  notes('Заметки', Icons.sticky_note_2_rounded, ItemType.note),
  tasks('Задачи', Icons.task_alt_rounded, ItemType.task);

  const _Section(this.label, this.icon, this.type);
  final String label;
  final IconData icon;
  final ItemType? type;
}

enum _SortMode {
  updated('Сначала недавние'),
  title('По названию'),
  created('По дате создания');

  const _SortMode(this.label);
  final String label;
}

enum _TaskFilter {
  active('Активные'),
  today('Сегодня'),
  all('Все'),
  done('Выполненные');

  const _TaskFilter(this.label);
  final String label;
}

/// Главный экран: разделы, поиск, список и (на широком экране) детали.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _appeared = <String>{};

  _Section _section = _Section.all;
  _SortMode _sort = _SortMode.updated;
  _TaskFilter _taskFilter = _TaskFilter.active;
  String? _tag;
  String? _selectedId;
  ModalRoute<Object?>? _route;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Ctrl+F — поиск, Ctrl+N — новая запись. Сравниваем физические клавиши,
  /// чтобы сочетания работали и в русской раскладке.
  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent || !mounted) return false;
    if (!HardwareKeyboard.instance.isControlPressed) return false;
    if (!(_route?.isCurrent ?? true)) return false;
    if (event.physicalKey == PhysicalKeyboardKey.keyF) {
      _searchFocus.requestFocus();
      _search.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _search.text.length,
      );
      return true;
    }
    if (event.physicalKey == PhysicalKeyboardKey.keyN) {
      _create();
      return true;
    }
    return false;
  }

  bool get _wide =>
      MediaQuery.sizeOf(context).width >= wideLayoutBreakpoint;

  void _selectSection(int index) {
    setState(() {
      _section = _Section.values[index];
      _appeared.clear();
    });
  }

  // ---------------------------------------------------------------- данные

  static bool _matches(VaultItem item, String query) {
    bool has(String value) => value.toLowerCase().contains(query);
    return has(item.title) ||
        has(item.username) ||
        has(item.url) ||
        has(item.host) ||
        has(item.note) ||
        item.tags.any(has);
  }

  List<VaultItem> _visibleItems(VaultController controller) {
    final query = _search.text.trim().toLowerCase();
    final today = DateUtils.dateOnly(DateTime.now());
    final tasksOnly = query.isEmpty && _section == _Section.tasks;

    final list = controller.items.where((item) {
      if (_tag != null && !item.tags.contains(_tag)) return false;
      // Поиск всегда глобальный — по всем типам записей.
      if (query.isNotEmpty) return _matches(item, query);
      final type = _section.type;
      if (type != null && item.type != type) return false;
      if (tasksOnly) {
        final due = item.dueDate;
        return switch (_taskFilter) {
          _TaskFilter.active => !item.done,
          _TaskFilter.today => !item.done &&
              due != null &&
              !DateUtils.dateOnly(due).isAfter(today),
          _TaskFilter.all => true,
          _TaskFilter.done => item.done,
        };
      }
      return true;
    }).toList();

    int byUpdated(VaultItem a, VaultItem b) =>
        b.updatedAt.compareTo(a.updatedAt);
    if (tasksOnly) {
      // Невыполненные выше; затем по сроку, приоритету и времени изменения.
      list.sort((a, b) {
        if (a.done != b.done) return a.done ? 1 : -1;
        final ad = a.dueDate, bd = b.dueDate;
        if (ad != null && bd != null && ad != bd) return ad.compareTo(bd);
        if ((ad == null) != (bd == null)) return ad == null ? 1 : -1;
        if (a.priority != b.priority) {
          return b.priority.index.compareTo(a.priority.index);
        }
        return byUpdated(a, b);
      });
    } else {
      list.sort(
        switch (_sort) {
          _SortMode.updated => byUpdated,
          _SortMode.title => (a, b) =>
              a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          _SortMode.created => (a, b) => b.createdAt.compareTo(a.createdAt),
        },
      );
    }
    return list;
  }

  // -------------------------------------------------------------- действия

  Future<void> _create() async {
    final controller = VaultScope.read(context);
    var type = _section.type;
    type ??= await showDialog<ItemType>(
      context: context,
      builder: (_) => const _TypeChooser(),
    );
    if (type == null || !mounted) return;
    final saved = await openEditor(
      context,
      controller.draft(type),
      isNew: true,
    );
    if (saved != null && mounted) {
      setState(() => _selectedId = saved.id);
    }
  }

  void _open(VaultItem item) {
    if (_wide) {
      setState(() => _selectedId = item.id);
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ItemDetailView(itemId: item.id),
        ),
      );
    }
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
  }

  Future<void> _toggleDone(VaultItem item) async {
    await VaultScope.read(context).save(item.copyWith(done: !item.done));
  }

  // ---------------------------------------------------------------- вёрстка

  @override
  Widget build(BuildContext context) {
    final controller = VaultScope.of(context);
    final tags = controller.allTags;
    if (_tag != null && !tags.contains(_tag)) _tag = null;
    final items = _visibleItems(controller);
    final listPane = _buildListPane(controller, items, tags);

    if (!_wide) {
      return Scaffold(
        body: SafeArea(bottom: false, child: listPane),
        floatingActionButton: FloatingActionButton(
          tooltip: 'Новая запись',
          onPressed: _create,
          child: const Icon(Icons.add_rounded),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _section.index,
          onDestinationSelected: _selectSection,
          destinations: [
            for (final s in _Section.values)
              NavigationDestination(icon: Icon(s.icon), label: s.label),
          ],
        ),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final selected = controller.itemById(_selectedId);
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            NavigationRail(
              selectedIndex: _section.index,
              onDestinationSelected: _selectSection,
              labelType: NavigationRailLabelType.all,
              leading: Column(
                children: [
                  const SizedBox(height: 8),
                  const AppLogo(size: 44),
                  const SizedBox(height: 20),
                  FloatingActionButton(
                    elevation: 0,
                    tooltip: 'Новая запись (Ctrl+N)',
                    onPressed: _create,
                    child: const Icon(Icons.add_rounded),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
              trailing: Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Заблокировать (Ctrl+L)',
                          icon: const Icon(Icons.lock_rounded),
                          onPressed: controller.lock,
                        ),
                        IconButton(
                          tooltip: 'Настройки',
                          icon: const Icon(Icons.settings_rounded),
                          onPressed: _openSettings,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              destinations: [
                for (final s in _Section.values)
                  NavigationRailDestination(
                    icon: Icon(s.icon),
                    label: Text(s.label),
                  ),
              ],
            ),
            const VerticalDivider(),
            SizedBox(width: 400, child: listPane),
            const VerticalDivider(),
            Expanded(
              child: ColoredBox(
                color: scheme.surfaceContainerLowest,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOutCubic,
                  child: selected == null
                      ? const _EmptyDetail(key: ValueKey('empty'))
                      : ItemDetailView(
                          key: ValueKey(selected.id),
                          itemId: selected.id,
                          embedded: true,
                          onClosed: () => setState(() => _selectedId = null),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildListPane(
    VaultController controller,
    List<VaultItem> items,
    List<String> tags,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final searching = _search.text.trim().isNotEmpty;
    final wide = _wide;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  focusNode: _searchFocus,
                  onChanged: (_) => setState(_appeared.clear),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: wide ? 'Поиск (Ctrl+F)' : 'Поиск по всем записям',
                    prefixIcon: const Icon(Icons.search_rounded),
                    isDense: true,
                    suffixIcon: searching
                        ? IconButton(
                            tooltip: 'Очистить',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => setState(() {
                              _search.clear();
                              _appeared.clear();
                            }),
                          )
                        : null,
                  ),
                ),
              ),
              PopupMenuButton<_SortMode>(
                tooltip: 'Сортировка',
                icon: const Icon(Icons.sort_rounded),
                initialValue: _sort,
                onSelected: (mode) => setState(() => _sort = mode),
                itemBuilder: (_) => [
                  for (final mode in _SortMode.values)
                    PopupMenuItem(value: mode, child: Text(mode.label)),
                ],
              ),
              if (wide)
                IconButton(
                  tooltip: 'Обновить из папки',
                  icon: const Icon(Icons.sync_rounded),
                  onPressed: controller.reload,
                )
              else ...[
                IconButton(
                  tooltip: 'Заблокировать',
                  icon: const Icon(Icons.lock_rounded),
                  onPressed: controller.lock,
                ),
                IconButton(
                  tooltip: 'Настройки',
                  icon: const Icon(Icons.settings_rounded),
                  onPressed: _openSettings,
                ),
              ],
            ],
          ),
        ),
        if (_section == _Section.tasks && !searching)
          _ChipRow(
            children: [
              for (final filter in _TaskFilter.values)
                ChoiceChip(
                  label: Text(filter.label),
                  selected: _taskFilter == filter,
                  onSelected: (_) => setState(() {
                    _taskFilter = filter;
                    _appeared.clear();
                  }),
                ),
            ],
          ),
        if (tags.isNotEmpty)
          _ChipRow(
            children: [
              for (final tag in tags)
                FilterChip(
                  label: Text(tag),
                  avatar: const Icon(Icons.sell_outlined, size: 14),
                  selected: _tag == tag,
                  onSelected: (on) => setState(() {
                    _tag = on ? tag : null;
                    _appeared.clear();
                  }),
                ),
            ],
          ),
        if (controller.unreadable > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Не удалось прочитать файлов: ${controller.unreadable}. '
                'Вероятно, синхронизация ещё не завершена.',
                style: TextStyle(color: scheme.onTertiaryContainer),
              ),
            ),
          ),
        if (searching)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
            child: Text(
              'Найдено во всех разделах: ${items.length}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: controller.reload,
            child: items.isEmpty
                ? LayoutBuilder(
                    builder: (context, constraints) => ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: constraints.maxHeight,
                          child: _EmptyList(searching: searching),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    key: PageStorageKey('${_section.name}-list'),
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final animate = index < 14 && _appeared.add(item.id);
                      return Appear(
                        key: ValueKey(item.id),
                        enabled: animate,
                        delay: Duration(milliseconds: 28 * index.clamp(0, 14)),
                        child: _ItemTile(
                          item: item,
                          selected: wide && item.id == _selectedId,
                          onTap: () => _open(item),
                          onToggleDone: () => _toggleDone(item),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class _ChipRow extends StatelessWidget {
  const _ChipRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: children.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, index) => Center(child: children[index]),
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.onToggleDone,
  });

  final VaultItem item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggleDone;

  String get _subtitle => switch (item.type) {
        ItemType.password =>
          item.username.isNotEmpty ? item.username : item.url,
        ItemType.server => '${item.protocol} · ${item.endpoint}',
        ItemType.note => 'Секретная заметка',
        ItemType.task => item.dueDate == null
            ? 'Без срока'
            : dueLabel(item.dueDate!),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isTask = item.type == ItemType.task;
    final overdue = isOverdue(item);
    final subtitle = _subtitle;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
            child: Row(
              children: [
                if (isTask)
                  SizedBox(
                    width: 42,
                    height: 42,
                    child: IconButton(
                      tooltip: item.done
                          ? 'Вернуть в работу'
                          : 'Отметить выполненной',
                      onPressed: onToggleDone,
                      icon: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        transitionBuilder: (child, animation) =>
                            ScaleTransition(scale: animation, child: child),
                        child: Icon(
                          item.done
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          key: ValueKey(item.done),
                          color: item.done
                              ? AppColors.forType(ItemType.task)
                              : AppColors.forPriority(item.priority),
                          size: 26,
                        ),
                      ),
                    ),
                  )
                else
                  TypeAvatar(type: item.type),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          decoration: isTask && item.done
                              ? TextDecoration.lineThrough
                              : null,
                          color: isTask && item.done
                              ? scheme.onSurfaceVariant
                              : null,
                        ),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: overdue
                                ? scheme.error
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (item.password.isNotEmpty)
                  IconButton(
                    tooltip: 'Скопировать пароль',
                    icon: const Icon(Icons.copy_rounded, size: 20),
                    onPressed: () =>
                        copyValue(context, item.password, 'Пароль'),
                  )
                else if (isTask)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Icon(
                      Icons.flag_rounded,
                      size: 18,
                      color: AppColors.forPriority(item.priority),
                    ),
                  )
                else
                  const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyList extends StatelessWidget {
  const _EmptyList({required this.searching});

  final bool searching;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              searching ? Icons.search_off_rounded : Icons.inbox_rounded,
              size: 56,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              searching ? 'Ничего не найдено' : 'Здесь пока пусто',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              searching
                  ? 'Попробуйте изменить запрос или снять фильтр по тегу.'
                  : 'Нажмите «+», чтобы добавить запись.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Opacity(opacity: 0.6, child: const AppLogo(size: 72)),
          const SizedBox(height: 20),
          Text('Выберите запись', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'Ctrl+N — новая запись · Ctrl+F — поиск · Ctrl+L — блокировка',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _TypeChooser extends StatelessWidget {
  const _TypeChooser();

  @override
  Widget build(BuildContext context) {
    return SimpleDialog(
      title: const Text('Новая запись'),
      contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      children: [
        for (final type in ItemType.values)
          ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            leading: TypeAvatar(type: type),
            title: Text(typeLabel(type)),
            onTap: () => Navigator.pop(context, type),
          ),
      ],
    );
  }
}
