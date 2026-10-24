//! Tuning constants, CLI config parsing, and usage text.
//! Pure logic; unit tests live at the bottom (`zig test`).

const std = @import("std");

/// Default iterations per batch, per worker. Bounds Ctrl-C/deadline latency:
/// one batch is a few ms of work per core. Override with -b.
pub const default_batch_iters: u64 = 1_000_000;

/// Stop-flag/voluntary-exit check interval inside the inner loop. Keeping
/// batches interruptible means huge -b values can't wedge Ctrl-C.
pub const check_stride: u64 = 65_536;

/// Duration bounds for the positional seconds argument (float ns safety:
/// everything at or below max_seconds is exactly representable in f64 ns math
/// we do; 1e300 silently truncates to ~0 without this clamp).
pub const min_seconds: f64 = 0.001;
pub const max_seconds: f64 = 31_557_600; // 365.25 days

/// Sanity cap on -t; spawn errors (rlimit) still handled gracefully in main.
pub const max_threads: usize = 4096;

/// Sanity cap on --batch; nothing stops you going higher conceptually, but
/// u64 parse is the guard and the interruptible stride keeps it responsive.
pub const max_batch: u64 = std.math.maxInt(u63);

/// Soft floor for --batch. Below this, per-batch overhead (clock check +
/// counter store, ~200ns) dominates the mul/add work (~1ns/iter), so load
/// becomes a small fraction of a core. Warned about, not rejected.
pub const min_batch_iters: u64 = 10_000;

/// Per-worker memory pool cap for --stress-memory (64 TiB).
pub const max_mem_mib: u64 = 65_536;

pub const Config = struct {
    seconds: ?f64 = null, // positional, mutually exclusive with forever
    forever: bool = false, // -f/--forever
    threads: ?usize = null, // -t/--threads N
    physical: bool = false, // -c/--cores (physical cores instead of logical)
    batch_iters: u64 = default_batch_iters, // -b/--batch N
    small_batch: bool = false, // set when -b below soft floor
    loop_ms: ?u64 = null, // -l/--loop-ms N (time-based batch quantum)
    memory_mib: ?u64 = null, // -m/--stress-memory N (per worker)
    progress: bool = false, // -p/--progress
    verbose: bool = false, // -v/--verbose
    json: bool = false, // --json (machine-readable summary)
};

pub const Flag = enum {
    forever,
    help,
    cores,
    progress,
    verbose,
    json,
    threads,
    batch,
    loop_ms,
    memory,
};

const FlagDef = struct { tag: Flag, strs: [2][]const u8 };

const flag_defs = [_]FlagDef{
    .{ .tag = .forever, .strs = .{ "-f", "--forever" } },
    .{ .tag = .help, .strs = .{ "-h", "--help" } },
    .{ .tag = .cores, .strs = .{ "-c", "--cores" } },
    .{ .tag = .progress, .strs = .{ "-p", "--progress" } },
    .{ .tag = .verbose, .strs = .{ "-v", "--verbose" } },
    .{ .tag = .json, .strs = .{ "--json", "--json" } }, // long-only: repeated
    .{ .tag = .threads, .strs = .{ "-t", "--threads" } },
    .{ .tag = .batch, .strs = .{ "-b", "--batch" } },
    .{ .tag = .loop_ms, .strs = .{ "-l", "--loop-ms" } },
    .{ .tag = .memory, .strs = .{ "-m", "--stress-memory" } },
};

fn lookupFlag(s: []const u8) ?Flag {
    inline for (flag_defs) |def| {
        if (std.mem.eql(u8, s, def.strs[0]) or std.mem.eql(u8, s, def.strs[1])) {
            return def.tag;
        }
    }
    return null;
}

/// Consumes the token after flag `i` (its value). Null when argv is exhausted.
fn nextValue(argv: []const [:0]const u8, i: *usize) ?[:0]const u8 {
    i.* += 1;
    if (i.* >= argv.len) return null;
    return argv[i.*];
}

pub fn parseSeconds(s: []const u8) ?f64 {
    const f = std.fmt.parseFloat(f64, s) catch return null;
    if (!std.math.isFinite(f) or f < min_seconds or f > max_seconds) return null;
    return f;
}

fn parseUsize(s: []const u8) ?usize {
    const n = std.fmt.parseInt(usize, s, 10) catch return null;
    if (n == 0) return null;
    return n;
}

fn parseU64Limit(s: []const u8, limit: u64) ?u64 {
    const n = std.fmt.parseInt(u64, s, 10) catch return null;
    if (n == 0 or n > limit) return null;
    return n;
}

