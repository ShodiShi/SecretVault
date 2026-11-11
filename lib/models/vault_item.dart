enum ItemType { password, server, note, task }

enum TaskPriority { low, medium, high }

const serverProtocols = ['SSH', 'RDP', 'HTTP', 'HTTPS', 'FTP', 'Другое'];

/// Порт по умолчанию для протокола (null — неизвестен).
int? defaultPortFor(String protocol) => switch (protocol) {
      'SSH' => 22,
      'RDP' => 3389,
      'HTTP' => 80,
      'HTTPS' => 443,
      'FTP' => 21,
      _ => null,
    };

const _unset = Object();

/// Одна запись хранилища. Все четыре типа записей живут в одном классе:
/// неиспользуемые поля остаются пустыми и не попадают в JSON.
class VaultItem {
  VaultItem({
    required this.id,
    required this.type,
    required this.title,
    this.username = '',
    this.password = '',
    this.url = '',
    this.host = '',
    this.port,
    this.protocol = 'SSH',
    this.note = '',
    List<String> tags = const [],
    this.dueDate,
    this.priority = TaskPriority.medium,
    this.done = false,
    required this.createdAt,
    required this.updatedAt,
    this.deleted = false,
  }) : tags = List.unmodifiable(tags);

  final String id;
  final ItemType type;
  final String title;

  final String username;
  final String password;
  final String url;

  final String host;
  final int? port;
  final String protocol;

  /// Заметка к записи, текст секретной заметки или описание задачи.
  final String note;
  final List<String> tags;

  /// Срок задачи (только дата, локальная полночь).
  final DateTime? dueDate;
  final TaskPriority priority;
  final bool done;

  /// Миллисекунды с начала эпохи, UTC.
  final int createdAt;
  final int updatedAt;

  /// Tombstone: запись удалена, файл остаётся для синхронизации удаления.
  final bool deleted;

  VaultItem copyWith({
    String? title,
    String? username,
    String? password,
    String? url,
    String? host,
    Object? port = _unset,
    String? protocol,
    String? note,
    List<String>? tags,
    Object? dueDate = _unset,
    TaskPriority? priority,
    bool? done,
    int? updatedAt,
    bool? deleted,
  }) =>
      VaultItem(
        id: id,
        type: type,
        title: title ?? this.title,
        username: username ?? this.username,
        password: password ?? this.password,
        url: url ?? this.url,
        host: host ?? this.host,
        port: identical(port, _unset) ? this.port : port as int?,
        protocol: protocol ?? this.protocol,
        note: note ?? this.note,
        tags: tags ?? this.tags,
        dueDate:
            identical(dueDate, _unset) ? this.dueDate : dueDate as DateTime?,
        priority: priority ?? this.priority,
        done: done ?? this.done,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        deleted: deleted ?? this.deleted,
      );

  /// Tombstone без секретного содержимого.
  VaultItem tombstone(int updatedAt) => VaultItem(
        id: id,
        type: type,
        title: '',
        createdAt: createdAt,
        updatedAt: updatedAt,
        deleted: true,
      );

  /// Команда подключения по SSH, либо null, если запись не SSH-сервер.
  String? get sshCommand {
    if (type != ItemType.server || protocol != 'SSH' || host.isEmpty) {
      return null;
    }
    final target = username.isEmpty ? host : '$username@$host';
    final p = port ?? 22;
    return p == 22 ? 'ssh $target' : 'ssh $target -p $p';
  }

  /// Адрес сервера в виде host:port.
  String get endpoint => port == null ? host : '$host:$port';

  Map<String, dynamic> toJson() {
    final due = dueDate;
    return {
      'id': id,
      'type': type.name,
      'title': title,
      if (username.isNotEmpty) 'username': username,
      if (password.isNotEmpty) 'password': password,
      if (url.isNotEmpty) 'url': url,
      if (host.isNotEmpty) 'host': host,
      if (port != null) 'port': port,
      if (type == ItemType.server) 'protocol': protocol,
      if (note.isNotEmpty) 'note': note,
      if (tags.isNotEmpty) 'tags': tags,
      if (due != null)
        'dueDate': '${due.year.toString().padLeft(4, '0')}-'
            '${due.month.toString().padLeft(2, '0')}-'
            '${due.day.toString().padLeft(2, '0')}',
      if (type == ItemType.task) 'priority': priority.name,
      if (type == ItemType.task) 'done': done,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'deleted': deleted,
    };
  }

  static VaultItem fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final typeName = json['type'];
    final updatedAt = json['updatedAt'];
    if (id is! String || typeName is! String || updatedAt is! int) {
      throw const FormatException('Некорректная запись');
    }
    final type = ItemType.values.asNameMap()[typeName];
    if (type == null) {
      throw FormatException('Неизвестный тип записи: $typeName');
    }
    DateTime? due;
    final dueRaw = json['dueDate'];
    if (dueRaw is String) {
      final parsed = DateTime.tryParse(dueRaw);
      if (parsed != null) due = DateTime(parsed.year, parsed.month, parsed.day);
    }
    String str(String key) => json[key] is String ? json[key] as String : '';
    return VaultItem(
      id: id,
      type: type,
      title: str('title'),
      username: str('username'),
      password: str('password'),
      url: str('url'),
      host: str('host'),
      port: json['port'] is int ? json['port'] as int : null,
      protocol: json['protocol'] is String ? json['protocol'] as String : 'SSH',
      note: str('note'),
      tags: json['tags'] is List
          ? (json['tags'] as List).whereType<String>().toList()
          : const [],
      dueDate: due,
      priority: TaskPriority.values.asNameMap()[json['priority']] ??
          TaskPriority.medium,
      done: json['done'] == true,
      createdAt: json['createdAt'] is int ? json['createdAt'] as int : updatedAt,
      updatedAt: updatedAt,
      deleted: json['deleted'] == true,
    );
  }
}
