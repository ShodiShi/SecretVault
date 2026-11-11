import 'package:flutter/material.dart';

import '../../crypto/password_tools.dart';
import '../../models/vault_item.dart';
import '../../state/secure_clipboard.dart';
import '../../state/vault_controller.dart';
import '../theme.dart';

/// Доступ к [VaultController] из дерева виджетов.
class VaultScope extends InheritedNotifier<VaultController> {
  const VaultScope({
    super.key,
    required VaultController controller,
    required super.child,
  }) : super(notifier: controller);

  /// С подпиской на изменения.
  static VaultController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VaultScope>()!.notifier!;

  /// Без подписки (для обработчиков событий).
  static VaultController read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<VaultScope>()!.notifier!;
}

void showSnack(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final scheme = Theme.of(context).colorScheme;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? scheme.errorContainer : null,
        duration: const Duration(seconds: 3),
        width: MediaQuery.sizeOf(context).width > 600 ? 420 : null,
      ),
    );
}

/// Копирует значение и сообщает об этом. Секреты стираются из буфера.
Future<void> copyValue(
  BuildContext context,
  String value,
  String what, {
  bool sensitive = true,
}) async {
  await SecureClipboard.instance.copy(value, sensitive: sensitive);
  if (!context.mounted) return;
  showSnack(
    context,
    sensitive ? '$what — скопировано, буфер очистится через 30 с' : '$what — скопировано',
  );
}

/// Логотип приложения на акцентном градиенте.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 88});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: AppColors.accentGradient,
        borderRadius: BorderRadius.circular(size * 0.3),
        boxShadow: [
          BoxShadow(
            color: AppColors.gradientStart.withValues(alpha: 0.35),
            blurRadius: size * 0.4,
            offset: Offset(0, size * 0.12),
          ),
        ],
      ),
      child: Icon(Icons.shield_rounded, color: Colors.white, size: size * 0.55),
    );
  }
}

/// Главная кнопка с акцентным градиентом.
class GradientButton extends StatelessWidget {
  const GradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: enabled || busy ? 1 : 0.45,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: const BoxDecoration(gradient: AppColors.accentGradient),
          child: InkWell(
            onTap: enabled ? onPressed : null,
            child: SizedBox(
              height: 52,
              child: Center(
                child: busy
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: Colors.white,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (icon != null) ...[
                            Icon(icon, color: Colors.white, size: 20),
                            const SizedBox(width: 8),
                          ],
                          Text(
                            label,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Поле ввода пароля с переключателем «показать/скрыть».
class SecretTextField extends StatefulWidget {
  const SecretTextField({
    super.key,
    required this.controller,
    required this.label,
    this.autofocus = false,
    this.onSubmitted,
    this.onChanged,
    this.errorText,
    this.textInputAction,
    this.extraActions = const [],
    this.mono = false,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String label;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final String? errorText;
  final TextInputAction? textInputAction;
  final List<Widget> extraActions;
  final bool mono;
  final bool enabled;

  @override
  State<SecretTextField> createState() => _SecretTextFieldState();
}

class _SecretTextFieldState extends State<SecretTextField> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      obscureText: !_visible,
      enableSuggestions: false,
      autocorrect: false,
      keyboardType: TextInputType.visiblePassword,
      textInputAction: widget.textInputAction,
      onSubmitted: widget.onSubmitted,
      onChanged: widget.onChanged,
      style: widget.mono && _visible ? monoStyle : null,
      decoration: InputDecoration(
        labelText: widget.label,
        errorText: widget.errorText,
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: _visible ? 'Скрыть' : 'Показать',
              icon: Icon(
                _visible
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
              ),
              onPressed: () => setState(() => _visible = !_visible),
            ),
            ...widget.extraActions,
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

/// Индикатор силы пароля.
class StrengthBar extends StatelessWidget {
  const StrengthBar({super.key, required this.password});

  final String password;

  @override
  Widget build(BuildContext context) {
    final strength = PasswordStrength.estimate(password);
    final color = AppColors.strength[strength.score];
    final theme = Theme.of(context);
    final empty = password.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: empty ? 0 : (strength.score + 1) / 5),
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => LinearProgressIndicator(
              value: value,
              minHeight: 6,
              color: color,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          empty
              ? 'Надёжность пароля'
              : '${strength.label} · ≈${strength.bits.round()} бит',
          style: theme.textTheme.bodySmall?.copyWith(
            color: empty ? theme.colorScheme.onSurfaceVariant : color,
          ),
        ),
      ],
    );
  }
}

/// Цветная иконка типа записи.
class TypeAvatar extends StatelessWidget {
  const TypeAvatar({super.key, required this.type, this.size = 42});

  final ItemType type;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = AppColors.forType(type);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(iconForType(type), color: color, size: size * 0.52),
    );
  }
}

/// Плавное появление элемента (сдвиг + прозрачность).
class Appear extends StatefulWidget {
  const Appear({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.enabled = true,
  });

  final Widget child;
  final Duration delay;

  /// Учитывается только при первом построении: начатая анимация
  /// доигрывается, а повторно (при прокрутке) не запускается.
  final bool enabled;

  @override
  State<Appear> createState() => _AppearState();
}

class _AppearState extends State<Appear> {
  late final bool _animate = widget.enabled;

  @override
  Widget build(BuildContext context) {
    if (!_animate) return widget.child;
    const base = Duration(milliseconds: 280);
    final total = base + widget.delay;
    final start = widget.delay.inMilliseconds / total.inMilliseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(start, 1, curve: Curves.easeOutCubic),
      child: widget.child,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, (1 - value) * 14),
          child: child,
        ),
      ),
    );
  }
}

/// Диалог подтверждения; true — пользователь согласился.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                )
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
