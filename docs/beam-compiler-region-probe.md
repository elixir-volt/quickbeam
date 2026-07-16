# Bounded compiler region coverage probe

This static probe partitions each verified basic block into independently
compilable regions of at most 64 operations. Property
and strict-global reads remain isolated preflight regions, calls terminate a
region, and unsupported instructions are excluded. The fixed module-pool
estimate retains only the 32 largest regions. These figures are
an instruction-inventory bound, not dynamic execution coverage or a speedup
claim.

- Git base: `0a332b81`
- Working tree at measurement: modified
- Generated: 2026-07-16T13:22:33Z
- Elixir: 1.20.2
- OTP: 29
- CPU: AMD Ryzen 9 9950X 16-Core Processor
- Maximum operations per region: 64
- Fixed generated-module slots: 32

| Fixture | profile | functions | instructions | region functions | bounded regions | regionizable instructions | static region coverage | largest 32 instructions | fixed-pool static coverage |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Preact 10.29.7 | `pure_v1` | 64 | 6648 | 60 | 2213 | 4332 | 65.2% | 224 | 3.4% |
| Preact 10.29.7 | `scalar_v1` | 64 | 6648 | 62 | 3188 | 5977 | 89.9% | 408 | 6.1% |
| Vue 3.5.39 | `pure_v1` | 685 | 33916 | 641 | 10104 | 21095 | 62.2% | 604 | 1.8% |
| Vue 3.5.39 | `scalar_v1` | 685 | 33916 | 670 | 15237 | 29184 | 86.0% | 998 | 2.9% |
| Svelte 5.56.4 | `pure_v1` | 209 | 12199 | 199 | 3664 | 6902 | 56.6% | 329 | 2.7% |
| Svelte 5.56.4 | `scalar_v1` | 209 | 12199 | 208 | 5882 | 10561 | 86.6% | 628 | 5.1% |

A region tier is useful only if dynamic hot-region measurements show that a
small fixed set is executed repeatedly. Static coverage alone cannot justify
compiling every listed region or exceeding the existing module and decision
bounds.
