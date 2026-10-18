//! Live upgrade: a session's master replaces itself with a newer rtach without ending
//! the session. It writes what it knows to `<socket>.resume`, then execs the new binary
//! as `rtach --resume <socket> <pty fd> <socket fd> <pipe fd> <shell pid>`. Same
//! process, same open PTY: the shell and everything under it carries on. Clients are
//! dropped and reattach.
//!
//! What's needed to keep the session (the fds and the shell) is on the command line;
//! the state file only has what's nice to keep (scrollback, modes, title, pane state).
//! A file the new version can't read costs the scrollback, not the session.
//!
//! `rtach upgrade` asks every older master on this machine to upgrade to this binary
//! (`upgrade;<path>` on its command pipe). The app runs it after deploying rtach.

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");
const version = @import("main.zig").version;

const log = std.log.scoped(.upgrade);

/// Bump when the state file changes in a way older readers would misread. Fields can be
/// added without a bump: a reader ignores ones it doesn't know and defaults missing ones.
pub const format = 1;

/// The state file's first line (JSON); the scrollback's bytes follow it
pub const State = struct {
    format: u32 = format,
    /// The version that wrote it
    rtach: []const u8 = "",
    command: []const u8 = "",
    scrollback_capacity: usize = 0,
    scrollback_total_written: u64 = 0,
    rows: u16 = 24,
    cols: u16 = 80,
    alt_screen: bool = false,
    cursor_visible: bool = true,
    mode_flags: u8 = 0,
    mouse_event: ?u16 = null,
    mouse_format: ?u16 = null,
    title: []const u8 = "",
    fg: []const u8 = "",
    cwd: []const u8 = "",
    agent: []const u8 = "none",
    status: []const u8 = "none",
    note: []const u8 = "",
    task: []const u8 = "",
    from_hook: bool = false,
    flushed_status: []const u8 = "none",
    pushed_status: []const u8 = "none",
    /// A command pipe line not finished yet
    cmd_partial: []const u8 = "",
};

pub fn statePath(buf: []u8, socket_path: []const u8) ?[:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{s}.resume", .{socket_path}) catch null;
}

/// Write the state file: the header line, then the scrollback (`first` then `second`)
pub fn save(io: std.Io, allocator: std.mem.Allocator, socket_path: []const u8, state: State, first: []const u8, second: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = statePath(&path_buf, socket_path) orelse return error.PathTooLong;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return error.PathTooLong;

    const header = try std.json.Stringify.valueAlloc(allocator, state, .{});
    defer allocator.free(header);
    const data = try std.mem.concat(allocator, u8, &.{ header, "\n", first, second });
    defer allocator.free(data);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = data, .flags = .{ .permissions = .fromMode(0o600) } });
    cwd.rename(tmp, cwd, path, io) catch |err| {
        cwd.deleteFile(io, tmp) catch {};
        return err;
    };
}

pub const Loaded = struct {
    state: State,
    scrollback: []const u8,
};

/// Read and delete the state file. Null if it's missing or can't be read: then the
/// session goes on without what was in it. Allocations live as long as `arena`.
pub fn load(io: std.Io, arena: std.mem.Allocator, socket_path: []const u8) ?Loaded {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = statePath(&path_buf, socket_path) orelse return null;
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, arena, .limited(256 * 1024 * 1024)) catch |err| {
        log.warn("no state to resume from ({s}): {}", .{ path, err });
        return null;
    };
    cwd.deleteFile(io, path) catch {};
    return parse(arena, data);
}

pub fn parse(arena: std.mem.Allocator, data: []const u8) ?Loaded {
    const end = std.mem.indexOfScalar(u8, data, '\n') orelse return null;
    const state = std.json.parseFromSliceLeaky(State, arena, data[0..end], .{ .ignore_unknown_fields = true }) catch |err| {
        log.warn("state file unreadable: {}", .{err});
        return null;
    };
    if (state.format != format) {
        log.warn("state file format {} (this reads {}), starting without it", .{ state.format, format });
        return null;
    }
    return .{ .state = state, .scrollback = data[end + 1 ..] };
}

