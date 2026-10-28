import 'package:flutter_test/flutter_test.dart';
import 'package:sync_orbit/sync_orbit.dart';

void main() {
  late InMemorySyncStorage storage;

  setUp(() async {
    storage = InMemorySyncStorage();
    await storage.initialize();
  });

  tearDown(() async {
    await storage.dispose();
  });

  group('InMemorySyncStorage', () {
    test('saves, retrieves by ID, and preserves FIFO order by createdAt', () async {
      final now = DateTime.utc(2026, 10, 28, 10, 0, 0);

      final m1 = SyncMutation(
        id: '1',
        endpoint: 'todos',
        action: SyncAction.create,
        payload: {'title': 'First'},
        createdAt: now.add(const Duration(minutes: 5)),
      );

      final m2 = SyncMutation(
        id: '2',
        endpoint: 'todos',
        action: SyncAction.create,
        payload: {'title': 'Second'},
        createdAt: now, // Older -> should be first in FIFO
      );

      await storage.saveMutation(m1);
      await storage.saveMutation(m2);

      final retrieved1 = await storage.getMutation('1');
      expect(retrieved1?.payload['title'], 'First');

      final pending = await storage.getPendingMutations();
      expect(pending.length, 2);
      expect(pending.first.id, '2'); // Oldest first
      expect(pending.last.id, '1');
    });

    test('respects limit in getPendingMutations', () async {
      final now = DateTime.utc(2026, 10, 28, 10, 0, 0);
      for (int i = 0; i < 5; i++) {
        await storage.saveMutation(
          SyncMutation(
            id: '$i',
            endpoint: 'items',
            action: SyncAction.create,
            payload: {'index': i},
            createdAt: now.add(Duration(seconds: i)),
          ),
        );
      }

      final pending = await storage.getPendingMutations(limit: 2);
      expect(pending.length, 2);
      expect(pending.map((m) => m.id).toList(), ['0', '1']);
    });

    test('markCompleted updates mutation status', () async {
      final mutation = SyncMutation(
        id: 'c1',
        endpoint: 'items',
        action: SyncAction.create,
        payload: {'k': 'v'},
      );
      await storage.saveMutation(mutation);

      await storage.markCompleted('c1');

      final updated = await storage.getMutation('c1');
      expect(updated?.status, SyncStatus.completed);
      expect(updated?.lastAttemptedAt, isNotNull);

      final pendingCount = await storage.getPendingCount();
      expect(pendingCount, 0);
    });

    test('markFailed increments retry count and sets lastError', () async {
      final mutation = SyncMutation(
        id: 'f1',
        endpoint: 'items',
        action: SyncAction.create,
        payload: {'k': 'v'},
      );
      await storage.saveMutation(mutation);

      await storage.markFailed('f1', error: 'Connection reset by peer');

      final failed = await storage.getMutation('f1');
      expect(failed?.status, SyncStatus.failed);
      expect(failed?.retryCount, 1);
      expect(failed?.lastError, 'Connection reset by peer');
      expect(failed?.lastAttemptedAt, isNotNull);

      // Failed mutations should still be in getPendingMutations for retry
      final pending = await storage.getPendingMutations();
      expect(pending.length, 1);
      expect(pending.first.id, 'f1');
    });

    test('deleteMutation and clear remove items', () async {
      await storage.saveMutation(
        SyncMutation(endpoint: 'items', action: SyncAction.create, payload: {}),
      );
      expect(await storage.getPendingCount(), 1);

      await storage.clear();
      expect(await storage.getPendingCount(), 0);
    });

    test('throws StateError when used after disposal', () async {
      final tempStorage = InMemorySyncStorage();
      await tempStorage.dispose();

      expect(
        () => tempStorage.saveMutation(SyncMutation(
          endpoint: 'a',
          action: SyncAction.create,
          payload: {},
        )),
        throwsStateError,
      );
    });
  });
}
