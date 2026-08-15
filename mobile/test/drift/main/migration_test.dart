// dart format width=80
// ignore_for_file: unused_local_variable, unused_import
import 'package:drift/drift.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

import 'generated/schema.dart';
import 'generated/schema_v1.dart' as v1;
import 'generated/schema_v2.dart' as v2;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  group('simple database migrations', () {
    // These simple tests verify all possible schema updates with a simple (no
    // data) migration. This is a quick way to ensure that written database
    // migrations properly alter the schema.
    const versions = GeneratedHelper.versions;
    for (final (i, fromVersion) in versions.indexed) {
      group('from $fromVersion', () {
        for (final toVersion in versions.skip(i + 1)) {
          test('to $toVersion', () async {
            final schema = await verifier.schemaAt(fromVersion);
            final db = Drift(schema.newConnection());
            await verifier.migrateAndValidate(db, toVersion);
            await db.close();
          });
        }
      });
    }
  });

  test('v31 migration backfills local timeline wall-clock times', () async {
    final schema = await verifier.schemaAt(31);
    schema.rawDatabase.execute(
      '''
      INSERT INTO local_asset_entity (id, name, type, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?)
    ''',
      [
        'local-timezone-asset',
        'photo.jpg',
        1,
        '2024-01-01T22:30:00.000Z',
        '2024-01-01T22:30:00.000Z',
      ],
    );
    final db = Drift(schema.newConnection());

    await verifier.migrateAndValidate(db, 32);

    final row = await db
        .customSelect(
          'SELECT created_at, local_date_time FROM local_asset_entity WHERE id = ?',
          variables: [const Variable('local-timezone-asset')],
        )
        .getSingle();
    expect(row.read<String>('created_at'), '2024-01-01T22:30:00.000Z');
    expect(row.read<String?>('local_date_time'), isA<String>());
    await db.close();
  });
}
