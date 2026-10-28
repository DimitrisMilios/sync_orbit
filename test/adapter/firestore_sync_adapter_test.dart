import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_orbit/sync_orbit.dart';

void main() {
  late FakeFirebaseFirestore fakeFirestore;
  late FirestoreSyncAdapter adapter;

  setUp(() {
    fakeFirestore = FakeFirebaseFirestore();
    adapter = FirestoreSyncAdapter(firestore: fakeFirestore);
  });

  group('FirestoreSyncAdapter - Basic Operations', () {
    test('creates document from collection endpoint using payload ID', () async {
      final mutation = SyncMutation(
        endpoint: 'users',
        action: SyncAction.create,
        payload: {
          'id': 'usr_42',
          'name': 'Grace Hopper',
          'role': 'Pioneer',
        },
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterSuccess>());
      final success = result as SyncAdapterSuccess;
      expect(success.statusCode, 201);

      final snapshot = await fakeFirestore.doc('users/usr_42').get();
      expect(snapshot.exists, isTrue);
      expect(snapshot.data()?['name'], 'Grace Hopper');
    });

    test('creates document using explicit document path endpoint', () async {
      final mutation = SyncMutation(
        endpoint: 'teams/alpha/members/usr_99',
        action: SyncAction.create,
        payload: {'name': 'Alan Turing'},
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterSuccess>());

      final snapshot =
          await fakeFirestore.doc('teams/alpha/members/usr_99').get();
      expect(snapshot.exists, isTrue);
      expect(snapshot.data()?['name'], 'Alan Turing');
    });

    test('updates document with merge semantics preserving other fields', () async {
      // Seed initial document
      await fakeFirestore.doc('users/usr_1').set({
        'name': 'Original Name',
        'email': 'original@example.com',
      });

      final mutation = SyncMutation(
        endpoint: 'users/usr_1',
        action: SyncAction.update,
        payload: {'name': 'Updated Name'},
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterSuccess>());

      final snapshot = await fakeFirestore.doc('users/usr_1').get();
      expect(snapshot.data()?['name'], 'Updated Name');
      expect(snapshot.data()?['email'], 'original@example.com'); // Preserved
    });

    test('updates document using update() method when useMergeSetForUpdate is false', () async {
      final strictAdapter = FirestoreSyncAdapter(
        firestore: fakeFirestore,
        useMergeSetForUpdate: false,
      );

      await fakeFirestore.doc('todos/t1').set({'title': 'Initial'});

      final mutation = SyncMutation(
        endpoint: 'todos/t1',
        action: SyncAction.update,
        payload: {'title': 'Updated Title'},
      );

      final result = await strictAdapter.send(mutation);

      expect(result, isA<SyncAdapterSuccess>());
      final snapshot = await fakeFirestore.doc('todos/t1').get();
      expect(snapshot.data()?['title'], 'Updated Title');
    });

    test('deletes document from path', () async {
      await fakeFirestore.doc('items/del_1').set({'value': 100});

      final mutation = SyncMutation(
        endpoint: 'items',
        action: SyncAction.delete,
        payload: {'id': 'del_1'},
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterSuccess>());
      expect((result as SyncAdapterSuccess).statusCode, 204);

      final snapshot = await fakeFirestore.doc('items/del_1').get();
      expect(snapshot.exists, isFalse);
    });
  });

  group('FirestoreSyncAdapter - Conflicts & Edge Cases', () {
    test('detects conflict on create if document already exists', () async {
      final conflictAdapter = FirestoreSyncAdapter(
        firestore: fakeFirestore,
        detectExistingOnCreateAsConflict: true,
      );

      final now = DateTime.utc(2026, 10, 28, 12, 0, 0);
      await fakeFirestore.doc('notes/n1').set({
        'title': 'Existing Note',
        'updated_at': Timestamp.fromDate(now),
      });

      final mutation = SyncMutation(
        endpoint: 'notes/n1',
        action: SyncAction.create,
        payload: {'title': 'New Conflicting Note'},
      );

      final result = await conflictAdapter.send(mutation);

      expect(result, isA<SyncAdapterConflict>());
      final conflict = result as SyncAdapterConflict;
      expect(conflict.serverPayload['title'], 'Existing Note');
      expect(conflict.serverTimestamp, now);
      expect(conflict.reason, contains('already exists'));
    });
  });
}
