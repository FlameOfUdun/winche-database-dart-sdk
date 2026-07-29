import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';
import 'package:winche_database/winche_database.dart';

void main() {
  final uri = Uri.parse('ws://fake/documents/ws');

  // NOT CONVERTED — reported to the task owner rather than guessed at.
  //
  // These four tests exercised construction-time validation on the old
  // `WincheDatabase(WincheDatabaseConfig(uri:, namespaceResolver:,
  // directoryResolver:, inMemory:))` factory constructor. None of
  // `uri`/`namespaceResolver`/`directoryResolver` exist on the current
  // `WincheDatabaseConfig` any more (see lib/src/facade/database.dart — it
  // only carries pingInterval/autoReconnect/maxBackoff/maxFrameBytes/
  // inMemory/conflictPolicy/maxCachedDocuments/cacheSizeBytes), and
  // `WincheDatabase` is no longer constructed from a config at all — it is
  // `WincheDatabase(app)`, registered with a `WincheApp`. There is no rename
  // that makes these compile.
  //
  // The validation itself relocated, not just renamed:
  //  - namespace/id validation now happens eagerly in `WincheIdentity`'s
  //    constructor (winche_core/lib/src/models/winche_identity.dart), which
  //    throws ArgumentError for a bad `id` at identity-creation time, not
  //    lazily on first store access via a caller-supplied namespaceResolver
  //    (there isn't one any more — the namespace is always the signed-in
  //    identity's storageKey).
  //  - the directoryResolver-required-on-native check still exists, but now
  //    lives on `WincheOptions` and is checked inside the facade's private
  //    `_storeFor`, reached only through a real `onSessionChanged` dispatch
  //    (i.e. a signed-in identity via a `WincheAuthService`).
  //
  // The test-only seam added by this task (`debugBindStore`) deliberately
  // bypasses identity and `_storeFor` entirely (that is the point of it), so
  // it cannot exercise either path, and standing up a fake auth service here
  // would be new test infrastructure beyond this task's construction/
  // teardown-only mandate. Preserved verbatim as comments (not deleted) so
  // the original assertions stay visible:
  //
  // test('inMemory: true constructs without a directoryResolver', () async {
  //   final db = WincheDatabase(WincheDatabaseConfig(uri: uri, inMemory: true));
  //   await db.close();
  // });
  //
  // test('native default requires a directoryResolver', () {
  //   // On the VM (_kIsWeb == false), omitting directoryResolver throws.
  //   expect(
  //       () => WincheDatabase(WincheDatabaseConfig(
  //           uri: uri, namespaceResolver: () => 'u1')),
  //       throwsArgumentError);
  // });
  //
  // test('a persistent store requires a namespaceResolver', () {
  //   expect(
  //       () => WincheDatabase(WincheDatabaseConfig(
  //           uri: uri, directoryResolver: () async => '/tmp/winche')),
  //       throwsArgumentError);
  // });
  //
  // test('inMemory: true with a directoryResolver throws', () {
  //   expect(
  //     () => WincheDatabase(WincheDatabaseConfig(
  //         uri: uri, inMemory: true, directoryResolver: () async => '/tmp/winche')),
  //     throwsArgumentError,
  //   );
  // });

  test('withStore injects a store directly', () async {
    final db = WincheDatabase(WincheApp('database-ctor'))
      ..debugBindStore(
          ConnectionConfig(uri: uri, autoReconnect: false), MemoryLocalStore());
    await db.dispose();
  });
}
