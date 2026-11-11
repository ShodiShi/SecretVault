import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:secret_vault/models/vault_item.dart';
import 'package:secret_vault/state/vault_controller.dart';
import 'package:secret_vault/storage/app_settings.dart';
import 'package:secret_vault/ui/app.dart';
import 'package:secret_vault/ui/screens/home_screen.dart';
import 'package:secret_vault/ui/screens/item_detail_view.dart';
import 'package:secret_vault/ui/screens/settings_screen.dart';
import 'package:secret_vault/ui/screens/setup_screen.dart';
import 'package:secret_vault/ui/screens/unlock_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Дымовой тест: приложение проходит путь «первый запуск → хранилище →
/// список → детали → блокировка» без ошибок вёрстки на обоих макетах.
void main() {
  testWidgets('основные экраны строятся на широком и узком макете',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('secretvault_ui_');
    late AppSettings settings;
    late VaultController controller;

    await tester.runAsync(() async {
      await initializeDateFormatting('ru');
      settings = await AppSettings.load();
      controller = VaultController(settings);
      await controller.init();
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      SecretVaultApp(settings: settings, controller: controller),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SetupScreen), findsOneWidget);

    await tester.runAsync(() async {
      await controller.createVault(dir.path, 'correct horse', light: true);
      await controller.save(
        controller.draft(ItemType.password).copyWith(
          title: 'Почта',
          username: 'admin',
          password: 's3cret-Пароль',
          tags: ['работа'],
        ),
      );
      await controller.save(
        controller.draft(ItemType.server).copyWith(
          title: 'Шлюз',
          host: '10.0.0.1',
          port: 2222,
          protocol: 'SSH',
          username: 'root',
        ),
      );
      await controller.save(
        controller.draft(ItemType.note).copyWith(title: 'Коды', note: '1234'),
      );
      await controller.save(
        controller.draft(ItemType.task).copyWith(
          title: 'Обновить сертификат',
          dueDate: DateTime.now(),
          priority: TaskPriority.high,
        ),
      );
    });
    await tester.pumpAndSettle();

    // Широкий макет: рейка навигации и двухпанельный режим.
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('Почта'), findsOneWidget);
    await tester.tap(find.text('Шлюз'));
    await tester.pumpAndSettle();
    expect(find.byType(ItemDetailView), findsOneWidget);
    expect(find.text('ssh root@10.0.0.1 -p 2222'), findsOneWidget);

    // Разделы и поиск.
    await tester.tap(find.text('Задачи'));
    await tester.pumpAndSettle();
    expect(find.text('Обновить сертификат'), findsOneWidget);
    expect(find.text('Почта'), findsNothing);
    await tester.enterText(find.byType(TextField).first, 'почт');
    await tester.pumpAndSettle();
    expect(find.text('Почта'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();

    // Настройки.
    await tester.tap(find.byTooltip('Настройки'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    // Узкий макет: нижняя панель, детали отдельной страницей.
    tester.view.physicalSize = const Size(400, 800);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Все'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Почта'));
    await tester.pumpAndSettle();
    expect(find.byType(ItemDetailView), findsOneWidget);
    expect(find.text('s3cret-Пароль'), findsNothing); // скрыт точками

    // Блокировка закрывает открытые страницы.
    controller.lock();
    await tester.pumpAndSettle();
    expect(find.byType(UnlockScreen), findsOneWidget);
    expect(find.byType(ItemDetailView), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.runAsync(() async {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Временную папку уберёт система.
      }
    });
  });
}
