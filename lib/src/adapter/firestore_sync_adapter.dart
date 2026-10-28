import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/sync_action.dart';
import '../models/sync_mutation.dart';
import 'sync_adapter.dart';
import 'sync_adapter_result.dart';

/// A production-ready [SyncAdapter] targeting Cloud Firestore documents.
///
/// Dispatches [SyncMutation] operations directly to Cloud Firestore:
/// - [SyncAction.create] -> `set()`
/// - [SyncAction.update] -> `update()` or `set(..., SetOptions(merge: true))`
/// - [SyncAction.delete] -> `delete()`
///
/// Supports both explicit document paths (e.g. `'users/usr_1'`) and collection
/// endpoints (e.g. `'users'`), automatically deriving the document path using
/// `mutation.payload['id'] ?? mutation.id`.
class FirestoreSyncAdapter implements SyncAdapter {
  /// The [FirebaseFirestore] instance used for database operations.
  final FirebaseFirestore firestore;

  /// Whether to use `set(..., SetOptions(merge: true))` instead of `update()`
  /// for [SyncAction.update].
  ///
  /// Set to `true` by default so missing documents will be created rather than throwing
  /// a `not-found` error.
  final bool useMergeSetForUpdate;

  /// Whether to inspect if a document already exists before executing [SyncAction.create]
  /// and return a [SyncAdapterConflict] if so.
  ///
  /// Defaults to `false`.
  final bool detectExistingOnCreateAsConflict;

  /// Creates a [FirestoreSyncAdapter].
  const FirestoreSyncAdapter({
    required this.firestore,
    this.useMergeSetForUpdate = true,
    this.detectExistingOnCreateAsConflict = false,
  });

  /// Resolves the target [DocumentReference] for a given [mutation].
  DocumentReference<Map<String, dynamic>> resolveDocumentReference(
      SyncMutation mutation) {
    final cleanEndpoint = mutation.endpoint.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    final segments = cleanEndpoint.split('/');

    // Even number of segments -> points directly to a document (e.g. 'users/123')
    if (segments.length % 2 == 0) {
      return firestore.doc(cleanEndpoint);
    }

    // Odd number of segments -> points to a collection (e.g. 'users')
    final docId = mutation.payload['id']?.toString() ?? mutation.id;
    return firestore.collection(cleanEndpoint).doc(docId);
  }

  @override
  Future<SyncAdapterResult> send(SyncMutation mutation) async {
    final docRef = resolveDocumentReference(mutation);

    try {
      switch (mutation.action) {
        case SyncAction.create:
          if (detectExistingOnCreateAsConflict) {
            final existing = await docRef.get();
            if (existing.exists) {
              final serverData = existing.data() ?? {};
              DateTime? serverTimestamp;
              final rawTs = serverData['updated_at'] ??
                  serverData['updatedAt'] ??
                  serverData['timestamp'];

              if (rawTs is Timestamp) {
                serverTimestamp = rawTs.toDate().toUtc();
              } else if (rawTs is String) {
                serverTimestamp = DateTime.tryParse(rawTs)?.toUtc();
              }

              return SyncAdapterConflict(
                serverPayload: serverData,
                serverTimestamp: serverTimestamp,
                reason: 'Document already exists at path: ${docRef.path}',
              );
            }
          }

          await docRef.set(mutation.payload, SetOptions(merge: false));
          return SyncAdapterSuccess(
            statusCode: 201,
            responseData: mutation.payload,
          );

        case SyncAction.update:
          if (useMergeSetForUpdate) {
            await docRef.set(mutation.payload, SetOptions(merge: true));
          } else {
            await docRef.update(mutation.payload);
          }

          return SyncAdapterSuccess(
            statusCode: 200,
            responseData: mutation.payload,
          );

        case SyncAction.delete:
          await docRef.delete();
          return const SyncAdapterSuccess(statusCode: 204);
      }
    } on FirebaseException catch (e) {
      if (e.code == 'already-exists') {
        Map<String, dynamic> serverData = {};
        try {
          final snapshot = await docRef.get();
          serverData = snapshot.data() ?? {};
        } catch (_) {}

        return SyncAdapterConflict(
          serverPayload: serverData,
          reason: e.message ?? 'Document already exists',
        );
      }

      final isRecoverable = e.code == 'unavailable' ||
          e.code == 'deadline-exceeded' ||
          e.code == 'resource-exhausted';

      return SyncAdapterFailure(
        error: 'FirestoreException (${e.code}): ${e.message ?? e.toString()}',
        isRecoverable: isRecoverable,
      );
    } on SocketException catch (e) {
      return SyncAdapterFailure(
        error: 'Network connection failed: ${e.message}',
        isRecoverable: true,
      );
    } on TimeoutException catch (e) {
      return SyncAdapterFailure(
        error: 'Firestore operation timed out: ${e.message ?? e}',
        isRecoverable: true,
      );
    } catch (e) {
      return SyncAdapterFailure(
        error: 'Unexpected Firestore error: $e',
        isRecoverable: false,
      );
    }
  }
}
