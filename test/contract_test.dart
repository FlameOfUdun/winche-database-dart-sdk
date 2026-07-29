import 'package:test/test.dart';
import 'package:winche_core/testing.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  test('WincheDatabase honours the winche_core service contract', () async {
    final report = await WincheServiceContract.check(
      create: WincheDatabase.new,
      sessionHandle: (service) => (service as WincheDatabase).debugSession,
      // An endpoint is required or onSessionChanged throws. The socket is never
      // dialled during the run, because construction is lazy.
      //
      // A `directoryResolver` is supplied too: with `inMemory` false (the
      // default) and no resolver, `_storeFor` throws synchronously the moment
      // an identity is announced, before a session is even built. The resolver
      // is never actually invoked here — the store it configures is a
      // `LazyLocalStore`, and the contract never issues a read or write, so
      // the directory is never touched and nothing hits disk.
      options: WincheOptions(
        databaseEndpoint: Uri.parse('ws://localhost:1/ws'),
        directoryResolver: () async => '/winche-contract-test',
      ),
    );
    expect(report.isSuccess, isTrue, reason: report.toString());
  });
}
