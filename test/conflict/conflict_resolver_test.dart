import 'package:flutter_test/flutter_test.dart';
import 'package:sync_orbit/sync_orbit.dart';

void main() {
  group('Conflict Resolvers', () {
    final clientMutation = SyncMutation(
      id: 'mut-1',
      endpoint: 'documents',
      action: SyncAction.update,
      payload: {'title': 'Client Draft', 'version': 2},
      createdAt: DateTime.utc(2026, 10, 28, 12, 0, 0),
    );

    final serverConflict = SyncAdapterConflict(
      serverPayload: {'title': 'Server Document', 'version': 3},
      serverTimestamp: DateTime.utc(2026, 10, 28, 11, 59, 0),
      reason: 'Version mismatch',
    );

    test('ServerWinsResolver always returns serverWins', () {
      const resolver = ServerWinsResolver();
      final resolution = resolver.resolve(
        clientMutation: clientMutation,
        serverConflict: serverConflict,
      );

      expect(resolution, isA<ServerWinsResolution>());
    });

    test('ClientWinsResolver always returns clientWins', () {
      const resolver = ClientWinsResolver();
      final resolution = resolver.resolve(
        clientMutation: clientMutation,
        serverConflict: serverConflict,
      );

      expect(resolution, isA<ClientWinsResolution>());
    });

    test('LastWriteWinsResolver favors client when client is newer', () {
      const resolver = LastWriteWinsResolver();
      // client time is 12:00:00, server time is 11:59:00 -> client wins
      final resolution = resolver.resolve(
        clientMutation: clientMutation,
        serverConflict: serverConflict,
      );

      expect(resolution, isA<ClientWinsResolution>());
    });

    test('LastWriteWinsResolver favors server when server is newer', () {
      const resolver = LastWriteWinsResolver();
      final newerServerConflict = SyncAdapterConflict(
        serverPayload: {'title': 'Server Update'},
        serverTimestamp: DateTime.utc(2026, 10, 28, 12, 05, 0),
      );

      final resolution = resolver.resolve(
        clientMutation: clientMutation,
        serverConflict: newerServerConflict,
      );

      expect(resolution, isA<ServerWinsResolution>());
    });

    test('LastWriteWinsResolver extracts server timestamp from payload if serverTimestamp is null', () {
      const resolver = LastWriteWinsResolver();
      final payloadTimestampConflict = SyncAdapterConflict(
        serverPayload: {
          'title': 'Server Update',
          'updated_at': '2026-10-28T12:05:00.000Z',
        },
      );

      final resolution = resolver.resolve(
        clientMutation: clientMutation,
        serverConflict: payloadTimestampConflict,
      );

      expect(resolution, isA<ServerWinsResolution>());
    });

    test('CustomConflictResolver invokes user defined merge logic', () async {
      final customResolver = CustomConflictResolver(({
        required clientMutation,
        required serverConflict,
      }) {
        final merged = {
          ...serverConflict.serverPayload,
          ...clientMutation.payload,
          'resolved': true,
        };
        return ConflictResolution.merge(merged);
      });

      final resolution = await customResolver.resolve(
        clientMutation: clientMutation,
        serverConflict: serverConflict,
      );

      expect(resolution, isA<MergeResolution>());
      final mergeRes = resolution as MergeResolution;
      expect(mergeRes.mergedPayload['resolved'], isTrue);
      expect(mergeRes.mergedPayload['title'], 'Client Draft');
    });
  });
}