/// The fds an upgrade keeps, and the shell, from `--resume`'s arguments
pub const Kept = struct {
    socket_path: []const u8,
    pty: posix.fd_t,
    socket: posix.fd_t,
    fifo: posix.fd_t,
    child_pid: posix.pid_t,
};

/// `--resume <socket> <pty fd> <socket fd> <pipe fd> <shell pid>`
pub fn parseResumeArgs(args: []const []const u8) ?Kept {
    if (args.len != 5) return null;
    return .{
        .socket_path = args[0],
        .pty = std.fmt.parseInt(posix.fd_t, args[1], 10) catch return null,
        .socket = std.fmt.parseInt(posix.fd_t, args[2], 10) catch return null,
        .fifo = std.fmt.parseInt(posix.fd_t, args[3], 10) catch return null,
        .child_pid = std.fmt.parseInt(posix.pid_t, args[4], 10) catch return null,
    };
}

// MARK: Versions

/// "2.18.0" → comparable; null if it isn't one
pub fn parseVersion(text: []const u8) ?[3]u32 {
    var parts = std.mem.splitScalar(u8, text, '.');
    var out: [3]u32 = undefined;
    for (&out) |*n| n.* = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    if (parts.next() != null) return null;
    return out;
}

pub fn older(a: [3]u32, b: [3]u32) bool {
    for (a, b) |x, y| {
        if (x != y) return x < y;
    }
    return false;
}

// MARK: rtach upgrade

const usage =
    \\Usage: rtach upgrade [--json] [SESSION...]
    \\
    \\Upgrade running sessions on this machine to this rtach without ending them.
    \\Each session's master replaces itself with this binary, keeping its shell and
    \\scrollback; attached clients reconnect. Sessions started before rtach 2.19.0
    \\can't upgrade: restart them to update. With no SESSION, all of them.
    \\
;

const Outcome = enum { upgraded, current, too_old, failed };

pub fn main(allocator: std.mem.Allocator, io: std.Io, process_args: std.process.Args) u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var json = false;
    var named: std.ArrayList([]const u8) = .empty;
    var it = process_args.iterate();
    _ = it.skip(); // rtach
    _ = it.skip(); // upgrade
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            _ = sys.write(posix.STDOUT_FILENO, usage) catch {};
            return 0;
        } else {
            named.append(arena, arg) catch return 1;
        }
    }

    const home = sys.getenv("HOME") orelse return fail("HOME isn't set", .{});
    const sessions = std.fmt.allocPrint(arena, "{s}/.clauntty/sessions", .{home}) catch return 1;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = std.process.executablePath(io, &exe_buf) catch return fail("can't find this rtach's path", .{});
    const exe = exe_buf[0..exe_len];
    const ours = parseVersion(version).?;

    // The sessions: named ones, or every socket's state file
    var ids: std.ArrayList([]const u8) = .empty;
    if (named.items.len > 0) {
        ids = named;
    } else {
        var dir = std.Io.Dir.cwd().openDir(io, sessions, .{ .iterate = true }) catch return report(json, .{ 0, 0, 0, 0 });
        defer dir.close(io);
        var entries = dir.iterate();
        while (entries.next(io) catch null) |entry| {
            if (std.mem.indexOfScalar(u8, entry.name, '.') != null) continue;
            if (entry.kind != .unix_domain_socket) continue;
            ids.append(arena, arena.dupe(u8, entry.name) catch return 1) catch return 1;
        }
    }

    // Ask each older master to upgrade, then wait for them to say they have
    var counts = [_]usize{0} ** 4;
    var asked: std.ArrayList([]const u8) = .empty;
    for (ids.items) |id| {
        // A session ID, or a socket's path
        const socket = if (std.mem.indexOfScalar(u8, id, '/') != null)
            id
        else
            std.fmt.allocPrint(arena, "{s}/{s}", .{ sessions, id }) catch return 1;
        const running = masterVersion(io, arena, socket);
        const outcome: Outcome = if (running) |v| blk: {
            if (!older(v, ours)) break :blk .current;
            if (!sendUpgrade(arena, socket, exe)) break :blk .failed;
            asked.append(arena, socket) catch return 1;
            continue;
        } else .too_old;
        counts[@intFromEnum(outcome)] += 1;
    }

    // A resumed master writes its state within a second or so
    const deadline = nowMs(io) + 5000;
    var waiting = asked.items;
    while (waiting.len > 0 and nowMs(io) < deadline) {
        var still: usize = 0;
        for (waiting) |socket| {
            const v = masterVersion(io, arena, socket);
            if (v != null and !older(v.?, ours)) {
                counts[@intFromEnum(Outcome.upgraded)] += 1;
            } else {
                waiting[still] = socket;
                still += 1;
            }
        }
        waiting = waiting[0..still];
        if (waiting.len > 0) io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
    counts[@intFromEnum(Outcome.failed)] += waiting.len;
    return report(json, counts);
}

