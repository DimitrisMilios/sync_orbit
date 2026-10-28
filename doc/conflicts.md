# Conflict Resolution Strategies & Distributed Consistency

In offline-first systems, conflicts are an inevitable consequence of distributed autonomy: two or more devices modify the same entity concurrently without real-time coordination.

---

## 1. Conflict Mechanics

A conflict occurs when:
1. Client A fetches record version $V_1$ at timestamp $T_1$.
2. Client A goes offline and updates the record locally to $V_2$ at $T_2$.
3. Concurrently, Client B updates the remote record to $V_3$ at $T_3$.
4. Client A reconnects and attempts to apply $V_2$ to the remote server.

The server detects a version mismatch and returns a conflict response (typically HTTP 409 or 412).

```
Client A:    [V1] ───(Offline)───> [V2 @ T2] ───────────────> SyncAttempt(V2) ───┐
                                                                                 ├──> CONFLICT!
Remote DB:   [V1] ───(Client B updates)───> [V3 @ T3] ───────────────────────────┘
```

The `SyncEngine` delegates this collision to the configured `ConflictResolver`.

---

## 2. Built-in Resolvers

### Last-Write-Wins (`LastWriteWinsResolver`)

The most common strategy in mobile and collaborative apps. Compares the client's mutation timestamp with the server's record timestamp.

```dart
const resolver = LastWriteWinsResolver();
```

- If `clientTime >= serverTime`: Returns `ConflictResolution.clientWins()`. The engine re-dispatches the mutation with `metadata['forceWrite'] = true`.
- If `serverTime > clientTime`: Returns `ConflictResolution.serverWins()`. The engine accepts the server's state and prunes the local mutation.

#### Clock Drift Mitigation
Mobile device clocks can drift or be intentionally manipulated by users. To safeguard LWW:
1. Prefer extracting server timestamps from server payloads or HTTP response headers:
```dart
final resolver = LastWriteWinsResolver(
  serverTimestampExtractor: (payload) =>
      DateTime.tryParse(payload['updated_at'] ?? ''),
);
```
2. When available, synchronize local time with TrueTime or NTP servers on app launch.

---

### Server Wins (`ServerWinsResolver`)

The remote server is treated as the absolute source of truth. Any conflicting local mutations are discarded or superseded.

```dart
const resolver = ServerWinsResolver();
```

**Use cases**:
- Financial transactions, seat reservations, inventory checks.
- Server-authoritative state where client modifications cannot override central business rules.

---

### Client Wins (`ClientWinsResolver`)

The client's write unconditionally overrides remote modifications.

```dart
const resolver = ClientWinsResolver();
```

**Use cases**:
- Single-user offline personal notes or journal entries.
- Draft saving where the active device represents the user's latest focus.

---

## 3. Field-Level & 3-Way Custom Merges

For complex JSON documents, whole-record overwrite strategies (LWW/Server/Client) cause data loss if Client A updated field `X` and Client B updated field `Y`.

`CustomConflictResolver` allows programmatic field-level merging:

```dart
final customResolver = CustomConflictResolver(({
  required clientMutation,
  required serverConflict,
}) {
  final clientData = clientMutation.payload;
  final serverData = serverConflict.serverPayload;

  // Field-by-field merge
  final merged = <String, dynamic>{
    ...serverData, // Start with server baseline
    ...clientData, // Overlay client changes
  };

  // Special handling for tags / arrays: union set
  if (clientData['tags'] is List && serverData['tags'] is List) {
    final clientTags = Set<String>.from(clientData['tags'] as List);
    final serverTags = Set<String>.from(serverData['tags'] as List);
    merged['tags'] = clientTags.union(serverTags).toList();
  }

  // Update revision counter
  merged['revision'] = ((serverData['revision'] as int? ?? 0) + 1);
  merged['updated_at'] = DateTime.now().toUtc().toIso8601String();

  return ConflictResolution.merge(merged);
});
```

When `ConflictResolution.merge(mergedPayload)` is returned:
1. `SyncEngine` updates the mutation's payload in local storage.
2. The engine immediately dispatches the combined payload back to the remote adapter.
3. If the merge succeeds, the mutation is marked completed.
