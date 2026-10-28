import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/sync_action.dart';
import '../models/sync_mutation.dart';
import 'sync_adapter.dart';
import 'sync_adapter_result.dart';

/// Signature for asynchronously or synchronously providing HTTP request headers.
typedef RestHeadersProvider = FutureOr<Map<String, String>> Function();

/// Signature for resolving the target [Uri] for a given [SyncMutation].
typedef RestUrlResolver = Uri Function(SyncMutation mutation, Uri baseUri);

/// A production-ready REST API implementation of [SyncAdapter].
///
/// Dispatches [SyncMutation] operations via HTTP:
/// - [SyncAction.create] -> `POST`
/// - [SyncAction.update] -> `PUT` (or `PATCH` if [usePatchForUpdate] is true)
/// - [SyncAction.delete] -> `DELETE`
class RestSyncAdapter implements SyncAdapter {
  /// The base URL for the REST API (e.g. `https://api.example.com/v1`).
  final String baseUrl;

  /// Optional function returning custom headers (e.g. Authorization Bearer tokens).
  final RestHeadersProvider? headersProvider;

  /// Injected HTTP client for network dispatch and testing.
  final http.Client client;

  /// Optional custom URL resolver overriding default endpoint routing.
  final RestUrlResolver? urlResolver;

  /// Whether to automatically append the entity identifier to the URL path
  /// for `UPDATE` and `DELETE` actions.
  ///
  /// Defaults to `true`.
  final bool appendIdOnUpdateAndDelete;

  /// Whether to use HTTP `PATCH` instead of `PUT` for [SyncAction.update].
  ///
  /// Defaults to `false`.
  final bool usePatchForUpdate;

  /// Network timeout for each HTTP request. Defaults to 30 seconds.
  final Duration timeout;

  /// Set of HTTP status codes interpreted as server-side conflicts.
  ///
  /// Defaults to `{409, 412}` (Conflict, Precondition Failed).
  final Set<int> conflictStatusCodes;

  /// Set of HTTP status codes treated as recoverable/transient errors.
  ///
  /// Defaults to `{408, 429, 500, 502, 503, 504}`.
  final Set<int> recoverableStatusCodes;

  /// Creates a [RestSyncAdapter].
  RestSyncAdapter({
    required this.baseUrl,
    this.headersProvider,
    http.Client? client,
    this.urlResolver,
    this.appendIdOnUpdateAndDelete = true,
    this.usePatchForUpdate = false,
    this.timeout = const Duration(seconds: 30),
    Set<int>? conflictStatusCodes,
    Set<int>? recoverableStatusCodes,
  })  : client = client ?? http.Client(),
        conflictStatusCodes = conflictStatusCodes ?? const {409, 412},
        recoverableStatusCodes =
            recoverableStatusCodes ?? const {408, 429, 500, 502, 503, 504};

  /// Resolves the destination [Uri] for the given [mutation].
  Uri resolveUri(SyncMutation mutation) {
    final baseUri = Uri.parse(baseUrl);

    if (urlResolver != null) {
      return urlResolver!(mutation, baseUri);
    }

    final cleanBase = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final cleanEndpoint = mutation.endpoint.startsWith('/')
        ? mutation.endpoint.substring(1)
        : mutation.endpoint;

    if (appendIdOnUpdateAndDelete &&
        (mutation.action == SyncAction.update ||
            mutation.action == SyncAction.delete)) {
      final id = mutation.payload['id']?.toString() ?? mutation.id;
      if (!cleanEndpoint.endsWith('/$id') && cleanEndpoint != id) {
        return Uri.parse('$cleanBase/$cleanEndpoint/$id');
      }
    }

    return Uri.parse('$cleanBase/$cleanEndpoint');
  }

  @override
  Future<SyncAdapterResult> send(SyncMutation mutation) async {
    final targetUri = resolveUri(mutation);

    try {
      final dynamicHeaders = await headersProvider?.call() ?? {};
      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        ...dynamicHeaders,
      };

      late http.Response response;

      switch (mutation.action) {
        case SyncAction.create:
          response = await client
              .post(
                targetUri,
                headers: headers,
                body: jsonEncode(mutation.payload),
              )
              .timeout(timeout);

        case SyncAction.update:
          final body = jsonEncode(mutation.payload);
          if (usePatchForUpdate) {
            response = await client
                .patch(targetUri, headers: headers, body: body)
                .timeout(timeout);
          } else {
            response = await client
                .put(targetUri, headers: headers, body: body)
                .timeout(timeout);
          }

        case SyncAction.delete:
          final body = mutation.payload.isNotEmpty
              ? jsonEncode(mutation.payload)
              : null;
          response = await client
              .delete(targetUri, headers: headers, body: body)
              .timeout(timeout);
      }

      return _handleResponse(response);
    } on TimeoutException catch (e) {
      return SyncAdapterFailure(
        error: 'REST request timed out after $timeout: ${e.message ?? e}',
        isRecoverable: true,
      );
    } on SocketException catch (e) {
      return SyncAdapterFailure(
        error: 'Network connection failed: ${e.message}',
        isRecoverable: true,
      );
    } on http.ClientException catch (e) {
      return SyncAdapterFailure(
        error: 'HTTP Client Exception: ${e.message}',
        isRecoverable: true,
      );
    } catch (e) {
      return SyncAdapterFailure(
        error: 'Unexpected REST sync error: $e',
        isRecoverable: false,
      );
    }
  }

  SyncAdapterResult _handleResponse(http.Response response) {
    final statusCode = response.statusCode;
    final Map<String, dynamic>? parsedBody = _tryParseJson(response.body);

    // 1. Success (2xx)
    if (statusCode >= 200 && statusCode < 300) {
      return SyncAdapterSuccess(
        statusCode: statusCode,
        responseData: parsedBody,
      );
    }

    // 2. Conflict (409, 412, etc.)
    if (conflictStatusCodes.contains(statusCode)) {
      DateTime? serverTimestamp;
      if (parsedBody != null) {
        final rawTimestamp = parsedBody['updated_at'] ??
            parsedBody['updatedAt'] ??
            parsedBody['timestamp'];
        if (rawTimestamp is String) {
          serverTimestamp = DateTime.tryParse(rawTimestamp)?.toUtc();
        }
      }

      // Also check HTTP Date header if body doesn't contain a timestamp
      if (serverTimestamp == null && response.headers.containsKey('date')) {
        try {
          serverTimestamp =
              HttpDate.parse(response.headers['date']!).toUtc();
        } catch (_) {}
      }

      return SyncAdapterConflict(
        serverPayload: parsedBody ?? {},
        serverTimestamp: serverTimestamp,
        statusCode: statusCode,
        reason: parsedBody?['message']?.toString() ??
            parsedBody?['error']?.toString() ??
            'Remote conflict detected (HTTP $statusCode)',
      );
    }

    // 3. Recoverable vs Non-recoverable failures
    final isRecoverable = recoverableStatusCodes.contains(statusCode);
    final errorMsg = parsedBody?['message']?.toString() ??
        parsedBody?['error']?.toString() ??
        (response.body.isNotEmpty ? response.body : 'HTTP error $statusCode');

    return SyncAdapterFailure(
      error: 'HTTP $statusCode: $errorMsg',
      statusCode: statusCode,
      isRecoverable: isRecoverable,
    );
  }

  Map<String, dynamic>? _tryParseJson(String body) {
    if (body.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      } else if (decoded is List) {
        return {'data': decoded};
      }
    } catch (_) {}
    return null;
  }
}
