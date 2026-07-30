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
  test('two identities get two directories', () {
    expect(
      storeDirectoryFor('/root', WincheIdentity('alice')),
      isNot(storeDirectoryFor('/root', WincheIdentity('bob'))),
    );
    expect(storeDirectoryFor('/root', WincheIdentity('alice')), '/root/winche/alice');
  });

  test('ids differing only in case do not collide', () {
    // On NTFS and default macOS APFS these are one directory.
    expect(
      storeDirectoryFor('/root', WincheIdentity('User1')),
      isNot(storeDirectoryFor('/root', WincheIdentity('user1'))),
    );
  });

  test('the web database name is scoped the same way', () {
    expect(webDatabaseNameFor(WincheIdentity('alice')), 'winche_alice');
    expect(
      webDatabaseNameFor(WincheIdentity('User1')),
      isNot(webDatabaseNameFor(WincheIdentity('user1'))),
    );
  });
}
