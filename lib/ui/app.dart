import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../state/vault_controller.dart';
import '../storage/app_settings.dart';
import 'screens/home_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/unlock_screen.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// Корневой виджет: тема, локаль, автоблокировка и выбор экрана по
/// состоянию хранилища.
class SecretVaultApp extends StatefulWidget {
  const SecretVaultApp({
    super.key,
    required this.settings,
    required this.controller,
  });

  final AppSettings settings;
  final VaultController controller;

  @override
  State<SecretVaultApp> createState() => _SecretVaultAppState();
}

class _SecretVaultAppState extends State<SecretVaultApp>
    with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();
  late VaultStatus _lastStatus = widget.controller.status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_handleKey);
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    HardwareKeyboard.instance.removeHandler(_handleKey);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        widget.controller.onAppPaused();
      case AppLifecycleState.resumed:
        widget.controller.onAppResumed();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  /// При блокировке закрываем все открытые поверх страницы и диалоги,
  /// чтобы расшифрованные данные не остались на экране.
  void _onControllerChanged() {
    final status = widget.controller.status;
    if (status == _lastStatus) return;
    final wasUnlocked = _lastStatus == VaultStatus.unlocked;
    _lastStatus = status;
    if (wasUnlocked) {
      _navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
  }

  /// Любое нажатие — активность; Ctrl+L — блокировка (физическая клавиша,
  /// чтобы работало и в русской раскладке).
  bool _handleKey(KeyEvent event) {
    final controller = widget.controller;
    controller.touch();
    if (event is KeyDownEvent &&
        event.physicalKey == PhysicalKeyboardKey.keyL &&
        HardwareKeyboard.instance.isControlPressed &&
        controller.status == VaultStatus.unlocked) {
      controller.lock();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) => MaterialApp(
        title: 'SecretVault',
        debugShowCheckedModeBanner: false,
        navigatorKey: _navigatorKey,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: widget.settings.themeMode,
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => widget.controller.touch(),
          onPointerSignal: (_) => widget.controller.touch(),
          child: VaultScope(
            controller: widget.controller,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
        home: const _Root(),
      ),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final status = VaultScope.of(context).status;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: KeyedSubtree(
        key: ValueKey(status),
        child: switch (status) {
          VaultStatus.loading => const _Splash(),
          VaultStatus.needsSetup => const SetupScreen(),
          VaultStatus.locked => const UnlockScreen(),
          VaultStatus.unlocked => const HomeScreen(),
        },
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: AppLogo()));
  }
}
