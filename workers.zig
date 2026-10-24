//! Worker threads: iteration-count CPU batches, time-based batches, and a
//! memory-churn mode. All flavours check the shared stop flag and their
//! deadline, and publish a batch counter for the summary.

const std = @import("std");
const signal = @import("signal.zig");
const config = @import("config.zig");

pub const WorkerCtx = struct {
    id: usize,
    io: std.Io,
    deadline: std.Io.Timestamp, // maxInt = forever
    batch_iters: u64, // ignored when loop_ms set
    loop_ms: ?u64,
    memory_mib: u64, // 0 = cpu mode
    counter: *std.atomic.Value(u64),
    verbose: bool,
};

fn timeUp(io: std.Io, deadline: std.Io.Timestamp) bool {
    return std.Io.Clock.awake.now(io).compare(.gte, deadline);
}

fn shouldStop(ctx: *const WorkerCtx) bool {
    return signal.stopRequested() or timeUp(ctx.io, ctx.deadline);
}

fn cpuWorker(ctx: *const WorkerCtx) void {
    if (ctx.verbose) std.debug.print("worker {}: started\n", .{ctx.id});
    var acc: u64 = 0;
    var batches: u64 = 0;
    const batch = @min(ctx.batch_iters, std.math.maxInt(u63));

    while (!shouldStop(ctx)) {
        if (ctx.loop_ms) |ms| {
            // Time-based batch: spin until the quantum elapses.
            const batch_deadline = std.Io.Clock.awake.now(ctx.io).addDuration(
                .{ .nanoseconds = @as(i96, @intCast(ms)) * std.time.ns_per_ms },
            );
            while (!timeUp(ctx.io, batch_deadline) and !signal.stopRequested()) {
                var i: u64 = 0;
                while (i < config.check_stride) : (i += 1) acc +%= i *% i;
            }
        } else {
            var done: u64 = 0;
            while (done < batch) {
                var i: u64 = 0;
                const end = @min(batch - done, config.check_stride);
                while (i < end) : (i += 1) acc +%= i *% i;
                done += end;
                if (shouldStop(ctx)) break;
            }
        }
        // Volatile deref keeps the batch live under ReleaseFast.
        const volatile_acc: *volatile u64 = &acc;
        _ = volatile_acc.*;
        batches += 1;
        ctx.counter.store(batches, .monotonic);
    }
    ctx.counter.store(batches, .monotonic);
    if (ctx.verbose) std.debug.print("worker {}: finished {d} batches\n", .{ ctx.id, batches });
}

fn memWorker(ctx: *const WorkerCtx) void {
    if (ctx.verbose) std.debug.print("worker {}: started (mem {d} MiB)\n", .{ ctx.id, ctx.memory_mib });

    const size = ctx.memory_mib * 1024 * 1024;
    const pool = std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_max), @intCast(size)) catch {
        std.debug.print("worker {d}: failed to allocate {d} MiB\n", .{ ctx.id, ctx.memory_mib });
        return;
    };
    defer std.heap.page_allocator.free(pool);

    // Touch once to commit pages.
    @memset(pool, 0);

    var batch: u64 = 0;
    var h: u64 = 0xcbf29ce484222325;
    while (!shouldStop(ctx)) {
        const batch_deadline = if (ctx.loop_ms) |ms|
            std.Io.Clock.awake.now(ctx.io).addDuration(
                .{ .nanoseconds = @as(i96, @intCast(ms)) * std.time.ns_per_ms },
            )
        else
            std.Io.Timestamp{ .nanoseconds = std.math.maxInt(i96) };

        for (pool) |*b| {
            h = (h ^ b.*) *% 0x100000001b3;
            b.* = @truncate(h);
            if ((@intFromPtr(b) & 0xFFFF) == 0) {
                if (timeUp(ctx.io, batch_deadline) or signal.stopRequested()) break;
            }
        }
        // Volatile sink keeps the pass live under ReleaseFast.
        const volatile_h: *volatile u64 = &h;
        _ = volatile_h.*;

        batch += 1;
        ctx.counter.store(batch, .monotonic);
    }
    ctx.counter.store(batch, .monotonic);
    if (ctx.verbose) std.debug.print("worker {d}: finished {d} memory batches\n", .{ ctx.id, batch });
}

/// Single dispatch trampoline so both worker flavours share one spawn closure type.
pub fn workerEntry(ctx: *const WorkerCtx) void {
    if (ctx.memory_mib != 0) memWorker(ctx) else cpuWorker(ctx);
}
