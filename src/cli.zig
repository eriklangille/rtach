//! `clauntty` command: send commands to the Clauntty app from any shell.
//!
//! rtach runs as this command when invoked as `clauntty` (or by the older helper
//! names open-browser, forward-port and open-tab, which are symlinks to it).
//! Commands are lines written to a session's command FIFO; the master forwards them
//! to its Clauntty client. The FIFO is $RTACH_CMD_PIPE inside rtach sessions and the
//! machine's active session (see active.zig) everywhere else.

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");
const active = @import("active.zig");
const inbox = @import("inbox.zig");

/// Names rtach answers to as this command
pub fn isCommandName(argv0: []const u8) bool {
    const name = std.fs.path.basename(argv0);
    for ([_][]const u8{ "clauntty", "open-browser", "forward-port", "open-tab" }) |known| {
        if (std.mem.eql(u8, name, known)) return true;
    }
    return false;
}

const usage =
    \\Usage: clauntty <command> [args]
    \\
    \\Send commands to the Clauntty app on your phone.
    \\
    \\Commands:
    \\  open <url>        Open a URL in the phone's browser (forwards localhost ports)
    \\  forward <port>    Forward a port to the phone (8000 or http://localhost:8000)
    \\  tab <port>        Open a port in a Clauntty web tab
    \\  show <image>...   Show images in Clauntty (png, jpg, gif, heic, webp); they
    \\                    wait on this machine until Clauntty connects
    \\  status            Show which session commands go to
    \\
    \\Inside a Clauntty session, commands go to that session. Elsewhere (tmux,
    \\other terminals, ssh) they go to the session Clauntty last had active on
    \\this machine.
    \\
;

pub fn main(allocator: std.mem.Allocator, io: std.Io, process_args: std.process.Args) u8 {
    var args = process_args.iterate();

    const argv0 = args.next() orelse "clauntty";
    const name = std.fs.path.basename(argv0);

    // Older helper names map onto subcommands
    const sub: []const u8 = if (std.mem.eql(u8, name, "open-browser"))
        "open"
    else if (std.mem.eql(u8, name, "forward-port"))
        "forward"
    else if (std.mem.eql(u8, name, "open-tab"))
        "tab"
    else
        args.next() orelse {
            writeOut(usage);
            return 2;
        };

    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(allocator);
    while (args.next()) |arg| rest.append(allocator, arg) catch return fail("out of memory", .{});

    return run(allocator, io, sub, rest.items);
}

fn run(allocator: std.mem.Allocator, io: std.Io, sub: []const u8, args: []const []const u8) u8 {
    if (eql(sub, "-h") or eql(sub, "--help") or eql(sub, "help")) {
        writeOut(usage);
        return 0;
    }
    if (eql(sub, "status")) return status(io);

    if (eql(sub, "open") or eql(sub, "browser")) {
        if (args.len != 1) return fail("usage: clauntty open <url>", .{});
        return sendLines(io, &.{.{ "browser", args[0] }}, null);
    }

    if (eql(sub, "forward") or eql(sub, "tab")) {
        if (args.len != 1) return fail("usage: clauntty {s} <port>", .{sub});
        const port = parsePort(args[0]) orelse return fail("not a port: {s}", .{args[0]});
        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;
        const is_forward = eql(sub, "forward");
        const code = sendLines(io, &.{.{ if (is_forward) "forward" else "open", port_str }}, null);
        if (code == 0) {
            if (is_forward) printOut("Port {d} forwarded\n", .{port}) else printOut("Opened port {d}\n", .{port});
        }
        return code;
    }

    if (eql(sub, "show")) return show(allocator, io, args);

    return fail("unknown command: {s} (see clauntty --help)", .{sub});
}

/// Leave each image in the inbox, then send `image;<id>;<path>` to the session. With
/// every image in the inbox, no reachable session isn't an error: the app picks them
/// up when it connects.
fn show(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) u8 {
    if (args.len == 0) return fail("usage: clauntty show <image>...", .{});

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    for (args) |arg| {
        if (!isImagePath(arg)) return fail("not an image (png, jpg, gif, heic, webp): {s}", .{arg});
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const real_len = std.Io.Dir.cwd().realPathFile(io, arg, &real_buf) catch |err|
            return fail("{s}: {s}", .{ arg, errorText(err) });
        if (std.mem.indexOfScalar(u8, real_buf[0..real_len], '\n') != null) return fail("path contains a newline: {s}", .{arg});
        const path = allocator.dupe(u8, real_buf[0..real_len]) catch return fail("out of memory", .{});
        paths.append(allocator, path) catch {
            allocator.free(path);
            return fail("out of memory", .{});
        };
    }

    var inbox_buf: [std.fs.max_path_bytes]u8 = undefined;
    const inbox_dir: ?[]const u8 = if (sys.getenv("HOME")) |home| inbox.dirPath(home, &inbox_buf) else null;
    const now_ms: i64 = @intCast(@divFloor(sys.realtimeNs(), std.time.ns_per_ms));
    if (inbox_dir) |dir| inbox.prune(io, dir, now_ms);

    var lines: std.ArrayList([2][]const u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line[1]);
        lines.deinit(allocator);
    }
    var queued: usize = 0;
    for (paths.items, 0..) |path, i| {
        var id_buf: [64]u8 = undefined;
        const id = inbox.makeId(&id_buf, now_ms, std.c.getpid(), i);
        const in_inbox = if (inbox_dir) |dir| blk: {
            inbox.add(io, dir, id, path) catch break :blk false;
            break :blk true;
        } else false;
        if (in_inbox) queued += 1;
        // Without an entry, send the plain path: there's nothing for the app to delete
        const value = if (in_inbox)
            std.fmt.allocPrint(allocator, "{s};{s}", .{ id, path })
        else
            allocator.dupe(u8, path);
        lines.append(allocator, .{ "image", value catch return fail("out of memory", .{}) }) catch return fail("out of memory", .{});
    }

    const plural = if (lines.items.len == 1) "" else "s";
    var pointer_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = resolveTarget(io, &pointer_buf);
    const reachable = if (target) |t| fifoOpen(t.fifo) else false;
    if (!reachable and queued == lines.items.len) {
        printOut("Queued {d} image{s} (shown when Clauntty connects)\n", .{ lines.items.len, plural });
        return 0;
    }
    const code = sendLines(io, lines.items, target);
    if (code == 0) printOut("Sent {d} image{s} to Clauntty\n", .{ lines.items.len, plural });
    return code;
}

