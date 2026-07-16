# BEAM VM object-memory measurements

This fixture retains one JavaScript array populated by sequential
`Array.prototype.push` calls. It measures the canonical interpreter path,
including isolated-process startup and result conversion. Endpoint process
memory is not a sampled peak or operating-system RSS value.

## Environment

- Git base: `d6162072`
- Working tree at measurement: modified
- Generated: 2026-07-16T14:40:42Z
- Elixir: 1.20.2
- OTP: 29
- ERTS: 17.0.2
- Architecture: x86_64-pc-linux-gnu
- CPU: AMD Ryzen 9 9950X 16-Core Processor
- Array entries: 20000
- Samples after 3 warmups: 30

| wall median | wall p95 | reductions median | endpoint process memory | VM steps | logical memory |
|---:|---:|---:|---:|---:|---:|
| 72.92 ms | 80.51 ms | 9655746 | 2.78 MiB | 280022 | 1.95 MiB |

VM steps and logical memory are deterministic. The benchmark intentionally
retains the array until measurement so the endpoint observation includes
its live representation.
