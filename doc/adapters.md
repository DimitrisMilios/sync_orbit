# Remote Sync Adapters Guide

The `SyncAdapter` interface isolates the `SyncEngine` from network protocols, authentication mechanisms, and vendor SDKs.

---

## 1. `RestSyncAdapter`

The `RestSyncAdapter` dispatches mutations via standard HTTP calls using `package:http`.

### Configuration Options

```dart
final adapter = RestSyncAdapter(
  baseUrl: 'https://api.myapp.com/v1',
  
  // Dynamic header provider (e.g. fresh OAuth token)
  headersProvider: () async {
    final token = await authManager.getValidBearerToken();
    return {
      'Authorization': 'Bearer $token',
      'X-Client-Version': '1.0.0',
    };
  },
  
  // Custom timeout (defaults to 30s)
  timeout: const Duration(seconds: 20),
  
  // Appends '/{id}' to URL path on PUT, PATCH, DELETE (defaults to true)
  appendIdOnUpdateAndDelete: true,
  
  // Use PATCH instead of PUT for updates (defaults to false)
  usePatchForUpdate: true,
  
  // Custom status code sets
  conflictStatusCodes: {409, 412},
  recoverableStatusCodes: {408, 429, 500, 502, 503, 504},
);
```

### URL Resolution Matrix

By default, the adapter builds the request URI based on `mutation.endpoint` and `mutation.action`:

| Action | Endpoint | Payload | Generated URL | HTTP Method |
|---|---|---|---|---|
| `create` | `todos` | `{"title": "Groceries"}` | `https://api.myapp.com/v1/todos` | `POST` |
| `update` | `todos` | `{"id": "42", "title": "Buy milk"}` | `https://api.myapp.com/v1/todos/42` | `PUT` or `PATCH` |
| `delete` | `todos` | `{"id": "42"}` | `https://api.myapp.com/v1/todos/42` | `DELETE` |
| `update` | `todos/42` | `{"title": "Buy milk"}` | `https://api.myapp.com/v1/todos/42` | `PUT` or `PATCH` |

### Custom URL Routing
For nested endpoints or non-RESTful routes, supply `urlResolver`:

```dart
final adapter = RestSyncAdapter(
  baseUrl: 'https://api.myapp.com',
  urlResolver: (mutation, baseUri) {
    if (mutation.endpoint == 'organization_members') {
      final orgId = mutation.payload['org_id'];
      final memberId = mutation.payload['member_id'];
      return Uri.parse('$baseUri/organizations/$orgId/members/$memberId');
    }
    return Uri.parse('$baseUri/${mutation.endpoint}');
  },
);
```

---

## 2. `SupabaseSyncAdapter`

The `SupabaseSyncAdapter` integrates with `supabase_flutter` to apply mutations directly to PostgREST tables.

### Configuration

```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sync_orbit/sync_orbit.dart';

final supabaseAdapter = SupabaseSyncAdapter(
  client: Supabase.instance.client,
  
  // Optional database schema (defaults to null / public)
  schema: 'public',
  
  // Default primary key column name (defaults to 'id')
  primaryKey: 'id',
  
  // Dynamic primary key resolution for composite or non-standard tables
  primaryKeyResolver: (endpoint) {
    if (endpoint == 'order_items') return 'item_id';
    return 'id';
  },
  
  // When a duplicate key error (23505) occurs, automatically query
  // the existing remote row to provide full state to ConflictResolver
  fetchConflictRecord: true,
);
```

### How Supabase Errors are Handled

1. **Unique Violation (`23505` or HTTP `409`)**:
   PostgREST returns a conflict error. The adapter queries the table to obtain the conflicting server record and timestamp, packaging it into `SyncAdapterConflict`.
2. **Transient Network Errors (`503`, Pool Exhausted, Socket Timeouts)**:
   Classified as `SyncAdapterFailure(isRecoverable: true)`. The mutation retry count is incremented, and exponential backoff triggers.
3. **Row-Level Security (RLS) Violations (`42501`)**:
   Classified as `isRecoverable: false` to prevent endless retry loops on authorization rejections.

---

## 3. `FirestoreSyncAdapter`

The `FirestoreSyncAdapter` writes mutations directly to Google Cloud Firestore via `package:cloud_firestore`.

### Configuration

```dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:sync_orbit/sync_orbit.dart';

final firestoreAdapter = FirestoreSyncAdapter(
  firestore: FirebaseFirestore.instance,
  
  // If true, uses set(payload, SetOptions(merge: true)) for updates.
  // Prevents 'not-found' exceptions when updating documents that were
  // created locally while offline.
  useMergeSetForUpdate: true,
  
  // If true, checks if a document exists before CREATE.
  // Returns SyncAdapterConflict if it exists.
  detectExistingOnCreateAsConflict: true,
);
```

### Endpoint Path Format

`FirestoreSyncAdapter` automatically handles both collection paths and explicit document paths:

```dart
// 1. Collection Path: document ID is extracted from payload['id'] or mutation.id
syncEngine.queue(
  endpoint: 'users',
  action: SyncAction.create,
  payload: {'id': 'usr_99', 'name': 'Sarah'},
);
// Resolves to: firestore.collection('users').doc('usr_99')

// 2. Explicit Document Path:
syncEngine.queue(
  endpoint: 'projects/p123/tasks/t456',
  action: SyncAction.update,
  payload: {'status': 'in_progress'},
);
// Resolves to: firestore.doc('projects/p123/tasks/t456')
```

---

## 4. Authoring a Custom Adapter (e.g. GraphQL)

Implementing custom protocols requires only implementing the `SyncAdapter` interface:

```dart
import 'package:graphql/client.dart';
import 'package:sync_orbit/sync_orbit.dart';

class GraphQLSyncAdapter implements SyncAdapter {
  final GraphQLClient client;

  GraphQLSyncAdapter(this.client);

  @override
  Future<SyncAdapterResult> send(SyncMutation mutation) async {
    try {
      final doc = gql(mutation.payload['query'] as String);
      final variables = mutation.payload['variables'] as Map<String, dynamic>? ?? {};

      final result = await client.mutate(
        MutationOptions(document: doc, variables: variables),
      );

      if (result.hasException) {
        final error = result.exception!;
        return SyncAdapterFailure(
          error: error.toString(),
          isRecoverable: error.linkException != null, // Link errors are network/retryable
        );
      }

      return SyncAdapterSuccess(
        statusCode: 200,
        responseData: result.data,
      );
    } catch (e) {
      return SyncAdapterFailure(error: e.toString(), isRecoverable: true);
    }
  }
}
```