// MARK: Target

const Target = struct {
    fifo: []const u8,
    /// From $RTACH_CMD_PIPE (this session) rather than the active pointer
    from_env: bool,
};

fn resolveTarget(io: std.Io, pointer_buf: []u8) ?Target {
    if (sys.getenv("RTACH_CMD_PIPE")) |pipe| {
        if (pipe.len > 0) return .{ .fifo = pipe, .from_env = true };
    }
    const home = sys.getenv("HOME") orelse return null;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pointer = std.fmt.bufPrint(&path_buf, "{s}/.clauntty/active", .{home}) catch return null;
    const fifo = active.read(io, pointer, pointer_buf) orelse return null;
    return .{ .fifo = fifo, .from_env = false };
}

const no_target_msg = "no Clauntty session is active on this machine (open a Clauntty tab connected to it)";

/// Write `kind;value` lines to the target session's FIFO
fn sendLines(io: std.Io, lines: []const [2][]const u8, target_override: ?Target) u8 {
    var pointer_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = target_override orelse resolveTarget(io, &pointer_buf) orelse return fail(no_target_msg, .{});

    const fd = openFifo(target.fifo) catch |err| {
        if (target.from_env) return fail("session command pipe unavailable ({s}): {s}", .{ errorText(err), target.fifo });
        return fail(no_target_msg, .{});
    };
    defer sys.close(fd);

    var buf: [8192]u8 = undefined;
    for (lines) |line| {
        const text = std.fmt.bufPrint(&buf, "{s};{s}\n", .{ line[0], line[1] }) catch return fail("argument too long", .{});
        writeAllFd(io, fd, text) catch |err| return fail("failed to send command: {s}", .{errorText(err)});
    }
    return 0;
}

/// Whether the FIFO has a reader (the session's master is running)
fn fifoOpen(path: []const u8) bool {
    const fd = openFifo(path) catch return false;
    sys.close(fd);
    return true;
}

/// Open a FIFO for writing without blocking. error.NoReader means the session's
/// master is gone.
fn openFifo(path: []const u8) !posix.fd_t {
    const path_z = try posix.toPosixPath(path);
    return sys.open(&path_z, .{ .ACCMODE = .WRONLY, .NONBLOCK = true }, 0);
}

fn writeAllFd(io: std.Io, fd: posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    var retries: usize = 0;
    while (written < data.len) {
        const n = sys.write(fd, data[written..]) catch |err| switch (err) {
            // Pipe momentarily full (the master reads it from its event loop)
            error.WouldBlock => {
                retries += 1;
                if (retries > 200) return err;
                try io.sleep(.fromMilliseconds(5), .awake);
                continue;
            },
            else => return err,
        };
        written += n;
    }
}

