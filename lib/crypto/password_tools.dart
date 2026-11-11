import 'dart:math';

/// Настройки генератора паролей.
class GeneratorOptions {
  const GeneratorOptions({
    this.length = 20,
    this.upper = true,
    this.digits = true,
    this.symbols = true,
  });

  final int length;
  final bool upper;
  final bool digits;
  final bool symbols;

  GeneratorOptions copyWith({
    int? length,
    bool? upper,
    bool? digits,
    bool? symbols,
  }) =>
      GeneratorOptions(
        length: length ?? this.length,
        upper: upper ?? this.upper,
        digits: digits ?? this.digits,
        symbols: symbols ?? this.symbols,
      );
}

abstract final class PasswordGenerator {
  // Без похожих символов (l, I, O, 0, 1), чтобы пароль можно было перепечатать.
  static const lowerChars = 'abcdefghijkmnopqrstuvwxyz';
  static const upperChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  static const digitChars = '23456789';
  static const symbolChars = '!@#\$%^&*()-_=+[]{};:,.?';

  static final _random = Random.secure();

  /// Генерирует пароль; в нём гарантированно есть символ каждого
  /// включённого класса. Строчные буквы используются всегда.
  static String generate(GeneratorOptions options, {Random? random}) {
    final rnd = random ?? _random;
    final classes = <String>[
      lowerChars,
      if (options.upper) upperChars,
      if (options.digits) digitChars,
      if (options.symbols) symbolChars,
    ];
    final length = max(options.length, classes.length);
    final all = classes.join();
    final chars = <String>[
      for (final cls in classes) cls[rnd.nextInt(cls.length)],
      for (var i = classes.length; i < length; i++) all[rnd.nextInt(all.length)],
    ];
    // Тасование Фишера — Йетса, чтобы обязательные символы не стояли в начале.
    for (var i = chars.length - 1; i > 0; i--) {
      final j = rnd.nextInt(i + 1);
      final tmp = chars[i];
      chars[i] = chars[j];
      chars[j] = tmp;
    }
    return chars.join();
  }
}

/// Оценка силы пароля: 0 (очень слабый) … 4 (отличный).
class PasswordStrength {
  const PasswordStrength(this.score, this.bits);

  final int score;

  /// Грубая оценка энтропии в битах.
  final double bits;

  String get label => const [
        'Очень слабый',
        'Слабый',
        'Средний',
        'Хороший',
        'Отличный',
      ][score];

  static const _common = {
    'password', 'qwerty', '123456', '12345678', '123456789', '1234567890',
    'admin', 'root', 'toor', 'letmein', 'welcome', 'iloveyou', 'monkey',
    'dragon', 'master', 'login', 'passw0rd', 'p@ssw0rd', 'qwerty123',
    'qwertyuiop', '1q2w3e4r', '1qaz2wsx', 'zaq12wsx', 'abc123', '111111',
    '000000', 'пароль', 'йцукен', 'админ', 'привет', 'administrator',
  };

  static PasswordStrength estimate(String password) {
    if (password.isEmpty) return const PasswordStrength(0, 0);
    final lowered = password.toLowerCase();
    if (_common.contains(lowered)) return const PasswordStrength(0, 8);

    var pool = 0;
    if (RegExp(r'[a-z]').hasMatch(password)) pool += 26;
    if (RegExp(r'[A-Z]').hasMatch(password)) pool += 26;
    if (RegExp(r'[0-9]').hasMatch(password)) pool += 10;
    if (RegExp(r'[а-яё]').hasMatch(password)) pool += 33;
    if (RegExp(r'[А-ЯЁ]').hasMatch(password)) pool += 33;
    if (RegExp(r'[^a-zA-Z0-9а-яёА-ЯЁ]').hasMatch(password)) pool += 32;
    if (pool == 0) pool = 10;

    // Повторы и последовательности (aaa, abc, 321) почти не добавляют энтропии.
    final units = password.codeUnits;
    var effective = 0.0;
    for (var i = 0; i < units.length; i++) {
      if (i > 0) {
        final diff = units[i] - units[i - 1];
        if (diff == 0 || diff == 1 || diff == -1) {
          effective += 0.25;
          continue;
        }
      }
      effective += 1;
    }
    // Мало разных символов — тоже признак слабого пароля.
    final unique = units.toSet().length;
    if (unique < units.length / 2) {
      effective *= 0.75;
    }

    final bits = effective * (log(pool) / ln2);
    final score = bits < 28
        ? 0
        : bits < 40
            ? 1
            : bits < 60
                ? 2
                : bits < 80
                    ? 3
                    : 4;
    return PasswordStrength(score, bits);
  }
}
