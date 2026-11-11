import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'vault_store.dart';

/// Локальные настройки устройства (не синхронизируются и не секретны):
/// путь к папке хранилища, тема, время автоблокировки.
class AppSettings extends ChangeNotifier {
  AppSettings(this._prefs);

  static const _keyPath = 'vaultPath';
  static const _keyTheme = 'themeMode';
  static const _keyAutoLock = 'autoLockMinutes';

  static const autoLockChoices = [1, 2, 5, 10, 30];
  static const clipboardClearDelay = Duration(seconds: 30);

  final SharedPreferences _prefs;

  static Future<AppSettings> load() async =>
      AppSettings(await SharedPreferences.getInstance());

  /// Папка хранилища по умолчанию для текущей платформы.
  static String defaultVaultPath() {
    if (Platform.isAndroid) {
      return '/storage/emulated/0/Documents/SecretVault';
    }
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    return joinPath(joinPath(home, 'Documents'), 'SecretVault');
  }

  String? get vaultPath => _prefs.getString(_keyPath);

  Future<void> setVaultPath(String? path) async {
    if (path == null) {
      await _prefs.remove(_keyPath);
    } else {
      await _prefs.setString(_keyPath, path);
    }
    notifyListeners();
  }

  ThemeMode get themeMode => switch (_prefs.getString(_keyTheme)) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      };

  Future<void> setThemeMode(ThemeMode mode) async {
    await _prefs.setString(_keyTheme, mode.name);
    notifyListeners();
  }

  int get autoLockMinutes => _prefs.getInt(_keyAutoLock) ?? 5;

  Future<void> setAutoLockMinutes(int minutes) async {
    await _prefs.setInt(_keyAutoLock, minutes);
    notifyListeners();
  }
}
