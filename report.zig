//! Summary reporting: human-readable and JSON output, slow-core detection.

const std = @import("std");
const config = @import("config.zig");

pub fn printSummary(
    cfg: *const config.Config,
    counters: []const std.atomic.Value(u64),
    elapsed_ns: i96,
    interrupted_run: bool,
) void {
    var total: u64 = 0;
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;
    var min_id: usize = 0;
    var max_id: usize = 0;
    for (counters, 0..) |c, id| {
        const v = c.load(.acquire);
        total += v;
        if (v < min) {
            min = v;
            min_id = id;
        }
        if (v > max) {
            max = v;
            max_id = id;
        }
    }
    const n = counters.len;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;

    // Slow-core detection (iteration-based CPU batches only: time-based
    // batches are equal-length by construction, and memory batches vary
    // legitimately with allocator behavior).
    var slow_ratio: f64 = 0;
    if (n > 1 and min > 0 and cfg.loop_ms == null and cfg.memory_mib == null) {
        slow_ratio = @as(f64, @floatFromInt(max)) / @as(f64, @floatFromInt(min));
    }
    const slow_detected = slow_ratio >= 1.25;

    if (cfg.json) {
        std.debug.print(
            "{{\"mode\":\"{s}\",\"seconds\":{any},\"threads\":{d},\"elapsed_s\":{d:.2},\"total_batches\":{d},\"total_iterations\":{any},\"interrupted\":{},\"min_thread_batches\":{d},\"max_thread_batches\":{d},\"min_thread_id\":{d},\"max_thread_id\":{d},\"slow_ratio\":{d:.2},\"slow_detected\":{},\"per_thread_batch_counts\":[",
            .{
                if (cfg.memory_mib != null) "memory" else "cpu",
                if (cfg.seconds) |s| s else -1.0,
                n,
                elapsed_s,
                total,
                total * cfg.batch_iters,
                interrupted_run,
                min,
                max,
                min_id,
                max_id,
                slow_ratio,
                slow_detected,
            },
        );
        for (counters, 0..) |c, idx| {
            std.debug.print("{s}{d}", .{ if (idx == 0) "" else ",", c.load(.acquire) });
        }
        std.debug.print("]}}\n", .{});
        return;
    }

    std.debug.print(
        "ztress: {d} batches ({d} iters) {s}{d} threads in {d:.2}s{s}\n",
        .{
            total,
            total * cfg.batch_iters,
            if (cfg.memory_mib != null) "(memory mode) " else "across ",
            n,
            elapsed_s,
            if (interrupted_run) " [interrupted]" else "",
        },
    );

    if (slow_detected) {
        std.debug.print(
            "  warning: thread {d} ran ~{d:.0}% fewer batches than thread {d} - check CPU affinity, pinning, thermal or frequency throttling\n",
            .{ min_id, (1.0 - 1.0 / slow_ratio) * 100.0, max_id },
        );
    }
    if (cfg.verbose) {
        for (counters, 0..) |c, id| {
            std.debug.print("  thread {d}: {d} batches\n", .{ id, c.load(.acquire) });
        }
    }
}
