//! ztress: a simple CPU (and optionally memory) stress test tool.
//! Entry point + supervisor loop; see config.zig, workers.zig, report.zig,
//! cores.zig, signal.zig for the pieces.

const std = @import("std");
const config = @import("config.zig");
const cores = @import("cores.zig");
const report = @import("report.zig");
const signal = @import("signal.zig");
const workers = @import("workers.zig");

pub fn main(init: std.process.Init) !void {
    var argv = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = argv.next(); // skip argv[0]

    var args_buf: [16][:0]const u8 = undefined;
    var args_len: usize = 0;
    while (argv.next()) |a| {
        if (args_len == args_buf.len) config.usage();
        args_buf[args_len] = a;
        args_len += 1;
    }

    const cfg = config.parseConfig(args_buf[0..args_len]) orelse config.usage();
    // No positional seconds and no -f: default to forever (original contract).
    const forever = cfg.seconds == null;
    if (cfg.small_batch and cfg.loop_ms == null) {
        std.debug.print(
            "ztress: warning: batch of {d} iterations is below the soft floor of {d}; " ++
                "per-batch overhead (~200ns clock/counter) dominates the ~1ns/iter work, " ++
                "so load will be a small fraction of a core. " ++
                "Use -l/--loop-ms for fine-grained time-based batches instead.\n",
            .{ cfg.batch_iters, config.min_batch_iters },
        );
    }

    signal.installSigIntHandler();

    const thread_count: usize = blk: {
        if (cfg.threads) |t| break :blk t;
        if (cfg.physical) {
            if (cores.physicalCoreCount(init.arena.allocator(), init.io)) |p| break :blk p;
            std.debug.print("ztress: note: physical core detection unavailable, using logical count\n", .{});
        }
        break :blk std.Thread.getCpuCount() catch 1;
    };

    const counters = try init.arena.allocator().alloc(std.atomic.Value(u64), thread_count);
    for (counters) |*c| c.* = std.atomic.Value(u64).init(0);

    const threads = try init.arena.allocator().alloc(std.Thread, thread_count);
    var spawned: usize = 0;
    errdefer for (threads[0..spawned]) |t| t.join();

    const start = std.Io.Clock.Timestamp.now(init.io, .awake).raw;
    const deadline: std.Io.Timestamp = if (forever)
        .{ .nanoseconds = std.math.maxInt(i96) }
    else
        start.addDuration(.{ .nanoseconds = @intFromFloat(cfg.seconds.? * 1e9) });

    const progress_period_ns: i96 = 500 * std.time.ns_per_ms;
    var next_progress_ns: i96 = 0;

    for (threads) |*t| {
        // One arena-allocated ctx per worker: stack locals die at loop end, and
        // taking &ctx of a fresh per-iteration local would race all workers on
        // the same (reused) stack address.
        const ctx = try init.arena.allocator().create(workers.WorkerCtx);
        ctx.* = .{
            .id = spawned,
            .io = init.io,
            .deadline = deadline,
            .batch_iters = cfg.batch_iters,
            .loop_ms = cfg.loop_ms,
            .memory_mib = cfg.memory_mib orelse 0,
            .counter = &counters[spawned],
            .verbose = cfg.verbose,
        };
        t.* = std.Thread.spawn(.{}, workers.workerEntry, .{ctx}) catch |e| {
            std.debug.print("ztress: failed to spawn thread {d}: {s}\n", .{ spawned, @errorName(e) });
            break;
        };
        spawned += 1;
    }

    if (spawned == 0) {
        std.debug.print("ztress: no threads started\n", .{});
        return error.NoThreads;
    }

    // Supervisor loop: sleep; wake on SIGINT (sleep unblocks or we re-check).
    var interrupted_run = false;
    while (true) {
        if (signal.stopRequested()) {
            interrupted_run = true;
            break;
        }
        if (!forever and std.Io.Clock.awake.now(init.io).compare(.gte, deadline)) break;
        if (cfg.progress) {
            const now_ts = std.Io.Clock.awake.now(init.io);
            if (next_progress_ns == 0) {
                next_progress_ns = now_ts.addDuration(.{ .nanoseconds = progress_period_ns }).nanoseconds;
            } else if (now_ts.nanoseconds >= next_progress_ns) {
                var total: u64 = 0;
                for (counters[0..spawned]) |*c| total += c.load(.monotonic);
                std.debug.print("progress: {d} batches\n", .{total});
                next_progress_ns = now_ts.addDuration(.{ .nanoseconds = progress_period_ns }).nanoseconds;
            }
        }
        init.io.sleep(.{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
    }

    for (threads[0..spawned]) |t| t.join();

    const end = std.Io.Clock.Timestamp.now(init.io, .awake).raw;
    report.printSummary(&cfg, counters[0..spawned], start.durationTo(end).nanoseconds, interrupted_run);
    if (interrupted_run) std.process.exit(130);
}

// Pull in module tests so `zig test ztress.zig` runs the whole suite.
test {
    _ = config;
    _ = cores;
    _ = report;
    _ = signal;
    _ = workers;
}
