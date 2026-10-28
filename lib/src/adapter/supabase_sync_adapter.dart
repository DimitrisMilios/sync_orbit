import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/sync_action.dart';
import '../models/sync_mutation.dart';
import 'sync_adapter.dart';
import 'sync_adapter_result.dart';

/// Function determining the primary key column name for a given table [endpoint].
typedef TablePrimaryKeyResolver = String Function(String endpoint);

/// A production-ready [SyncAdapter] targeting Supabase PostgREST tables.
///
/// Applies [SyncMutation] operations directly to Supabase tables:
/// - [SyncAction.create] -> `insert()`
/// - [SyncAction.update] -> `update().eq(primaryKey, id)`
/// - [SyncAction.delete] -> `delete().eq(primaryKey, id)`
class SupabaseSyncAdapter implements SyncAdapter {
  /// The [SupabaseClient] instance used to execute database operations.
  final SupabaseClient client;

  /// Optional database schema (e.g. `'public'`). If null, the default schema is used.
  final String? schema;

  /// Primary key column name or dynamic resolver per table endpoint.
  ///
  /// Defaults to resolving `'id'`.
  final TablePrimaryKeyResolver primaryKeyResolver;

  /// Whether to fetch the latest server record when a conflict is encountered.
  ///
  /// Defaults to `true`.
  final bool fetchConflictRecord;

  /// Creates a [SupabaseSyncAdapter].
  SupabaseSyncAdapter({
    required this.client,
    this.schema,
    String? primaryKey,
    TablePrimaryKeyResolver? primaryKeyResolver,
    this.fetchConflictRecord = true,
  }) : primaryKeyResolver = primaryKeyResolver ??
            ((_) => primaryKey ?? 'id');

  PostgrestQueryBuilder _table(String endpoint) {
    if (schema != null) {
      return client.schema(schema!).from(endpoint);
    }
    return client.from(endpoint);
  }

  @override
  Future<SyncAdapterResult> send(SyncMutation mutation) async {
    final pk = primaryKeyResolver(mutation.endpoint);
    final idValue = mutation.payload[pk] ?? mutation.id;

    try {
      switch (mutation.action) {
        case SyncAction.create:
          final response = await _table(mutation.endpoint)
              .insert(mutation.payload)
              .select()
              .maybeSingle();

          return SyncAdapterSuccess(
            statusCode: 201,
            responseData: response,
          );

        case SyncAction.update:
          final response = await _table(mutation.endpoint)
              .update(mutation.payload)
              .eq(pk, idValue)
              .select()
              .maybeSingle();

          return SyncAdapterSuccess(
            statusCode: 200,
            responseData: response,
          );

        case SyncAction.delete:
          await _table(mutation.endpoint).delete().eq(pk, idValue);

          return const SyncAdapterSuccess(
            statusCode: 204,
          );
      }
    } on PostgrestException catch (e) {
      // 23505 = unique_violation, 409 = Conflict
      if (e.code == '23505' || e.code == '409') {
        Map<String, dynamic>? serverData;
        if (fetchConflictRecord) {
          try {
            serverData = await _table(mutation.endpoint)
                .select()
                .eq(pk, idValue)
                .maybeSingle();
          } catch (_) {}
        }

        DateTime? serverTimestamp;
        if (serverData != null) {
          final ts = serverData['updated_at'] ??
              serverData['updatedAt'] ??
              serverData['timestamp'];
          if (ts is String) {
            serverTimestamp = DateTime.tryParse(ts)?.toUtc();
          }
        }

        return SyncAdapterConflict(
          serverPayload: serverData ?? {},
          serverTimestamp: serverTimestamp,
          statusCode: 409,
          reason: e.message,
        );
      }

      final isRecoverable = e.code == '503' ||
          e.code == '502' ||
          e.code == '504' ||
          e.message.toLowerCase().contains('connection') ||
          e.message.toLowerCase().contains('timeout');

      return SyncAdapterFailure(
        error: 'PostgrestException (${e.code}): ${e.message}',
        statusCode: int.tryParse(e.code ?? ''),
        isRecoverable: isRecoverable,
      );
    } on SocketException catch (e) {
      return SyncAdapterFailure(
        error: 'Network connection failed: ${e.message}',
        isRecoverable: true,
      );
    } on TimeoutException catch (e) {
      return SyncAdapterFailure(
        error: 'Supabase operation timed out: ${e.message ?? e}',
        isRecoverable: true,
      );
    } catch (e) {
      return SyncAdapterFailure(
        error: 'Unexpected Supabase error: $e',
        isRecoverable: false,
      );
    }
  }
}
