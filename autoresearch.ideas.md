# Ideas

## Existing Elixir handlers to reuse
- `QuickBEAM.SubtleCrypto` — digest, sign, verify, encrypt, decrypt, generateKey, deriveBits
- `QuickBEAM.Compression` — compress, decompress (zlib)
- `QuickBEAM.Storage` — get_item, set_item, remove_item, clear, key, length
- `QuickBEAM.Buffer` — encode, decode, byte_length (TextEncoder/Decoder internals)
- `QuickBEAM.LocksAPI` — request_lock, release_lock, query_locks
- `QuickBEAM.WorkerAPI` — spawn_worker, terminate_worker, post_to_child
- `QuickBEAM.NodeProcess` — env_get, platform, arch, pid, cwd
- `QuickBEAM.EventSource` — SSE client
