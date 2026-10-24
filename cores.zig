//! Physical core detection from Linux /proc/cpuinfo.
//! Non-Linux and parse-failure callers fall back to logical core count.

const std = @import("std");

const Pair = struct { p: u32, c: u32 };

/// Counts unique (physical id, core id) pairs in a Linux /proc/cpuinfo body.
/// Returns null when either field is missing (some arches/VMs omit them).
pub fn countUniqueCores(cpuinfo: []const u8, alloc: std.mem.Allocator) ?usize {
    var pairs: std.ArrayList(Pair) = .empty;
    defer pairs.deinit(alloc);

    var physical_id: ?u32 = null;
    var core_id: ?u32 = null;
    var lines = std.mem.splitScalar(u8, cpuinfo, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            // End of one CPU block: flush.
            if (physical_id != null and core_id != null) {
                addUniquePair(&pairs, alloc, physical_id.?, core_id.?) catch return null;
            }
            physical_id = null;
            core_id = null;
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        const val = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (std.mem.eql(u8, key, "physical id")) {
            physical_id = std.fmt.parseInt(u32, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "core id")) {
            core_id = std.fmt.parseInt(u32, val, 10) catch null;
        }
    }
    // Flush trailing block if file didn't end on blank line.
    if (physical_id != null and core_id != null) {
        addUniquePair(&pairs, alloc, physical_id.?, core_id.?) catch return null;
    }
    if (pairs.items.len == 0) return null;
    return pairs.items.len;
}

fn addUniquePair(pairs: *std.ArrayList(Pair), alloc: std.mem.Allocator, p: u32, c: u32) !void {
    for (pairs.items) |k| {
        if (k.p == p and k.c == c) return;
    }
    try pairs.append(alloc, .{ .p = p, .c = c });
}

pub fn physicalCoreCount(alloc: std.mem.Allocator, init_io: std.Io) ?usize {
    const f = std.Io.Dir.openFileAbsolute(init_io, "/proc/cpuinfo", .{}) catch return null;
    defer f.close(init_io);
    // procfs reports stat.size == 0, so use a fixed cap instead of trusting it.
    const buf = alloc.alignedAlloc(u8, .of(u8), 4 * 1024 * 1024) catch return null;
    defer alloc.free(buf);
    const n = f.readPositionalAll(init_io, buf, 0) catch return null;
    return countUniqueCores(buf[0..n], alloc);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "countUniqueCores: synthetic /proc/cpuinfo shapes" {
    const two_socket_two_cores =
        \\processor : 0
        \\physical id : 0
        \\core id : 0
        \\
        \\processor : 1
        \\physical id : 0
        \\core id : 1
        \\
        \\processor : 2
        \\physical id : 1
        \\core id : 0
        \\
        \\processor : 3
        \\physical id : 1
        \\core id : 1
        \\
    ;
    try testing.expectEqual(@as(?usize, 4), countUniqueCores(two_socket_two_cores, testing.allocator));

    // Hyperthreaded pair sharing one core counts once.
    const ht_pair =
        \\processor : 0
        \\physical id : 0
        \\core id : 0
        \\
        \\processor : 1
        \\physical id : 0
        \\core id : 0
        \\
    ;
    try testing.expectEqual(@as(?usize, 1), countUniqueCores(ht_pair, testing.allocator));

    // Missing topology fields -> fallback (null).
    try testing.expectEqual(@as(?usize, null), countUniqueCores("processor : 0\n", testing.allocator));
}
