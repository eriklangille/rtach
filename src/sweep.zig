//! `rtach sweep`: clear what ended sessions left in ~/.clauntty/sessions.
//!
//! A session that ends normally removes its own files (Master.removeSessionFiles). One
//! whose master crashed or was killed leaves its socket, command pipe, .state, .title
//! and .lock behind, and its .log, the only record of why it ended. For each session
//! whose master doesn't answer, sweep deletes everything but the log, and the log once
//! it's `log_days` old. The app runs it once per host per launch, after `rtach upgrade`.
//!
//! A session being started can look dead for a moment (its master not listening yet),
//! so sweep skips any whose `-A` lock is held or whose files changed in the last
//! `quiet_s` seconds. It deletes a lock only while holding it.

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");

/// A dead session's log is kept this long
pub const log_days = 7;
/// Files this recent mean the session may be starting
const quiet_s = 60;

/// Left by a master, besides the log and the lock
const leftovers = [_][]const u8{ "", ".cmd", ".state", ".state.tmp", ".title", ".title.tmp", ".resume" };

const usage =
    \\Usage: rtach sweep [--json]
    \\
    \\Clear the files of sessions that ended without cleaning up (their master
    \\crashed or was killed) from ~/.clauntty/sessions. Their logs are kept for 7 days.
    \\
;

pub const Result = struct {
    sessions: usize = 0,
    logs: usize = 0,
};

pub fn main(allocator: std.mem.Allocator, io: std.Io, process_args: std.process.Args) u8 {
    var json = false;
    var it = process_args.iterate();
    _ = it.skip(); // rtach
    _ = it.skip(); // sweep
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else {
            _ = sys.write(posix.STDOUT_FILENO, usage) catch {};
            return if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) 0 else 1;
        }
    }

    const home = sys.getenv("HOME") orelse return 1;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = std.fmt.allocPrint(arena, "{s}/.clauntty/sessions", .{home}) catch return 1;
    const now_s: i64 = @intCast(@divFloor(sys.realtimeNs(), std.time.ns_per_s));

    const result = sweep(arena, io, dir, now_s);
    var buf: [128]u8 = undefined;
    const text = if (json)
        std.fmt.bufPrint(&buf, "{{\"sessions\":{d},\"logs\":{d}}}\n", .{ result.sessions, result.logs }) catch return 1
    else
        std.fmt.bufPrint(&buf, "Cleared {d} ended session{s} and {d} old log{s}\n", .{
            result.sessions, if (result.sessions == 1) "" else "s", result.logs, if (result.logs == 1) "" else "s",
        }) catch return 1;
    _ = sys.write(posix.STDOUT_FILENO, text) catch {};
    return 0;
}

pub fn sweep(arena: std.mem.Allocator, io: std.Io, dir_path: []const u8, now_s: i64) Result {
    var result: Result = .{};
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return result;
    defer dir.close(io);

    // Each session's id (a name up to its first '.') and the newest of its files
    var newest: std.StringArrayHashMapUnmanaged(i64) = .empty;
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const id = entry.name[0 .. std.mem.indexOfScalar(u8, entry.name, '.') orelse entry.name.len];
        const mtime: i64 = if (dir.statFile(io, entry.name, .{})) |stat| stat.mtime.toSeconds() else |_| now_s;
        const slot = newest.getOrPut(arena, arena.dupe(u8, id) catch continue) catch continue;
        slot.value_ptr.* = if (slot.found_existing) @max(slot.value_ptr.*, mtime) else mtime;
    }

    for (newest.keys(), newest.values()) |id, changed| {
        if (now_s - changed < quiet_s) continue;
        const socket = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, id }) catch continue;
        if (answers(socket)) continue;

        // Held: the session is being started
        const lock_path = std.fmt.allocPrint(arena, "{s}.lock", .{socket}) catch continue;
        const lock = tryLock(lock_path) catch continue;
        defer if (lock) |fd| sys.close(fd);
        if (answers(socket)) continue;

        var removed = false;
        for (leftovers) |suffix| {
            const path = std.fmt.allocPrint(arena, "{s}{s}", .{ socket, suffix }) catch continue;
            if (deleted(io, path)) removed = true;
        }
        if (lock != null and deleted(io, lock_path)) removed = true;
        if (removed) result.sessions += 1;

        const log_path = std.fmt.allocPrint(arena, "{s}.log", .{socket}) catch continue;
        const log_stat = std.Io.Dir.cwd().statFile(io, log_path, .{}) catch continue;
        if (now_s - log_stat.mtime.toSeconds() >= log_days * std.time.s_per_day and deleted(io, log_path)) result.logs += 1;
    }
    return result;
}

/// A master listens on it
fn answers(path: []const u8) bool {
    const fd = sys.unixSocket(false) catch return true;
    defer sys.close(fd);
    sys.connect(fd, path) catch |err| return err == error.AccessDenied;
    return true;
}

/// The session's lock, taken without waiting: null if it has none, an error if it's held
fn tryLock(path: []const u8) error{Held}!?sys.fd_t {
    const path_z = posix.toPosixPath(path) catch return null;
    const fd = sys.open(&path_z, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch return null;
    while (true) {
        switch (posix.errno(std.c.flock(fd, posix.LOCK.EX | posix.LOCK.NB))) {
            .SUCCESS => return fd,
            .INTR => continue,
            else => {
                sys.close(fd);
                return error.Held;
            },
        }
    }
}

fn deleted(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().deleteFile(io, path) catch return false;
    return true;
}
