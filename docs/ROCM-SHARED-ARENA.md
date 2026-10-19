# The 4-replica shared-arena crash: full investigation & the capped-registration fix

This is the complete evidence chain behind the `STRATA_ARENA_PIN_GIB` (1/4/16 GiB tested stable; 25 GiB+ crashes) recommendation in the README. Everything below was measured on one machine: 4× RX 7900 XTX (gfx1100), EPYC 7K62, 128 GB DDR4-3200, Ubuntu 24.04.5 (kernel 6.8.0-147), Strata 0.1.45, TheRock ROCm wheels 7.10.0a20251120 and 7.14.0a20260612 (both affected).

## Goal

4 independent engines (data parallel, one GPU each) sharing **one** copy of the 56 GB expert pool: a MAP_SHARED file (tmpfs `/dev/shm`, or a regular file — both tested), each process mmaps it and registers it with its GPU via `hipHostRegister` (`cudaHostRegister(Portable|Mapped)` through Strata's built-in `--shared-expert-arena`, which adds a magic + pack-hash header so late joiners validate before mapping).

## Symptom

- 1 or 2 processes: registration OK, load OK, serves for hours (50.6 tok/s per lane measured).
- 4 processes: all four register OK, load 55.43 GiB, reach `session is up`, then SIGSEGV almost simultaneously in the last startup steps. Victim varies; the failure is otherwise deterministic across dozens of runs, both ROCm versions, both backing files.

## Evidence

dmesg — identical instruction offset in every process, null-pointer deref:

```
strata[...]: segfault at 8 ip ...b71c9 ... error 6 in libamdhip64.so.7
```

gdb on the coredump:

```
#0–#5  libamdhip64.so.7 (no symbols, same offset b71c9)
#6  strata::core::Verifier::init(...)
#7  main ()
```

Disassembly at the faulting instruction:

```
mov  0x80(%rbx),%r8              ; r8 = an internal table pointer = NULL
=> movw $0x1,-0x80(%r8,%rdi,1)   ; write a 16-bit flag; addr = 0 + 0x88 - 0x80 = 8
```

A struct field that should point to a mapping-descriptor table is NULL and is written through — i.e. an earlier step **succeeded nominally** but left the runtime's internal state incomplete. Same signature as TheRock issue #8939 (1 MiB pageable registration returns success; a runtime thread segfaults later), and matches AMD's documented guidance that `hipHostRegister` is for small-to-moderate buffers (internally ROCM-29767, a *permanent* limitation: "Performance and Kernel Stability Limitations with Large Registrations").

## The decisive experiment

| hipHostRegister size per process | Processes | Result |
|---|---|---|
| 56 GB (whole arena) | 1, 2 | ✅ stable for hours |
| 56 GB | 4 | ❌ deterministic SIGSEGV |
| 25 GB, 22 slices × ~1.1 GiB (`STRATA_ARENA_PIN_GIB=27`) | 4 | ❌ SIGSEGV — slicing doesn't help |
| **1 GB (`STRATA_ARENA_PIN_GIB` (1/4/16 GiB tested stable; 25 GiB+ crashes))** | **4** | ✅ stable, benchmarked |

Registration size is the dominant variable; process count matters only as a multiplier of exposure.

## Ruled out (each change alone, crash unchanged)

1. `cudaHostRegisterPortable` removed (engine patch; per-device registration only)
2. Registration capped to 25 GiB (rules out total-bytes / GTT-capacity explanations)
3. `HSA_USERPTR_FOR_PAGED_MEM=0`
4. tmpfs vs NVMe file backing
5. ROCm 7.10 → 7.14
6. Kernel `iommu=pt` + GTT 256 GiB (`ttm.pages_limit=67108864`, `ttm.page_pool_size=67108864`, `amdgpu gttsize=262144`)
7. OOM (none), `LimitMEMLOCK=infinity`, ample free RAM

## Why the 1 GiB cap costs almost nothing

The un-registered 54 GiB stays `mlock`-resident and is read by the **CPU expert pool** — host threads reading their own process memory need no GPU registration. GPU-side reads of the arena are covered by each card's ~16 GiB expert cache (filled at load) plus the 1 GiB registered window. Measured: single stream 46.9 tok/s vs 50.6 fully-registered (−7%); 4 concurrent streams 45.6–52.4 each, **188.6 tok/s aggregate**, zero crashes over sustained load.

## Practical checklist for this configuration

1. `/dev/shm` must exceed the arena: `sudo mount -o remount,size=70G /dev/shm` (re-run after every reboot; the arena is rebuilt on first start).
2. `--shared-expert-arena` and `--resident-budget-gib` are mutually exclusive — no budget flag means the full pool.
3. `env: {"STRATA_ARENA_PIN_GIB": "16", "GPU_PINNED_MIN_XFER_SIZE": "1048576"}` in the model config.
4. systemd unit needs `LimitMEMLOCK=infinity`.
5. First engine creates and loads the arena (~1–2 min); the others validate the pack hash and map the same physical pages.
