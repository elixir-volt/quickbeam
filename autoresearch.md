# Autoresearch: Complete Web API Parity

## Objective
Implement ALL remaining web APIs as BEAM builtins to match NIF mode. Every `test/web_apis/*_test.exs` file now has a `beam_*` mirror.

## Metrics
- **Primary**: `failing_tests` (lower is better)
- **Secondary**: `passing_tests`

## How to Run
`./autoresearch.sh`

## Test files (new batch)
- `beam_buffer_test.exs` — Buffer/TextEncoder/ArrayBuffer (73 tests)
- `beam_message_channel_test.exs` — MessageChannel/MessagePort (27 tests)
- `beam_subtle_crypto_test.exs` — SubtleCrypto (21 tests)
- `beam_process_test.exs` — Node.js process (18 tests)
- `beam_compression_test.exs` — CompressionStream/DecompressionStream (9 tests)
- `beam_streams_writable_test.exs` — WritableStream (9 tests)
- `beam_locks_test.exs` — Web Locks (8 tests)
- `beam_storage_test.exs` — localStorage/sessionStorage (7 tests)
- `beam_console_ext_test.exs` — console extensions (6 tests)
- `beam_worker_test.exs` — Worker (5 tests)
- `beam_event_source_test.exs` — EventSource (4 tests)
- `beam_console_test.exs` — console basics (4 tests)

## Architecture
Builtins in `lib/quickbeam/vm/runtime/web/`. Use existing Elixir handlers where they exist (`QuickBEAM.SubtleCrypto`, `QuickBEAM.Compression`, `QuickBEAM.Storage`, etc.).
