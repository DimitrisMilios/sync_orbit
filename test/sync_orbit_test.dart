import 'package:flutter_test/flutter_test.dart';
import 'package:sync_orbit/sync_orbit.dart';

void main() {
  test('sync_orbit library exports expected core classes', () {
    final storage = InMemorySyncStorage();
    expect(storage, isA<SyncStorage>());

    final mutation = SyncMutation(
      endpoint: 'test',
      action: SyncAction.create,
      payload: {'status': 'ok'},
    );
    expect(mutation.endpoint, 'test');
    expect(mutation.action, SyncAction.create);
  });
}
