import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sync_orbit/sync_orbit.dart';

void main() {
  group('SupabaseSyncAdapter - Operations', () {
    test('creates row in PostgREST table via insert and select', () async {
      late http.Request capturedRequest;

      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({'id': 'todo_1', 'title': 'Test Todo', 'completed': false}),
          201,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });

      final supabaseClient = SupabaseClient(
        'https://test.supabase.co',
        'dummy-anon-key',
        httpClient: mockClient,
      );

      final adapter = SupabaseSyncAdapter(client: supabaseClient);

      final mutation = SyncMutation(
        id: 'todo_1',
        endpoint: 'todos',
        action: SyncAction.create,
        payload: {'id': 'todo_1', 'title': 'Test Todo', 'completed': false},
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterSuccess>());
      final success = result as SyncAdapterSuccess;
      expect(success.statusCode, 201);
      expect(success.responseData?['title'], 'Test Todo');

      expect(capturedRequest.method, 'POST');
      expect(capturedRequest.url.path, '/rest/v1/todos');
      expect(jsonDecode(capturedRequest.body), {
        'id': 'todo_1',
        'title': 'Test Todo',
        'completed': false,
      });
    });

    test('updates row in PostgREST table with eq filter on primary key', () async {
      late http.Request capturedRequest;

      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({'id': 'usr_99', 'name': 'Updated User'}),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });

      final supabaseClient = SupabaseClient(
        'https://test.supabase.co',
        'dummy-anon-key',
        httpClient: mockClient,
      );

      final adapter = SupabaseSyncAdapter(
        client: supabaseClient,
        primaryKey: 'id',
      );

      final mutation = SyncMutation(
        id: 'usr_99',
        endpoint: 'users',
        action: SyncAction.update,
        payload: {'id': 'usr_99', 'name': 'Updated User'},
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterSuccess>());
      expect(capturedRequest.method, 'PATCH');
      expect(capturedRequest.url.queryParameters['id'], 'eq.usr_99');
    });

    test('deletes row from PostgREST table', () async {
      late http.Request capturedRequest;

      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          '',
          204,
          request: request,
        );
      });

      final supabaseClient = SupabaseClient(
        'https://test.supabase.co',
        'dummy-anon-key',
        httpClient: mockClient,
      );

      final adapter = SupabaseSyncAdapter(client: supabaseClient);

      final mutation = SyncMutation(
        id: 'del_10',
        endpoint: 'items',
        action: SyncAction.delete,
        payload: {'id': 'del_10'},
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterSuccess>());
      expect((result as SyncAdapterSuccess).statusCode, 204);
      expect(capturedRequest.method, 'DELETE');
      expect(capturedRequest.url.queryParameters['id'], 'eq.del_10');
    });

    test('respects custom schema and dynamic primaryKeyResolver', () async {
      late http.Request capturedRequest;

      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({'uuid': 'custom_123', 'status': 'archived'}),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });

      final supabaseClient = SupabaseClient(
        'https://test.supabase.co',
        'dummy-anon-key',
        httpClient: mockClient,
      );

      final adapter = SupabaseSyncAdapter(
        client: supabaseClient,
        schema: 'custom_schema',
        primaryKeyResolver: (endpoint) => 'uuid',
      );

      final mutation = SyncMutation(
        id: 'custom_123',
        endpoint: 'archive',
        action: SyncAction.update,
        payload: {'uuid': 'custom_123', 'status': 'archived'},
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterSuccess>());
      expect(
        capturedRequest.headers['Content-Profile'] ??
            capturedRequest.headers['content-profile'] ??
            capturedRequest.headers['Accept-Profile'],
        'custom_schema',
      );
      expect(capturedRequest.url.queryParameters['uuid'], 'eq.custom_123');
    });
  });

  group('SupabaseSyncAdapter - Conflict & Error Handling', () {
    test('handles PostgrestException unique violation (23505) as SyncAdapterConflict', () async {
      int callCount = 0;

      final mockClient = MockClient((request) async {
        callCount++;
        if (callCount == 1) {
          // Insert fails with duplicate key
          return http.Response(
            jsonEncode({
              'code': '23505',
              'message': 'duplicate key value violates unique constraint',
              'details': 'Key (id)=(task_1) already exists.',
            }),
            409,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        } else {
          // Fetch existing record returns conflict state
          return http.Response(
            jsonEncode({
              'id': 'task_1',
              'title': 'Existing Task on Remote',
              'updated_at': '2026-10-28T14:30:00.000Z',
            }),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
      });

      final supabaseClient = SupabaseClient(
        'https://test.supabase.co',
        'dummy-anon-key',
        httpClient: mockClient,
      );

      final adapter = SupabaseSyncAdapter(
        client: supabaseClient,
        fetchConflictRecord: true,
      );

      final mutation = SyncMutation(
        id: 'task_1',
        endpoint: 'tasks',
        action: SyncAction.create,
        payload: {'id': 'task_1', 'title': 'Client Task'},
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterConflict>());
      final conflict = result as SyncAdapterConflict;
      expect(conflict.statusCode, 409);
      expect(conflict.serverPayload['title'], 'Existing Task on Remote');
      expect(conflict.serverTimestamp, DateTime.utc(2026, 10, 28, 14, 30, 0));
    });

    test('treats 503 PostgrestException as recoverable failure', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'code': '503',
            'message': 'Database connection pool exhausted',
          }),
          503,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });

      final supabaseClient = SupabaseClient(
        'https://test.supabase.co',
        'dummy-anon-key',
        httpClient: mockClient,
      );

      final adapter = SupabaseSyncAdapter(client: supabaseClient);

      final mutation = SyncMutation(
        endpoint: 'logs',
        action: SyncAction.create,
        payload: {'msg': 'test'},
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterFailure>());
      final failure = result as SyncAdapterFailure;
      expect(failure.isRecoverable, isTrue);
      expect(failure.statusCode, 503);
    });

    test('treats 400 PostgrestException as non-recoverable failure', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'code': '42703',
            'message': 'column "unknown_col" does not exist',
          }),
          400,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      });

      final supabaseClient = SupabaseClient(
        'https://test.supabase.co',
        'dummy-anon-key',
        httpClient: mockClient,
      );

      final adapter = SupabaseSyncAdapter(client: supabaseClient);

      final mutation = SyncMutation(
        endpoint: 'items',
        action: SyncAction.create,
        payload: {'unknown_col': 123},
      );

      final result = await adapter.send(mutation);

      expect(result, isA<SyncAdapterFailure>());
      final failure = result as SyncAdapterFailure;
      expect(failure.isRecoverable, isFalse);
    });
  });
}
