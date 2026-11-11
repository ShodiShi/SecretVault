import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../models/vault_item.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/password_generator_dialog.dart';

const wideLayoutBreakpoint = 900.0;

/// Открывает редактор: диалогом на широком экране, отдельной страницей на
/// телефоне. Возвращает сохранённую запись или null.
Future<VaultItem?> openEditor(
  BuildContext context,
  VaultItem item, {
  required bool isNew,
}) {
  if (MediaQuery.sizeOf(context).width >= wideLayoutBreakpoint) {
    return showDialog<VaultItem>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 780),
          child: ItemEditScreen(item: item, isNew: isNew),
        ),
      ),
    );
  }
  return Navigator.of(context).push<VaultItem>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ItemEditScreen(item: item, isNew: isNew),
    ),
  );
}

class ItemEditScreen extends StatefulWidget {
  const ItemEditScreen({super.key, required this.item, required this.isNew});

  final VaultItem item;
  final bool isNew;

  @override
  State<ItemEditScreen> createState() => _ItemEditScreenState();
}

class _ItemEditScreenState extends State<ItemEditScreen> {
  late final _title = TextEditingController(text: widget.item.title);
  late final _username = TextEditingController(text: widget.item.username);
  late final _password = TextEditingController(text: widget.item.password);
  late final _url = TextEditingController(text: widget.item.url);
  late final _host = TextEditingController(text: widget.item.host);
  late final _port =
      TextEditingController(text: widget.item.port?.toString() ?? '');
  late final _note = TextEditingController(text: widget.item.note);
  late final _tags = TextEditingController(text: widget.item.tags.join(', '));

  late String _protocol = serverProtocols.contains(widget.item.protocol)
      ? widget.item.protocol
      : 'Другое';
  late DateTime? _dueDate = widget.item.dueDate;
  late TaskPriority _priority = widget.item.priority;
  late bool _done = widget.item.done;

  bool _dirty = false;
  bool _saving = false;
  String? _titleError;
  String? _hostError;

  ItemType get _type => widget.item.type;

  List<TextEditingController> get _controllers =>
      [_title, _username, _password, _url, _host, _port, _note, _tags];

