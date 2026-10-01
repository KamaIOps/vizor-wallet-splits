// Bills kept before accounts were kept apart, as each account first opens
// the feature.
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:splitz_host/io.dart';
import 'package:splitz_host/splitz_host.dart';
import 'package:zcash_wallet/src/core/storage/wallet_paths.dart';

const bill = 'BILLaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

PendingSend note() => const PendingSend(
  billId: bill,
  uri: 'zcash:ztestsapling1xyz?amount=0.175',
  carried: {'payee': 175000},
  at: '2026-09-30T10:00:00Z',
  txid: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
);

/// The layout one shared store wrote: a bill and an unresolved send note,
/// directly under the splits directory.
Future<void> preFixLayout() async {
  final root = Directory(await getSplitsDirectoryPath());
  final store = BillStore(FileBillStorage(root));
  await store.storage.write('splitz_bill_$bill', '[]');
  final sends = PendingSends(store.storage);
  await sends.begin(note());
  // end() not called: the wallet built the tx and the app died (unresolved).
}

/// The storage the entry screen opens for [account].
Future<BillStore> open(String account) async {
  await adoptLegacySplits(account);
  final dir = Directory(await getSplitsAccountDirectoryPath(account));
  await dir.create(recursive: true);
  return BillStore(FileBillStorage(dir));
}

Future<String> tryPayAgain(BillStore store) async {
  final sends = PendingSends(store.storage);
  try {
    await sends.begin(
      PendingSend(
        billId: bill,
        uri: note().uri,
        carried: note().carried,
        at: '2026-10-01T09:00:00Z',
      ),
    );
    return 'allowed';
  } on SendInFlight {
    return 'refused: SendInFlight';
  }
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('splits_legacy');
    PathProviderPlatform.instance = _Paths(tmp.path);
  });
  tearDown(() => tmp.delete(recursive: true));

  test('the first account to open keeps the send note', () async {
    await preFixLayout();
    final a = await open('acctA');
    expect(await a.billIds(), [bill]);
    expect(await tryPayAgain(a), 'refused: SendInFlight');
  });

  test('another account opening first takes nothing away', () async {
    await preFixLayout();
    final b = await open('acctB');
    final a = await open('acctA');
    expect(await b.billIds(), [bill]);
    expect(await a.billIds(), [bill]);
    expect((await PendingSends(a.storage).of(bill))?.txid, note().txid);
    expect(await tryPayAgain(a), 'refused: SendInFlight');
    expect(await tryPayAgain(b), 'refused: SendInFlight');
  });

  test('an account that has opened before is not adopted into again', () async {
    await preFixLayout();
    final a = await open('acctA');
    await a.forget(bill);
    expect(await a.billIds(), isEmpty);
    final again = await open('acctA');
    expect(await again.billIds(), isEmpty);
  });

  test('an adoption cut short is done again in full', () async {
    await preFixLayout();
    final root = await getSplitsDirectoryPath();
    final staging = Directory('$root/.adopting-acctA');
    await staging.create(recursive: true);
    await File('${staging.path}/partial').writeAsString('x');
    final a = await open('acctA');
    expect(await a.billIds(), [bill]);
    expect(await PendingSends(a.storage).of(bill), isNotNull);
    expect(await staging.exists(), isFalse);
    expect(
      await File(
        '${await getSplitsAccountDirectoryPath('acctA')}/partial',
      ).exists(),
      isFalse,
    );
  });

  test('with nothing kept before, an account starts empty', () async {
    final a = await open('acctA');
    expect(await a.billIds(), isEmpty);
  });
}

class _Paths extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}
