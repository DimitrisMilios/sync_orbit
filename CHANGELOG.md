# Changelog

All notable changes to `sync_orbit` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-10-28

### Added
- **Core Orchestrator**: `SyncEngine` with concurrent flush protection, paused/resume controls, and reactive state monitoring.
- **Outbox Mutation Model**: `SyncMutation` supporting `create`, `update`, and `delete` actions with ISO-8601 timestamps, retry tracking, metadata, and JSON serialization.
- **Pluggable Persistence**: `SyncStorage` interface and `InMemorySyncStorage` implementation for unit testing and lightweight use.
- **Remote Adapter Contract**: `SyncAdapter` with sealed `SyncAdapterResult` (`SyncAdapterSuccess`, `SyncAdapterConflict`, `SyncAdapterFailure`).
- **Conflict Resolution Strategies**:
  - `ServerWinsResolver`
  - `ClientWinsResolver`
  - `LastWriteWinsResolver` (timestamp comparison with payload fallbacks)
  - `CustomConflictResolver` for programmatic payload merges.
- **Exponential Backoff**: `RetryPolicy` supporting customizable base delay, multipliers, maximum bounds, jitter, and retry limits.
- **Reactive Connectivity**: `SyncConnectivity` and `StreamSyncConnectivity` allowing seamless injection of `connectivity_plus` or custom network streams.
- **Example & Tests**: Complete runnable example script and comprehensive test suite with 100% passing unit and integration tests.