  @override
  void initState() {
    super.initState();
    for (final c in _controllers) {
      c.addListener(_markDirty);
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  List<String> _parseTags() {
    final seen = <String>{};
    return [
      for (final raw in _tags.text.split(','))
        if (raw.trim().isNotEmpty && seen.add(raw.trim().toLowerCase()))
          raw.trim(),
    ];
  }

  Future<void> _save() async {
    if (_saving) return;
    final title = _title.text.trim();
    final host = _host.text.trim();
    setState(() {
      _titleError = title.isEmpty ? 'Введите название' : null;
      _hostError = _type == ItemType.server && host.isEmpty
          ? 'Введите хост или IP-адрес'
          : null;
    });
    if (_titleError != null || _hostError != null) return;

    final item = widget.item.copyWith(
      title: title,
      username: _username.text.trim(),
      password: _password.text,
      url: _url.text.trim(),
      host: host,
      port: int.tryParse(_port.text.trim()),
      protocol: _protocol,
      note: _note.text.trimRight(),
      tags: _parseTags(),
      dueDate: _dueDate,
      priority: _priority,
      done: _done,
    );
    setState(() => _saving = true);
    try {
      final saved = await VaultScope.read(context).save(item);
      if (!mounted) return;
      _dirty = false;
      Navigator.of(context).pop(saved);
    } on FileSystemException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showSnack(
        context,
        'Не удалось сохранить: ${e.osError?.message ?? e.message}',
        error: true,
      );
    } on StateError {
      // Хранилище заблокировалось, пока запись редактировалась.
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _generate() async {
    final password = await showPasswordGenerator(context);
    if (password != null) setState(() => _password.text = password);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 20),
      helpText: 'Срок выполнения',
    );
    if (picked != null) {
      setState(() {
        _dueDate = picked;
        _dirty = true;
      });
    }
  }

  Future<void> _onPopInvoked(bool didPop) async {
    if (didPop) return;
    final navigator = Navigator.of(context);
    final discard = await confirmDialog(
      context,
      title: 'Закрыть без сохранения?',
      message: 'Изменения в записи будут потеряны.',
      confirmLabel: 'Не сохранять',
      destructive: true,
    );
    if (discard && mounted) {
      setState(() => _dirty = false);
      // Дождаться перестройки PopScope, затем закрыть экран.
      WidgetsBinding.instance.addPostFrameCallback((_) => navigator.pop());
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.isNew
        ? switch (_type) {
            ItemType.password => 'Новый пароль',
            ItemType.server => 'Новый сервер',
            ItemType.note => 'Новая заметка',
            ItemType.task => 'Новая задача',
          }
        : 'Изменить запись';

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) => _onPopInvoked(didPop),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        },
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              tooltip: 'Закрыть',
              icon: const Icon(Icons.close_rounded),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            title: Row(
              children: [
                TypeAvatar(type: _type, size: 32),
                const SizedBox(width: 12),
                Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
              ],
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_rounded, size: 20),
                  label: const Text('Сохранить'),
                ),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              TextField(
                controller: _title,
                autofocus: widget.isNew,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'Название',
                  errorText: _titleError,
                ),
              ),
              const SizedBox(height: 14),
              ...switch (_type) {
                ItemType.password => _passwordFields(),
                ItemType.server => _serverFields(),
                ItemType.note => _noteFields(),
                ItemType.task => _taskFields(),
              },
              const SizedBox(height: 14),
              _tagsField(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _gap() => const SizedBox(height: 14);

  Widget _passwordInput() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SecretTextField(
            controller: _password,
            label: 'Пароль',
            mono: true,
            onChanged: (_) => setState(() {}),
            extraActions: [
              IconButton(
                tooltip: 'Генератор паролей',
                icon: const Icon(Icons.auto_awesome_rounded),
                onPressed: _generate,
              ),
            ],
          ),
          if (_password.text.isNotEmpty) ...[
            const SizedBox(height: 8),
            StrengthBar(password: _password.text),
          ],
        ],
      );

  Widget _noteInput(String label, {int minLines = 3, bool mono = false}) =>
      TextField(
        controller: _note,
        minLines: minLines,
        maxLines: 14,
        keyboardType: TextInputType.multiline,
        style: mono ? monoStyle : null,
        enableSuggestions: !mono,
        autocorrect: !mono,
        decoration: InputDecoration(labelText: label, alignLabelWithHint: true),
      );

  List<Widget> _passwordFields() => [
        TextField(
          controller: _username,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Логин'),
        ),
        _gap(),
        _passwordInput(),
        _gap(),
        TextField(
          controller: _url,
          autocorrect: false,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'URL'),
        ),
        _gap(),
        _noteInput('Заметка'),
      ];

  List<Widget> _serverFields() => [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _host,
                autocorrect: false,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                style: monoStyle,
                decoration: InputDecoration(
                  labelText: 'Хост или IP',
                  errorText: _hostError,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _port,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.next,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(5),
                ],
                style: monoStyle,
                decoration: const InputDecoration(labelText: 'Порт'),
              ),
            ),
          ],
        ),
        _gap(),
        DropdownButtonFormField<String>(
          initialValue: _protocol,
          decoration: const InputDecoration(labelText: 'Протокол'),
          borderRadius: BorderRadius.circular(14),
          items: [
            for (final p in serverProtocols)
              DropdownMenuItem(value: p, child: Text(p)),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              // Порт меняем, только если он был пуст или стандартен
              // для прежнего протокола.
              final current = int.tryParse(_port.text.trim());
              if (current == null || current == defaultPortFor(_protocol)) {
                _port.text = defaultPortFor(value)?.toString() ?? '';
              }
              _protocol = value;
              _dirty = true;
            });
          },
        ),
        _gap(),
        TextField(
          controller: _username,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Логин'),
        ),
        _gap(),
        _passwordInput(),
        _gap(),
        _noteInput('Заметка'),
      ];

  List<Widget> _noteFields() => [
        _noteInput('Текст (ключи, токены, конфиги)', minLines: 8, mono: true),
      ];

  List<Widget> _taskFields() {
    final scheme = Theme.of(context).colorScheme;
    final due = _dueDate;
    return [
      _noteInput('Описание'),
      _gap(),
      InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _pickDate,
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: 'Срок',
            prefixIcon: const Icon(Icons.event_rounded),
            suffixIcon: due == null
                ? null
                : IconButton(
                    tooltip: 'Убрать срок',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => setState(() {
                      _dueDate = null;
                      _dirty = true;
                    }),
                  ),
          ),
          child: Text(
            due == null
                ? 'Без срока'
                : DateFormat('d MMMM y, EEEE', 'ru').format(due),
            style: TextStyle(
              color: due == null ? scheme.onSurfaceVariant : scheme.onSurface,
            ),
          ),
        ),
      ),
      _gap(),
      Text('Приоритет', style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 8),
      SegmentedButton<TaskPriority>(
        segments: [
          for (final p in TaskPriority.values)
            ButtonSegment(
              value: p,
              label: Text(priorityLabel(p)),
              icon: Icon(
                Icons.circle,
                size: 10,
                color: AppColors.forPriority(p),
              ),
            ),
        ],
        showSelectedIcon: false,
        selected: {_priority},
        onSelectionChanged: (v) => setState(() {
          _priority = v.first;
          _dirty = true;
        }),
      ),
      const SizedBox(height: 6),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Выполнено'),
        value: _done,
        onChanged: (v) => setState(() {
          _done = v;
          _dirty = true;
        }),
      ),
    ];
  }

  Widget _tagsField() {
    final current = _parseTags().map((t) => t.toLowerCase()).toSet();
    final suggestions = VaultScope.of(context)
        .allTags
        .where((t) => !current.contains(t.toLowerCase()))
        .take(12)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _tags,
          autocorrect: false,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Теги',
            hintText: 'через запятую: работа, prod',
            prefixIcon: Icon(Icons.sell_outlined),
          ),
        ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final tag in suggestions)
                ActionChip(
                  label: Text(tag),
                  avatar: const Icon(Icons.add_rounded, size: 16),
                  onPressed: () {
                    final tags = [..._parseTags(), tag];
                    setState(() => _tags.text = tags.join(', '));
                  },
                ),
            ],
          ),
        ],
      ],
    );
  }
}
