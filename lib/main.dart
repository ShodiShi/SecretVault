import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'state/vault_controller.dart';
import 'storage/app_settings.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru');
  final settings = await AppSettings.load();
  final controller = VaultController(settings);
  runApp(SecretVaultApp(settings: settings, controller: controller));
  unawaited(controller.init());
}
