//! Shared stop flag and SIGINT (POSIX) / Ctrl-C (Windows) handling.
//! The flag is set by the handler and read by workers + supervisor.

const std = @import("std");
const builtin = @import("builtin");

var stop_flag = std.atomic.Value(bool).init(false);

// Win32 `PHANDLER_ROUTINE`. std does not wrap SetConsoleCtrlHandler, so the
// binding lives here; BOOL is an int and CTRL_C_EVENT == 0, CTRL_BREAK_EVENT == 1.
extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (u32) callconv(.winapi) c_int,
    add: c_int,
) callconv(.winapi) c_int;

fn handleConsoleCtrl(ctrl_type: u32) callconv(.winapi) c_int {
    if (ctrl_type > 1) return 0; // close/logoff/shutdown: leave to the default handler
    if (stop_flag.swap(true, .seq_cst)) return 0; // second Ctrl-C: default kills the process
    return 1; // handled: supervisor stops workers and prints the summary
}

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
    if (builtin.os.tag == .windows) {
        _ = SetConsoleCtrlHandler(handleConsoleCtrl, 1);
        return;
    }
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