pub fn parseConfig(argv: []const [:0]const u8) ?Config {
    var cfg = Config{};
    var i: usize = 0;
    var positional_seen: bool = false;
    var only_positional: bool = false; // after `--`
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (!only_positional and std.mem.eql(u8, a, "--")) {
            only_positional = true;
        } else if (!only_positional and a.len > 1 and a[0] == '-') {
            const flag = lookupFlag(a) orelse return null;
            switch (flag) {
                .forever => cfg.forever = true,
                .help => return null, // triggers usage; distinct from runtime errors
                .progress => cfg.progress = true,
                .verbose => cfg.verbose = true,
                .json => cfg.json = true,
                .cores => {
                    cfg.physical = true;
                    // Optional value: consume the next token only if it parses
                    // as a plain count, so `-c 4` = 4 workers on physical
                    // cores while `-c 2.5` still leaves 2.5 as the positional
                    // seconds.
                    if (i + 1 < argv.len and argv[i + 1].len > 0 and argv[i + 1][0] != '-') {
                        if (parseUsize(argv[i + 1])) |n| {
                            if (n > max_threads) return null;
                            cfg.threads = n;
                            i += 1;
                        }
                    }
                },
                .threads => {
                    const v = nextValue(argv, &i) orelse return null;
                    cfg.threads = parseUsize(v) orelse return null;
                    if (cfg.threads.? > max_threads) return null;
                },
                .batch => {
                    const v = nextValue(argv, &i) orelse return null;
                    cfg.batch_iters = parseU64Limit(v, max_batch) orelse return null;
                    if (cfg.batch_iters < min_batch_iters) cfg.small_batch = true;
                },
                .loop_ms => {
                    const v = nextValue(argv, &i) orelse return null;
                    cfg.loop_ms = parseU64Limit(v, 60 * 60 * 1000) orelse return null;
                },
                .memory => {
                    const v = nextValue(argv, &i) orelse return null;
                    cfg.memory_mib = parseU64Limit(v, max_mem_mib) orelse return null;
                },
            }
        } else {
            // Positional: seconds. Flags may appear on either side of it.
            if (positional_seen) return null;
            positional_seen = true;
            cfg.seconds = parseSeconds(a) orelse return null;
        }
    }
    if (cfg.forever and cfg.seconds != null) return null;
    return cfg;
}

pub fn usage() noreturn {
    std.debug.print(
        \\usage: ztress [options] [SECONDS]
        \\
        \\Runs CPU (optionally + memory) load until SECONDS elapse or stopped.
        \\SECONDS is a float (e.g. 5, 2.5); range {d:.3}..{d:.0}; default: run
        \\forever (-f/--forever is the explicit way to run forever).
        \\
        \\  -f, --forever         run until stopped (SIGINT, Ctrl-C)
        \\  -t, --threads N       worker threads (default: logical CPUs)
        \\  -c, --cores [N]       use physical cores instead (Linux detection;
        \\                        falls back to logical elsewhere); optional N
        \\                        = exact worker count on physical cores
        \\  -b, --batch N         iterations per batch (default {d}; bounds
        \\                        latency-to-exit and progress granularity)
        \\  -l, --loop-ms N       time-based batches: one batch = N ms of work,
        \\                        instead of a fixed iteration count
        \\  -m, --stress-memory N each worker allocates and cycles N MiB of
        \\                        memory per batch (replaces arithmetic spin)
        \\  -p, --progress        print running totals every 500 ms
        \\  -v, --verbose         per-thread start/finish lines
        \\      --json            machine-readable summary to stdout
        \\  -h, --help            show this help
        \\
        \\Exit codes: 0 normal, 130 interrupted, 2 usage error, 1 runtime error.
        \\
    , .{ min_seconds, max_seconds, default_batch_iters });
    std.process.exit(2);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseSeconds: valid floats and ranges" {
    try testing.expectEqual(@as(?f64, 5.0), parseSeconds("5"));
    try testing.expectEqual(@as(?f64, 2.5), parseSeconds("2.5"));
    try testing.expectEqual(@as(?f64, 0.5), parseSeconds(".5"));
    try testing.expectEqual(@as(?f64, 100.0), parseSeconds("1e2"));
}

test "parseSeconds: rejects the zero/precision/clamp bugs" {
    try testing.expectEqual(@as(?f64, null), parseSeconds("0"));
    try testing.expectEqual(@as(?f64, null), parseSeconds("-1"));
    try testing.expectEqual(@as(?f64, null), parseSeconds("1e300")); // regression: silently-truncated huge value
    try testing.expectEqual(@as(?f64, null), parseSeconds("inf"));
    try testing.expectEqual(@as(?f64, null), parseSeconds("nan"));
    try testing.expectEqual(@as(?f64, null), parseSeconds(""));
    try testing.expectEqual(@as(?f64, null), parseSeconds("banana"));
    const over_max = try std.fmt.allocPrint(testing.allocator, "{d}", .{max_seconds * 2});
    defer testing.allocator.free(over_max);
    try testing.expectEqual(@as(?f64, null), parseSeconds(over_max));
}

