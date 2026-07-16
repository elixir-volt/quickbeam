# BEAM VM object-memory measurements

These fixtures retain a sequential JavaScript array and an array of ordinary
three-property objects. They measure the canonical interpreter path,
including isolated-process startup and result conversion. Endpoint process
memory is not a sampled peak or operating-system RSS value.

## Environment

- Git base: `dff74297`
- Working tree at measurement: modified
- Generated: 2026-07-16T15:09:18Z
- Elixir: 1.20.2
- OTP: 29
- ERTS: 17.0.2
- Architecture: x86_64-pc-linux-gnu
- CPU: AMD Ryzen 9 9950X 16-Core Processor
- Samples per fixture after 3 warmups: 30

| workload | entries | wall median | wall p95 | reductions median | endpoint process memory | retained VM heap | VM steps | logical memory |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| sequential array | 20000 | 70.45 ms | 73.14 ms | 9627442 | 4.5 MiB | 1017.3 KiB | 280022 | 1.95 MiB |
| ordinary objects | 5000 | 44.32 ms | 45.27 ms | 4907714 | 9.13 MiB | 2.32 MiB | 130022 | 5.14 MiB |

VM steps and logical memory are deterministic. Retained VM heap uses
`:erts_debug.size/1` after direct canonical interpretation and includes
shared subterms once; it is diagnostic rather than a supported OTP API.
Endpoint process memory is observational and reflects allocated heap classes,
not only live terms.
