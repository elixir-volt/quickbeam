# Bounded compiler dynamic region hotspots

This opt-in diagnostic samples every 16th interpreted instruction into at
most 64 owner-local Space-Saving heavy hitters. Windows are aligned to 64
instruction PCs. `samples-error` is the conservative frequency lower bound;
fixed-pool potential applies each window's statically supported ratio to the
32 strongest lower bounds. Generated instructions are not sampled. Results
are fixture/profile-specific and are not production telemetry or speedup
claims.

- Git base: `0a332b81`
- Working tree at measurement: modified
- Generated: 2026-07-16T13:22:35Z
- Elixir: 1.20.2
- OTP: 29
- CPU: AMD Ryzen 9 9950X 16-Core Processor
- Sampling interval: 16 interpreted instructions
- Heavy-hitter capacity: 64 regions
- Fixed generated-module slots: 32

| Fixture | profile | VM steps | existing generated steps | samples | retained regions | fixed-pool supported lower bound |
|---|---|---:|---:|---:|---:|---:|
| Preact 10.29.7 | `pure_v1` | 3651 | 0 | 228 | 41 | 61.8% |
| Preact 10.29.7 | `scalar_v1` | 3651 | 0 | 228 | 41 | 85.2% |
| Vue 3.5.39 | `pure_v1` | 11957 | 50 | 744 | 64 | 37.0% |
| Vue 3.5.39 | `scalar_v1` | 11957 | 126 | 739 | 64 | 46.9% |
| Svelte 5.56.4 | `pure_v1` | 1777 | 24 | 109 | 34 | 34.0% |
| Svelte 5.56.4 | `scalar_v1` | 1777 | 0 | 111 | 35 | 77.7% |

## Leading sampled windows

| Fixture | profile | function@pc | samples | error | lower bound | supported instructions |
|---|---|---|---:|---:|---:|---:|
| Preact 10.29.7 | `pure_v1` | `f56@0` | 28 | 0 | 28 | 46/64 |
| Preact 10.29.7 | `pure_v1` | `f4@0` | 19 | 0 | 19 | 35/57 |
| Preact 10.29.7 | `pure_v1` | `f3@0` | 18 | 0 | 18 | 48/64 |
| Preact 10.29.7 | `pure_v1` | `f56@64` | 13 | 0 | 13 | 51/64 |
| Preact 10.29.7 | `pure_v1` | `f56@1024` | 12 | 0 | 12 | 52/64 |
| Preact 10.29.7 | `pure_v1` | `f56@128` | 10 | 0 | 10 | 41/64 |
| Preact 10.29.7 | `pure_v1` | `f56@1088` | 10 | 0 | 10 | 49/64 |
| Preact 10.29.7 | `pure_v1` | `f56@768` | 9 | 0 | 9 | 50/64 |
| Preact 10.29.7 | `scalar_v1` | `f56@0` | 28 | 0 | 28 | 59/64 |
| Preact 10.29.7 | `scalar_v1` | `f4@0` | 19 | 0 | 19 | 42/57 |
| Preact 10.29.7 | `scalar_v1` | `f3@0` | 18 | 0 | 18 | 57/64 |
| Preact 10.29.7 | `scalar_v1` | `f56@64` | 13 | 0 | 13 | 58/64 |
| Preact 10.29.7 | `scalar_v1` | `f56@1024` | 12 | 0 | 12 | 62/64 |
| Preact 10.29.7 | `scalar_v1` | `f56@128` | 10 | 0 | 10 | 60/64 |
| Preact 10.29.7 | `scalar_v1` | `f56@1088` | 10 | 0 | 10 | 61/64 |
| Preact 10.29.7 | `scalar_v1` | `f56@768` | 9 | 0 | 9 | 62/64 |
| Vue 3.5.39 | `pure_v1` | `f1@0` | 165 | 0 | 165 | 21/35 |
| Vue 3.5.39 | `pure_v1` | `f493@0` | 20 | 1 | 19 | 62/64 |
| Vue 3.5.39 | `pure_v1` | `f492@64` | 20 | 3 | 17 | 39/64 |
| Vue 3.5.39 | `pure_v1` | `f652@0` | 20 | 5 | 15 | 31/53 |
| Vue 3.5.39 | `pure_v1` | `f175@0` | 15 | 0 | 15 | 11/20 |
| Vue 3.5.39 | `pure_v1` | `f660@0` | 18 | 4 | 14 | 50/64 |
| Vue 3.5.39 | `pure_v1` | `f658@0` | 16 | 4 | 12 | 47/64 |
| Vue 3.5.39 | `pure_v1` | `f492@0` | 15 | 3 | 12 | 63/64 |
| Vue 3.5.39 | `scalar_v1` | `f1@0` | 165 | 0 | 165 | 27/35 |
| Vue 3.5.39 | `scalar_v1` | `f493@0` | 20 | 1 | 19 | 64/64 |
| Vue 3.5.39 | `scalar_v1` | `f492@64` | 20 | 3 | 17 | 44/64 |
| Vue 3.5.39 | `scalar_v1` | `f175@0` | 15 | 0 | 15 | 13/20 |
| Vue 3.5.39 | `scalar_v1` | `f660@0` | 18 | 4 | 14 | 60/64 |
| Vue 3.5.39 | `scalar_v1` | `f652@0` | 17 | 5 | 12 | 42/53 |
| Vue 3.5.39 | `scalar_v1` | `f492@0` | 15 | 3 | 12 | 64/64 |
| Vue 3.5.39 | `scalar_v1` | `f658@0` | 15 | 4 | 11 | 61/64 |
| Svelte 5.56.4 | `pure_v1` | `f1@0` | 8 | 0 | 8 | 46/64 |
| Svelte 5.56.4 | `pure_v1` | `f199@0` | 5 | 0 | 5 | 31/64 |
| Svelte 5.56.4 | `pure_v1` | `f0@0` | 4 | 0 | 4 | 0/64 |
| Svelte 5.56.4 | `pure_v1` | `f0@64` | 4 | 0 | 4 | 0/64 |
| Svelte 5.56.4 | `pure_v1` | `f0@128` | 4 | 0 | 4 | 0/64 |
| Svelte 5.56.4 | `pure_v1` | `f0@192` | 4 | 0 | 4 | 0/64 |
| Svelte 5.56.4 | `pure_v1` | `f0@256` | 4 | 0 | 4 | 0/64 |
| Svelte 5.56.4 | `pure_v1` | `f0@320` | 4 | 0 | 4 | 0/64 |
| Svelte 5.56.4 | `scalar_v1` | `f1@0` | 10 | 0 | 10 | 63/64 |
| Svelte 5.56.4 | `scalar_v1` | `f207@0` | 6 | 0 | 6 | 10/13 |
| Svelte 5.56.4 | `scalar_v1` | `f0@0` | 4 | 0 | 4 | 64/64 |
| Svelte 5.56.4 | `scalar_v1` | `f0@64` | 4 | 0 | 4 | 64/64 |
| Svelte 5.56.4 | `scalar_v1` | `f0@128` | 4 | 0 | 4 | 64/64 |
| Svelte 5.56.4 | `scalar_v1` | `f0@192` | 4 | 0 | 4 | 52/64 |
| Svelte 5.56.4 | `scalar_v1` | `f0@256` | 4 | 0 | 4 | 37/64 |
| Svelte 5.56.4 | `scalar_v1` | `f0@320` | 4 | 0 | 4 | 42/64 |

The next implementation gate is positive only when a small fixed region set
has a meaningful conservative dynamic lower bound. Otherwise region
compilation would add artifact churn without enough warm execution.
