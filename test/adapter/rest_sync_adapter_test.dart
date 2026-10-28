import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sync_orbit/sync_orbit.dart';

void main() {
  group('RestSyncAdapter - Requests & Methods', () {
    test('dispatches POST for SyncAction.create with payload and headers', () async {
      late http.Request capturedRequest;

      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({'id': 'item-1', 'title': 'Test Item'}),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      final adapter = RestSyncAdapter(
        baseUrl: 'https://api.example.com/v1',
        headersProvider: () => {'Authorization': 'Bearer test-token-123'},
        client: mockClient,
      );

      final mutation = SyncMutation(
        id: 'item-1',
        endpoint: 'items',
        action: SyncAction.create,
        payload: {'title': 'Test Item'},
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterSuccess>());
      final success = result as SyncAdapterSuccess;
      expect(success.statusCode, 201);
      expect(success.responseData?['title'], 'Test Item');

      expect(capturedRequest.method, 'POST');
      expect(capturedRequest.url.toString(), 'https://api.example.com/v1/items');
      expect(capturedRequest.headers['Authorization'], 'Bearer test-token-123');
      expect(capturedRequest.headers['Content-Type'], 'application/json');
      expect(jsonDecode(capturedRequest.body), {'title': 'Test Item'});
    });

    test('dispatches PUT for SyncAction.update with ID appended to URL', () async {
      late http.Request capturedRequest;

      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({'id': '42', 'title': 'Updated Title'}),
          200,
        );
      });

      final adapter = RestSyncAdapter(
        baseUrl: 'https://api.example.com/v1',
        client: mockClient,
        appendIdOnUpdateAndDelete: true,
      );

      final mutation = SyncMutation(
        id: 'mut-42',
        endpoint: 'posts',
        action: SyncAction.update,
        payload: {'id': '42', 'title': 'Updated Title'},
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterSuccess>());
      expect(capturedRequest.method, 'PUT');
      expect(capturedRequest.url.toString(), 'https://api.example.com/v1/posts/42');
    });

    test('dispatches PATCH for SyncAction.update when usePatchForUpdate is true', () async {
      late http.Request capturedRequest;

      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response('{"status": "ok"}', 200);
      });

      final adapter = RestSyncAdapter(
        baseUrl: 'https://api.example.com',
        client: mockClient,
        usePatchForUpdate: true,
      );

      final mutation = SyncMutation(
        id: 'item-99',
        endpoint: 'items/item-99',
        action: SyncAction.update,
        payload: {'status': 'active'},
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterSuccess>());
      expect(capturedRequest.method, 'PATCH');
      expect(capturedRequest.url.toString(), 'https://api.example.com/items/item-99');
    });

    test('dispatches DELETE for SyncAction.delete', () async {
      late http.Request capturedRequest;

      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response('', 204);
      });

      final adapter = RestSyncAdapter(
        baseUrl: 'https://api.example.com',
        client: mockClient,
      );

      final mutation = SyncMutation(
        id: 'del-1',
        endpoint: 'todos',
        action: SyncAction.delete,
        payload: {'id': 'del-1'},
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterSuccess>());
      expect((result as SyncAdapterSuccess).statusCode, 204);
      expect(capturedRequest.method, 'DELETE');
      expect(capturedRequest.url.toString(), 'https://api.example.com/todos/del-1');
    });

    test('uses custom urlResolver when provided', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.toString(), 'https://custom.api.com/custom/route');
        return http.Response('{}', 200);
      });

      final adapter = RestSyncAdapter(
        baseUrl: 'https://ignored.com',
        client: mockClient,
        urlResolver: (mutation, baseUri) =>
            Uri.parse('https://custom.api.com/custom/route'),
      );

      final mutation = SyncMutation(
        endpoint: 'any',
        action: SyncAction.create,
        payload: {},
      );

      final result = await adapter.send(mutation);
      expect(result, isA<SyncAdapterSuccess>());
    });
  });

  group('RestSyncAdapter - Conflict & Error Handling', () {
    test('returns SyncAdapterConflict on HTTP 409 with body timestamp', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'message': 'Version mismatch',
            'version': 5,
            'updated_at': '2026-10-28T14:00:00.000Z',
          }),
          409,
        );
      });

      final adapter = RestSyncAdapter(
        baseUrl: 'https://api.example.com',
        client: mockClient,
      );

      final mutation = SyncMutation(
        endpoint: 'docs',
        action: SyncAction.update,
        payload: {'version': 4},
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterConflict>());
      final conflict = result as SyncAdapterConflict;
      expect(conflict.statusCode, 409);
      expect(conflict.reason, 'Version mismatch');
      expect(conflict.serverPayload['version'], 5);
      expect(
        conflict.serverTimestamp,
        DateTime.utc(2026, 10, 28, 14, 0, 0),
      );
    });

    test('returns SyncAdapterConflict on HTTP 412 parsing HTTP Date header', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({'error': 'Precondition Failed'}),
          412,
          headers: {'date': 'Wed, 28 Oct 2026 14:05:00 GMT'},
        );
      });

      final adapter = RestSyncAdapter(
        baseUrl: 'https://api.example.com',
        client: mockClient,
      );

      final mutation = SyncMutation(
        endpoint: 'items',
        action: SyncAction.update,
        payload: {},
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterConflict>());
      final conflict = result as SyncAdapterConflict;
      expect(conflict.statusCode, 412);
      expect(conflict.serverTimestamp, DateTime.utc(2026, 10, 28, 14, 5, 0));
    });

    test('returns unrecoverable SyncAdapterFailure on HTTP 400', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({'error': 'Bad Request: invalid payload'}),
          400,
        );
      });

      final adapter = RestSyncAdapter(
        baseUrl: 'https://api.example.com',
        client: mockClient,
      );

      final mutation = SyncMutation(
        endpoint: 'items',
        action: SyncAction.create,
        payload: {},
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterFailure>());
      final failure = result as SyncAdapterFailure;
      expect(failure.statusCode, 400);
      expect(failure.isRecoverable, isFalse);
      expect(failure.error, contains('Bad Request'));
    });

    test('returns recoverable SyncAdapterFailure on HTTP 503', () async {
      final mockClient = MockClient((request) async {
        return http.Response('Service Unavailable', 503);
      });

      final adapter = RestSyncAdapter(
        baseUrl: 'https://api.example.com',
        client: mockClient,
      );

      final mutation = SyncMutation(
        endpoint: 'orders',
        action: SyncAction.create,
        payload: {},
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterFailure>());
      final failure = result as SyncAdapterFailure;
      expect(failure.statusCode, 503);
      expect(failure.isRecoverable, isTrue);
    });

    test('returns recoverable SyncAdapterFailure on ClientException or SocketException', () async {
      final mockClient = MockClient((request) async {
        throw const SocketException('Connection refused');
      });

      final adapter = RestSyncAdapter(
        baseUrl: 'https://api.example.com',
        client: mockClient,
      );

      final mutation = SyncMutation(
        endpoint: 'orders',
        action: SyncAction.create,
        payload: {},
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterFailure>());
      final failure = result as SyncAdapterFailure;
      expect(failure.isRecoverable, isTrue);
      expect(failure.error, contains('Connection refused'));
    });
  });
}
