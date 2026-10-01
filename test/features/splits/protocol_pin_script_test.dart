// scripts/splits/check-protocol-pin.sh, against throwaway git trees.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _script = File('scripts/splits/check-protocol-pin.sh').absolute.path;

/// A wallet beside a protocol tree with both linked packages committed, and
/// the wallet's pin at that commit.
Future<({Directory wallet, Directory protocol})> _trees() async {
  final root = await Directory.systemTemp.createTemp('pin');
  final wallet = Directory('${root.path}/w');
  final protocol = Directory('${root.path}/p');
  await Directory('${wallet.path}/scripts/splits').create(recursive: true);
  await File(
    _script,
  ).copy('${wallet.path}/scripts/splits/check-protocol-pin.sh');
  for (final dir in ['dart', 'splitz_host', 'rust']) {
    await Directory('${protocol.path}/$dir').create(recursive: true);
    await File('${protocol.path}/$dir/f').writeAsString(dir);
  }
  Future<void> git(List<String> args) async {
    final r = await Process.run('git', [
      '-c',
      'user.name=t',
      '-c',
      'user.email=t@t',
      ...args,
    ], workingDirectory: protocol.path);
    expect(r.exitCode, 0, reason: '${r.stderr}');
  }

  await git(['init', '-q']);
  await git(['add', '-A']);
  await git(['commit', '-qm', 'one']);
  final head = await Process.run('git', [
    'rev-parse',
    'HEAD',
  ], workingDirectory: protocol.path);
  await File(
    '${wallet.path}/splitz-protocol.rev',
  ).writeAsString(head.stdout as String);
  return (wallet: wallet, protocol: protocol);
}

Future<int> _check(({Directory wallet, Directory protocol}) t) async =>
    (await Process.run(
      '${t.wallet.path}/scripts/splits/check-protocol-pin.sh',
      const [],
      environment: {'SPLITZ_PROTOCOL_DIR': t.protocol.path},
    )).exitCode;

void main() {
  test('at the pin and clean it passes', () async {
    expect(await _check(await _trees()), 0);
  });

  test('a pin file with trailing space still passes', () async {
    final t = await _trees();
    final pin = File('${t.wallet.path}/splitz-protocol.rev');
    await pin.writeAsString('${(await pin.readAsString()).trim()}  \n');
    expect(await _check(t), 0);
  });

  test('a change outside the linked packages still passes', () async {
    final t = await _trees();
    await File('${t.protocol.path}/rust/f').writeAsString('changed');
    expect(await _check(t), 0);
  });

  test('a commit past the pin is refused', () async {
    final t = await _trees();
    final r = await Process.run('git', [
      '-c',
      'user.name=t',
      '-c',
      'user.email=t@t',
      'commit',
      '-qm',
      'two',
      '--allow-empty',
    ], workingDirectory: t.protocol.path);
    expect(r.exitCode, 0);
    expect(await _check(t), 1);
  });

  test('an uncommitted change under dart/ is refused', () async {
    final t = await _trees();
    await File('${t.protocol.path}/dart/f').writeAsString('changed');
    expect(await _check(t), 1);
  });

  test('an untracked file under splitz_host/ is refused', () async {
    final t = await _trees();
    await File('${t.protocol.path}/splitz_host/new').writeAsString('new');
    expect(await _check(t), 1);
  });

  test('no protocol checkout is refused', () async {
    final t = await _trees();
    await t.protocol.delete(recursive: true);
    expect(await _check(t), 1);
  });
}