fn status(io: std.Io) u8 {
    var pointer_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = resolveTarget(io, &pointer_buf) orelse {
        printOut("No active Clauntty session on this machine.\n", .{});
        return 1;
    };
    if (!fifoOpen(target.fifo)) {
        printOut("Session {s} is gone ({s}).\n", .{ sessionId(target.fifo), target.fifo });
        return 1;
    }
    printOut("Commands go to session {s} ({s}).\n", .{
        sessionId(target.fifo),
        if (target.from_env) "this session, $RTACH_CMD_PIPE" else "last active in Clauntty",
    });
    return 0;
}

// MARK: Helpers

/// Session ID from a FIFO path (/.../sessions/<id>.cmd)
fn sessionId(fifo: []const u8) []const u8 {
    const base = std.fs.path.basename(fifo);
    return if (std.mem.endsWith(u8, base, ".cmd")) base[0 .. base.len - 4] else base;
}

/// Port from "8000", ":8000", "localhost:8000" or "http://localhost:8000/path"
pub fn parsePort(arg: []const u8) ?u16 {
    var rest = arg;
    if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];
    if (std.mem.indexOfAny(u8, rest, "/?#")) |i| rest = rest[0..i];
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |i| rest = rest[i + 1 ..];
    const port = std.fmt.parseInt(u16, rest, 10) catch return null;
    return if (port == 0) null else port;
}

pub fn isImagePath(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".heic", ".webp" }) |known| {
        if (std.ascii.eqlIgnoreCase(ext, known)) return true;
    }
    return false;
}

fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "not found",
        error.AccessDenied => "permission denied",
        error.NoReader => "no reader",
        else => @errorName(err),
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn writeOut(text: []const u8) void {
    _ = sys.write(posix.STDOUT_FILENO, text) catch {};
}

fn printOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    writeOut(std.fmt.bufPrint(&buf, fmt, args) catch return);
}

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "clauntty: " ++ fmt ++ "\n", args) catch "clauntty: error\n";
    _ = sys.write(posix.STDERR_FILENO, msg) catch {};
    return 1;
}

const testing = std.testing;
extern "c" fn mkfifo(path: [*:0]const u8, mode: posix.mode_t) c_int;

test "isCommandName" {
    try testing.expect(isCommandName("/home/u/.clauntty/bin/clauntty"));
    try testing.expect(isCommandName("open-browser"));
    try testing.expect(!isCommandName("/home/u/.clauntty/bin/rtach-2.9.0"));
}

test "parsePort" {
    try testing.expectEqual(@as(?u16, 8000), parsePort("8000"));
    try testing.expectEqual(@as(?u16, 8000), parsePort(":8000"));
    try testing.expectEqual(@as(?u16, 3000), parsePort("localhost:3000"));
    try testing.expectEqual(@as(?u16, 5173), parsePort("http://localhost:5173/app?x=1"));
    try testing.expectEqual(@as(?u16, 8080), parsePort("http://[::1]:8080"));
    try testing.expectEqual(@as(?u16, null), parsePort("http://localhost"));
    try testing.expectEqual(@as(?u16, null), parsePort("0"));
    try testing.expectEqual(@as(?u16, null), parsePort("70000"));
}

test "isImagePath" {
    try testing.expect(isImagePath("shot.png"));
    try testing.expect(isImagePath("/tmp/Photo.JPEG"));
    try testing.expect(!isImagePath("notes.txt"));
    try testing.expect(!isImagePath("png"));
}

test "sendLines writes kind;value lines to the FIFO" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const fifo = try std.fmt.bufPrintZ(&path_buf, "{s}/s.cmd", .{dir});

    try testing.expectEqual(@as(c_int, 0), mkfifo(fifo, 0o600));

    // No reader yet: sending fails rather than blocking
    try testing.expectEqual(@as(u8, 1), sendLines(io, &.{.{ "open", "1" }}, .{ .fifo = fifo, .from_env = true }));

    const reader = try sys.open(fifo, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
    defer sys.close(reader);

    try testing.expectEqual(@as(u8, 0), sendLines(io, &.{ .{ "image", "/a.png" }, .{ "image", "/b.png" } }, .{ .fifo = fifo, .from_env = true }));
    var buf: [64]u8 = undefined;
    const n = try posix.read(reader, &buf);
    try testing.expectEqualStrings("image;/a.png\nimage;/b.png\n", buf[0..n]);
}
