import 'dart:async';

/// Interface representing network connectivity monitoring.
///
/// Decouples `sync_orbit` from concrete third-party packages (e.g. `connectivity_plus`,
/// `internet_connection_checker`), allowing any stream of network status to be injected.
abstract interface class SyncConnectivity {
  /// Stream emitting boolean values indicating connectivity:
  /// - `true`: device is connected to the network.
  /// - `false`: device is offline.
  Stream<bool> get onConnectivityChanged;

  /// Returns the current known online status.
  bool get isOnline;

  /// Releases connectivity listeners and subscriptions.
  void dispose();

  /// Creates a [SyncConnectivity] instance backed by an arbitrary [Stream<bool>].
  factory SyncConnectivity.fromStream(
    Stream<bool> stream, {
    bool initialValue,
  }) = _StreamSyncConnectivity;
}

class _StreamSyncConnectivity implements SyncConnectivity {
  final Stream<bool> _stream;
  late final StreamController<bool> _controller;
  StreamSubscription<bool>? _subscription;
  bool _isOnline;

  _StreamSyncConnectivity(
    this._stream, {
    bool initialValue = true,
  }) : _isOnline = initialValue {
    _controller = StreamController<bool>.broadcast();
    _subscription = _stream.listen(
      (online) {
        _isOnline = online;
        if (!_controller.isClosed) {
          _controller.add(online);
        }
      },
      onError: (e, st) {
        if (!_controller.isClosed) {
          _controller.addError(e, st);
        }
      },
    );
  }

  @override
  Stream<bool> get onConnectivityChanged => _controller.stream;

  @override
  bool get isOnline => _isOnline;

  @override
  void dispose() {
    _subscription?.cancel();
    _controller.close();
  }
}
