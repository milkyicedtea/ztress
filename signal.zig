//! Shared stop flag and SIGINT handling.
//! The flag is set by the signal handler and read by workers + supervisor.

const std = @import("std");

var stop_flag = std.atomic.Value(bool).init(false);

fn handleSigInt(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    if (stop_flag.swap(true, .seq_cst)) {
        // Second SIGINT: restore default disposition and re-raise for a hard kill.
        const def: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &def, null);
        std.posix.raise(std.posix.SIG.INT) catch {};
    }
}

pub fn installSigIntHandler() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSigInt },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

pub fn stopRequested() bool {
    return stop_flag.load(.monotonic);
}
