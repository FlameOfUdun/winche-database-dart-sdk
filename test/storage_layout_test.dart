import 'package:test/test.dart';
import 'package:winche_core/winche_core.dart';
// `storeDirectoryFor` and `webDatabaseNameFor` are declared in
// `lib/src/facade/database.dart`, but that file is a `part of
// '../../winche_database.dart'` — it has no library URI of its own to import.
// Top-level declarations in a part become part of the enclosing library's
// public API (Dart privacy is per-library, keyed on the leading underscore,
// not per-file), so both functions are already reachable through the main
// library import below; no separate export is needed.
import 'package:winche_database/winche_database.dart';

void main() {
  // winche_core 0.2.0 made `storageKey` a 128-bit SHA-256 digest of the id,
  // rendered as 32 lowercase hex characters. These assertions deliberately do
  // not spell that digest out: recomputing the algorithm here would only
  // prove this test agrees with itself. Core pins the exact value against an
  // independently computed vector. What matters *here* is that the layout is
  // built from `storageKey` rather than from `id`.
  final key = RegExp(r'^[0-9a-f]{32}$');

  test('the store lives in a per-package subdirectory of a per-identity root',
      () {
    // The stack-wide layout: <root>/winche/<storageKey>/<package>. Every
    // Winche package shares the identity directory and takes one subdirectory
    // beneath it, so forgetting a user is a single recursive delete of
    // <root>/winche/<storageKey> that takes database *and* storage with it.
    final directory = storeDirectoryFor('/root', WincheIdentity('alice'));
    final parts = directory.split('/');

    expect(directory, startsWith('/root/winche/'));
    expect(parts.last, 'database');
    expect(
      parts[parts.length - 2],
      matches(key),
      reason: 'the identity segment sits directly above the package segment',
    );
  });

  test('the store file matches winche_storage: index.db', () {
    // sembast appends the extension, so the name here is extension-free.
    expect(storeFileName, 'index');
  });

  test('the store path is scoped by storageKey, not by the raw id', () {
    expect(
      storeDirectoryFor('/root', WincheIdentity('alice')),
      isNot(contains('alice')),
      reason: 'a raw id in the path is the pre-0.2.0 behaviour — it writes '
          'the user id onto disk, and a case-insensitive filesystem can '
          'collapse two of them together',
    );
  });

  test('two identities get two directories', () {
    expect(
      storeDirectoryFor('/root', WincheIdentity('alice')),
      isNot(storeDirectoryFor('/root', WincheIdentity('bob'))),
    );
  });

  test('ids differing only in case do not collide', () {
    // Used raw, these are one directory on NTFS and default macOS APFS, so
    // one user would read the other's cache.
    final upper = storeDirectoryFor('/root', WincheIdentity('User1'));
    final lower = storeDirectoryFor('/root', WincheIdentity('user1'));

    expect(upper, isNot(lower));
    // The stronger claim: still distinct *after* the filesystem folds case.
    expect(upper.toLowerCase(), isNot(lower.toLowerCase()));
  });

  test('an id that is not filesystem-safe still yields a usable path', () {
    // Rejected outright before 0.2.0 — core would not even construct the
    // identity. The digest absorbs any id shape, so a backend issuing emails
    // or distinguished names can now be signed in at all.
    for (final id in ['user@example.com', 'cn=alice,ou=people', 'a/b']) {
      expect(
        storeDirectoryFor('/root', WincheIdentity(id)),
        '/root/winche/${WincheIdentity(id).storageKey}/database',
      );
    }
  });

  test('two packages under one identity do not collide', () {
    // What the layout buys: the identity directory is shared, the leaf is
    // not. Pinned with a literal `storage` segment rather than a reference to
    // winche_storage, which this package must not depend on.
    final identity = WincheIdentity('alice');
    final database = storeDirectoryFor('/root', identity);
    final storage = '/root/winche/${identity.storageKey}/storage';

    expect(database, isNot(storage));
    expect(
      database.substring(0, database.lastIndexOf('/')),
      storage.substring(0, storage.lastIndexOf('/')),
      reason: 'both packages must sit under the same per-identity directory, '
          'or forgetting a user takes more than one delete',
    );
  });

  test('the path is stable across calls, so a restart finds the same store',
      () {
    expect(
      storeDirectoryFor('/root', WincheIdentity('alice')),
      storeDirectoryFor('/root', WincheIdentity('alice')),
    );
  });

  test('the web database name carries the same three parts, flattened', () {
    // IndexedDB has no directories, so scope/identity/package become one name.
    final identity = WincheIdentity('alice');
    final name = webDatabaseNameFor(identity);

    expect(name, 'winche_${identity.storageKey}_database');
    expect(name, isNot(contains('alice')));
    expect(
      webDatabaseNameFor(WincheIdentity('User1')),
      isNot(webDatabaseNameFor(WincheIdentity('user1'))),
    );
  });
}
