# ztress

A simple CPU (and optionally memory) stress-test utility written in Zig.

Spawns one spinning thread per logical CPU core by default and pegs every core to 100% until the timer runs out or you stop it.

## Usage

```sh
zig run ztress.zig            # run forever (Ctrl-C to stop)
zig run ztress.zig 10         # run for 10 seconds
zig run ztress.zig 2.5        # fractional seconds work too
./ztress 5                    # same, on a built binary
```

```sh
zig build-exe ztress.zig -O ReleaseFast -femit-bin=ztress
./ztress 5
```

Timed mode exits on its own and prints a batch/throughput summary. In forever mode, Ctrl-C stops the workers and still prints the summary before exiting with code 130.

```
usage: ztress [options] [SECONDS]

Runs CPU (optionally + memory) load until SECONDS elapse or stopped.
SECONDS is a float (e.g. 5, 2.5); range 0.001..31557600; default: run
forever (-f/--forever is the explicit way to run forever).

  -f, --forever             run until stopped (SIGINT, Ctrl-C)
  -t, --threads N           worker threads (default: logical CPUs)
  -c, --cores [N]           use physical cores instead (Linux detection;
                            falls back to logical elsewhere); optional N
                            = exact worker count on physical cores
  -b, --batch N             iterations per batch (default 1000000; bounds
                            latency-to-exit and progress granularity)
  -l, --loop-ms N           time-based batches: one batch = N ms of work,
                            instead of a fixed iteration count
  -m, --stress-memory N     each worker allocates and cycles N MiB of
                            memory per batch (replaces arithmetic spin)
  -p, --progress            print running totals every 500 ms
  -v, --verbose             per-thread start/finish lines
      --json                machine-readable summary to stdout
  -h, --help                show this help

Exit codes: 0 normal, 130 interrupted, 2 usage error, 1 runtime error.
```

Flags may appear on either side of `SECONDS`. Batches below 10,000 iterations trigger a warning (per-batch overhead dominates the work and load collapses to a fraction of a core); the run proceeds - use `-l/--loop-ms` if you genuinely want fine-grained batches.

## How it works

Each worker runs an integer-heavy loop (`acc +%= i *% i`) so cores stay hot; a volatile dereference on the accumulator keeps the loop from being optimized away in ReleaseFast builds. Work is done in *batches*: one batch is `-b` iterations (default 1M, a few ms per core) or `-l` milliseconds of spin time. Batches are interruptible, which bounds Ctrl-C/deadline response latency regardless of batch size - bigger batches just make progress reporting coarser.

Per-thread batch counts are compared in the summary; when one thread ran ≥25% fewer batches than another (and batches are iteration-based, not time-based), ztress warns about possible CPU affinity, thermal, or frequency-throttling problems.

With `-m N`, each worker instead allocates N MiB (page-backed, touched to commit), cycles a hashing pass over it each batch, and frees it at exit - e.g. `ztress 5 -m 512` with 16 threads holds ~8 GiB RSS.

## Requirements

- Zig (written against 0.17)
- Linux for `-c/--cores` (reads `/proc/cpuinfo`); falls back to logical core count elsewhere

## Tests

```sh
zig test ztress.zig
```

Covers the arg parser (range clamps, the `1e300`/`0` regressions, flag ordering, mutual exclusions) and physical-core detection parsing. Module tests are aggregated from `ztress.zig`; `config.zig` holds the parser tests, `cores.zig` the cpuinfo parsing tests.
