import 'package:flutter_test/flutter_test.dart';
import 'package:sync_orbit/sync_orbit.dart';

void main() {
  group('SyncAction & SyncStatus', () {
    test('SyncAction fromString parses valid values', () {
      expect(SyncAction.fromString('create'), SyncAction.create);
      expect(SyncAction.fromString('UPDATE'), SyncAction.update);
      expect(SyncAction.fromString('delete'), SyncAction.delete);
    });

    test('SyncAction tryFromString handles null and invalid', () {
      expect(SyncAction.tryFromString(null), isNull);
      expect(SyncAction.tryFromString('unknown'), isNull);
      expect(SyncAction.tryFromString('create'), SyncAction.create);
    });

    test('SyncStatus fromString parses valid values', () {
      expect(SyncStatus.fromString('pending'), SyncStatus.pending);
      expect(SyncStatus.fromString('INFLIGHT'), SyncStatus.inFlight);
      expect(SyncStatus.fromString('failed'), SyncStatus.failed);
      expect(SyncStatus.fromString('completed'), SyncStatus.completed);
    });
  });

  group('SyncMutation', () {
    test('instantiates with defaults', () {
      final mutation = SyncMutation(
        endpoint: 'users',
        action: SyncAction.create,
        payload: {'name': 'Alice'},
      );

      expect(mutation.id, isNotEmpty);
      expect(mutation.endpoint, 'users');
      expect(mutation.action, SyncAction.create);
      expect(mutation.payload['name'], 'Alice');
      expect(mutation.retryCount, 0);
      expect(mutation.status, SyncStatus.pending);
      expect(mutation.createdAt.isUtc, isTrue);
      expect(mutation.lastAttemptedAt, isNull);
      expect(mutation.lastError, isNull);
    });

    test('serializes and deserializes to/from map and JSON', () {
      final now = DateTime.utc(2026, 10, 28, 12, 0, 0);
      final mutation = SyncMutation(
        id: 'mut-123',
        endpoint: 'posts',
        action: SyncAction.update,
        payload: {'title': 'Offline-first Dart'},
        createdAt: now,
        retryCount: 2,
        status: SyncStatus.failed,
        lastAttemptedAt: now.add(const Duration(seconds: 30)),
        lastError: 'HTTP 503 Service Unavailable',
        metadata: {'authorId': 'auth-99'},
      );

      final map = mutation.toMap();
      final revived = SyncMutation.fromMap(map);

      expect(revived.id, mutation.id);
      expect(revived.endpoint, mutation.endpoint);
      expect(revived.action, mutation.action);
      expect(revived.payload, mutation.payload);
      expect(revived.createdAt, mutation.createdAt);
      expect(revived.retryCount, 2);
      expect(revived.status, SyncStatus.failed);
      expect(revived.lastAttemptedAt, mutation.lastAttemptedAt);
      expect(revived.lastError, mutation.lastError);
      expect(revived.metadata, mutation.metadata);
      expect(revived, equals(mutation));
    });

    test('copyWith produces modified copy preserving unmodified fields', () {
      final mutation = SyncMutation(
        id: 'mut-1',
        endpoint: 'items',
        action: SyncAction.delete,
        payload: {'id': 42},
      );

      final updated = mutation.copyWith(
        status: SyncStatus.completed,
        retryCount: 1,
      );

      expect(updated.id, 'mut-1');
      expect(updated.endpoint, 'items');
      expect(updated.action, SyncAction.delete);
      expect(updated.payload, {'id': 42});
      expect(updated.status, SyncStatus.completed);
      expect(updated.retryCount, 1);
    });
  });
}
