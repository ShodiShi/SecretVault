import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../storage/app_settings.dart';

/// Буфер обмена для секретов: копирование с пометкой «конфиденциально»
/// (скрытие в предпросмотре Android 13+, исключение из журнала буфера
/// Windows) и автоочистка через 30 секунд.
class SecureClipboard {
  SecureClipboard._();
  static final instance = SecureClipboard._();

  static const _channel = MethodChannel('secretvault/platform');

  Timer? _timer;
  String? _pending;

  /// Копирует [text]. Секреты ([sensitive]) стираются из буфера по таймеру.
  Future<void> copy(String text, {bool sensitive = true}) async {
    _timer?.cancel();
    _pending = null;
    if (!sensitive) {
      await Clipboard.setData(ClipboardData(text: text));
      return;
    }
    try {
      await _channel.invokeMethod<void>('copySensitive', {'text': text});
    } on MissingPluginException {
      await Clipboard.setData(ClipboardData(text: text));
    } on PlatformException {
      await Clipboard.setData(ClipboardData(text: text));
    }
    _pending = text;
    _timer = Timer(AppSettings.clipboardClearDelay, _clearIfOurs);
  }

  Future<void> _clearIfOurs() async {
    final expected = _pending;
    _pending = null;
    if (expected == null) return;
    // Стираем только своё значение, чтобы не уничтожить то, что пользователь
    // скопировал позже. Android не даёт читать буфер из фона — там чистим
    // безусловно: безопасность важнее.
    if (!Platform.isAndroid) {
      try {
        final current = await Clipboard.getData(Clipboard.kTextPlain);
        if (current?.text != expected) return;
      } on PlatformException {
        return;
      }
    }
    try {
      await _channel.invokeMethod<void>('clearClipboard');
    } on MissingPluginException {
      await Clipboard.setData(const ClipboardData(text: ''));
    } on PlatformException {
      await Clipboard.setData(const ClipboardData(text: ''));
    }
  }
}
