/// Configuration options for fine-tuning [SyncEngine] behavior.
class SyncEngineOptions {
  /// Whether successfully synced mutations should be deleted from storage immediately.
  ///
  /// If `false`, mutations are kept in storage and marked with [SyncStatus.completed].
  /// Defaults to `true`.
  final bool deleteOnSuccess;

  /// Whether to automatically trigger a queue flush upon enqueuing a new mutation
  /// when online.
  ///
  /// Defaults to `true`.
  final bool autoFlushOnEnqueue;

  /// Whether to automatically trigger a queue flush when connectivity transitions
  /// to online.
  ///
  /// Defaults to `true`.
  final bool autoFlushOnOnline;

  /// Maximum number of mutations to process in a single flush pass.
  ///
  /// If null, all pending mutations are processed sequentially.
  final int? batchSize;

  const SyncEngineOptions({
    this.deleteOnSuccess = true,
    this.autoFlushOnEnqueue = true,
    this.autoFlushOnOnline = true,
    this.batchSize,
  });
}
