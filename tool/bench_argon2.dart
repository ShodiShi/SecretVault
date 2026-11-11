// Замер скорости Argon2id: dart run tool/bench_argon2.dart
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

Future<void> main() async {
  for (final (mem, iters) in [(19456, 2), (65536, 3)]) {
    final algo = Argon2id(
      memory: mem,
      iterations: iters,
      parallelism: 1,
      hashLength: 32,
    );
    final sw = Stopwatch()..start();
    final key = await algo.deriveKey(
      secretKey: SecretKey(utf8.encode('correct horse battery staple')),
      nonce: List<int>.generate(16, (i) => i),
    );
    final bytes = await key.extractBytes();
    sw.stop();
    stdout.writeln('m=$mem KiB t=$iters: ${sw.elapsedMilliseconds} ms '
        '(${bytes.take(4).map((b) => b.toRadixString(16)).join()})');
  }
}