/// The version a session's master runs, from its state file (2.19.0+ write it)
fn masterVersion(io: std.Io, arena: std.mem.Allocator, socket: []const u8) ?[3]u32 {
    const path = std.fmt.allocPrint(arena, "{s}.state", .{socket}) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return null;
    const Fields = struct { rtach: ?[]const u8 = null };
    const fields = std.json.parseFromSliceLeaky(Fields, arena, data, .{ .ignore_unknown_fields = true }) catch return null;
    return parseVersion(fields.rtach orelse return null);
}

fn sendUpgrade(arena: std.mem.Allocator, socket: []const u8, exe: []const u8) bool {
    const fifo = std.fmt.allocPrintSentinel(arena, "{s}.cmd", .{socket}, 0) catch return false;
    const line = std.fmt.allocPrint(arena, "upgrade;{s}\n", .{exe}) catch return false;
    // No reader: the master is gone
    const fd = sys.open(fifo, .{ .ACCMODE = .WRONLY, .NONBLOCK = true }, 0) catch return false;
    defer sys.close(fd);
    const n = sys.write(fd, line) catch return false;
    return n == line.len;
}

fn report(json: bool, counts: [4]usize) u8 {
    var buf: [512]u8 = undefined;
    const text = if (json)
        std.fmt.bufPrint(&buf, "{{\"upgraded\":{d},\"current\":{d},\"too_old\":{d},\"failed\":{d}}}\n", .{ counts[0], counts[1], counts[2], counts[3] }) catch return 1
    else
        std.fmt.bufPrint(&buf, "Upgraded {d}, already current {d}, too old to upgrade {d} (restart them to update), failed {d}\n", .{ counts[0], counts[1], counts[2], counts[3] }) catch return 1;
    _ = sys.write(posix.STDOUT_FILENO, text) catch {};
    return if (counts[3] > 0) 1 else 0;
}

fn fail(comptime format_text: []const u8, args: anytype) u8 {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "rtach upgrade: " ++ format_text ++ "\n", args) catch return 1;
    _ = sys.write(posix.STDERR_FILENO, text) catch {};
    return 1;
}

fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

test "versions" {
    try std.testing.expect(older(parseVersion("2.18.0").?, parseVersion("2.19.0").?));
    try std.testing.expect(older(parseVersion("2.9.3").?, parseVersion("2.10.0").?));
    try std.testing.expect(!older(parseVersion("2.19.0").?, parseVersion("2.19.0").?));
    try std.testing.expect(parseVersion("2.19") == null);
}

test "state round trip, and a bad header loses only the state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const header = try std.json.Stringify.valueAlloc(arena, State{ .rtach = "2.19.0", .title = "a\nb", .alt_screen = true }, .{});
    const data = try std.mem.concat(arena, u8, &.{ header, "\n", "line 1\nline 2\n" });
    const loaded = parse(arena, data).?;
    try std.testing.expectEqualStrings("a\nb", loaded.state.title);
    try std.testing.expect(loaded.state.alt_screen);
    try std.testing.expectEqualStrings("line 1\nline 2\n", loaded.scrollback);

    try std.testing.expect(parse(arena, "{not json\nbytes") == null);
    try std.testing.expect(parse(arena, "{\"format\":99}\nbytes") == null);
    // Unknown fields (a newer writer) are fine
    try std.testing.expect(parse(arena, "{\"format\":1,\"later\":true}\n") != null);
}