test "parseConfig: flags, positionals, exclusions" {
    // Accepted shapes
    inline for (.{ "-t", "--threads" }) |flag| {
        const argv_fwd = [_][:0]const u8{ flag, "4" };
        const c = parseConfig(&argv_fwd) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(?usize, 4), c.threads);
    }
    const argv1 = [_][:0]const u8{ "-b", "100", "1.5" };
    const r1 = parseConfig(&argv1);
    try testing.expect(r1 != null);
    try testing.expectEqual(@as(u64, 100), r1.?.batch_iters);
    try testing.expectEqual(@as(?f64, 1.5), r1.?.seconds);

    const argv2 = [_][:0]const u8{"--forever"};
    const r2 = parseConfig(&argv2);
    try testing.expect(r2 != null);
    try testing.expect(r2.?.forever);

    const argv3 = [_][:0]const u8{ "--stress-memory", "64" };
    const r3 = parseConfig(&argv3);
    try testing.expect(r3 != null);
    try testing.expectEqual(@as(?u64, 64), r3.?.memory_mib);

    const argv4 = [_][:0]const u8{ "-l", "50" };
    const r4 = parseConfig(&argv4);
    try testing.expect(r4 != null);
    try testing.expectEqual(@as(?u64, 50), r4.?.loop_ms);

    // Mutual exclusion: forever + positional
    const argv5 = [_][:0]const u8{ "-f", "5" };
    try testing.expectEqual(@as(?Config, null), parseConfig(&argv5));

    // Two positionals rejected
    const argv6 = [_][:0]const u8{ "3", "4" };
    try testing.expectEqual(@as(?Config, null), parseConfig(&argv6));

    // Unknown flag rejected; flag missing value rejected
    const argv7 = [_][:0]const u8{"-o"};
    try testing.expectEqual(@as(?Config, null), parseConfig(&argv7));
    const argv8 = [_][:0]const u8{"-t"};
    try testing.expectEqual(@as(?Config, null), parseConfig(&argv8));

    // Flag after positional (regression: consumed-token ordering bug)
    const argv11 = [_][:0]const u8{ "0.2", "--json" };
    const r11 = parseConfig(&argv11) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(?f64, 0.2), r11.seconds);
    try testing.expect(r11.json);

    // Soft floor: below-floor batch sets small_batch, floor batch doesn't
    const argv12 = [_][:0]const u8{ "-b", "10" };
    const r12 = parseConfig(&argv12) orelse return error.TestUnexpectedResult;
    try testing.expect(r12.small_batch);
    try testing.expectEqual(@as(u64, 10), r12.batch_iters);
    const argv13 = [_][:0]const u8{ "-b", "10000" };
    const r13 = parseConfig(&argv13) orelse return error.TestUnexpectedResult;
    try testing.expect(!r13.small_batch);

    // -c with optional count: `-c 4` = physical + 4 workers
    const argv14 = [_][:0]const u8{ "-c", "4" };
    const r14 = parseConfig(&argv14) orelse return error.TestUnexpectedResult;
    try testing.expect(r14.physical);
    try testing.expectEqual(@as(?usize, 4), r14.threads);
    // `-c` bare = physical, auto count
    const argv15 = [_][:0]const u8{"-c"};
    const r15 = parseConfig(&argv15) orelse return error.TestUnexpectedResult;
    try testing.expect(r15.physical);
    try testing.expectEqual(@as(?usize, null), r15.threads);
    // `-c 2.5` = physical, 2.5 stays positional
    const argv16 = [_][:0]const u8{ "-c", "2.5" };
    const r16 = parseConfig(&argv16) orelse return error.TestUnexpectedResult;
    try testing.expect(r16.physical);
    try testing.expectEqual(@as(?usize, null), r16.threads);
    try testing.expectEqual(@as(?f64, 2.5), r16.seconds);
    // flags-only = forever default (no positional, no -f is now valid)
    const argv17 = [_][:0]const u8{ "-b", "10" };
    const r17 = parseConfig(&argv17) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(?f64, null), r17.seconds);
    try testing.expect(!r17.forever); // main supplies the forever default

    // --json long-only entry works via table (repeat-slot sanity)
    const argv18 = [_][:0]const u8{"--json"};
    const r18 = parseConfig(&argv18) orelse return error.TestUnexpectedResult;
    try testing.expect(r18.json);

    // unknown long flag still rejected
    const argv19 = [_][:0]const u8{"--bogus"};
    try testing.expectEqual(@as(?Config, null), parseConfig(&argv19));

    // Zero/huge thread counts rejected
    const argv9 = [_][:0]const u8{ "-t", "0" };
    try testing.expectEqual(@as(?Config, null), parseConfig(&argv9));
    const argv10 = [_][:0]const u8{ "-t", "99999" };
    try testing.expectEqual(@as(?Config, null), parseConfig(&argv10));
}
