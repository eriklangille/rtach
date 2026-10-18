//! Push notifications, for when an agent finishes or needs the user while the app is
//! away (suspended phones can't hear the session). Each phone that connected here left
//! a line in ~/.clauntty/push: `<worker url> <device key> <phone id>`. For each, curl
//! (or wget) posts the notice to Clauntty's push Worker, which sends it on through APNs.
//!
//! A pane's master works out the notice (`line`) when its agent's status changes; the
//! master of the session the app shows sends it, if no app is attached there (see
//! Master.handlePush): that's the one the app would have been told through.

const std = @import("std");
const sys = @import("sys.zig");

const log = std.log.scoped(.push);

/// `<pane>;<done|blocked>;<title>;<body>`, as the pane's master sends it. Title has
/// no `;`. `buf` is where it goes.
pub fn line(buf: []u8, pane: []const u8, kind: []const u8, title: []const u8, body: []const u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("{s};{s};", .{ pane, kind }) catch return null;
    for (title) |c| w.writeByte(if (c == ';' or c == '\n') ',' else c) catch return null;
    w.writeByte(';') catch return null;
    for (body) |c| w.writeByte(if (c == '\n') ' ' else c) catch return null;
    return w.buffered();
}

/// Send `notice` (see `line`) to every phone in ~/.clauntty/push. Doesn't wait.
pub fn send(io: std.Io, notice: []const u8) void {
    var fields = std.mem.splitScalar(u8, notice, ';');
    const pane = fields.next() orelse return;
    const kind = fields.next() orelse return;
    const title = fields.next() orelse return;
    const body = fields.rest();

    const home = sys.getenv("HOME") orelse return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.clauntty/push", .{home}) catch return;
    var file_buf: [8192]u8 = undefined;
    const phones = std.Io.Dir.cwd().readFile(io, path, &file_buf) catch return;

    var lines = std.mem.splitScalar(u8, phones, '\n');
    while (lines.next()) |phone| {
        var words = std.mem.tokenizeAny(u8, phone, " \t\r");
        const url = words.next() orelse continue;
        const key = words.next() orelse continue;
        if (!std.mem.startsWith(u8, url, "https://")) continue;

        var json_buf: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&json_buf);
        std.json.Stringify.value(.{ .key = key, .title = title, .body = body, .pane = pane, .kind = kind }, .{}, &w) catch continue;
        var url_buf: [512]u8 = undefined;
        const target = std.fmt.bufPrintZ(&url_buf, "{s}/notify", .{std.mem.trimEnd(u8, url, "/")}) catch continue;
        post(target, w.buffered());
        log.info("push: {s} for {s}", .{ kind, pane });
    }
}

/// curl (or BusyBox wget, on minimal Linux without curl), with the JSON on its stdin
/// (not in its arguments, where `ps` shows it). A grandchild runs it so nobody has to
/// wait for it to finish.
fn post(url: [*:0]const u8, json: []const u8) void {
    const fds = sys.pipe() catch return;
    const pid = sys.fork() catch {
        sys.close(fds[0]);
        sys.close(fds[1]);
        return;
    };
    if (pid == 0) {
        const grandchild = sys.fork() catch std.process.exit(1);
        if (grandchild != 0) std.process.exit(0);
        sys.dup2(fds[0], 0);
        const null_fd = sys.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch std.process.exit(1);
        sys.dup2(null_fd, 1);
        sys.dup2(null_fd, 2);
        // Not the master's sockets and terminal
        var fd: sys.fd_t = 3;
        while (fd < 1024) : (fd += 1) sys.close(fd);
        const curl = [_:null]?[*:0]const u8{
            "curl", "-s", "-m", "10", "-o", "/dev/null",
            "-H",   "content-type: application/json",
            "--data-binary", "@-",
            url,
        };
        sys.execvpZ("curl", &curl);
        const wget = [_:null]?[*:0]const u8{
            "wget", "-q", "-T", "10", "-O", "/dev/null",
            "--header", "content-type: application/json",
            "--post-file", "/dev/stdin",
            url,
        };
        sys.execvpZ("wget", &wget);
        std.process.exit(127);
    }
    sys.close(fds[0]);
    _ = sys.waitExitCode(pid);
    // Small enough for the pipe's buffer, so this doesn't block
    _ = sys.write(fds[1], json) catch {};
    sys.close(fds[1]);
}

test "line" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "abc;blocked;ws, a · fix;Allow Bash: ls -la",
        line(&buf, "abc", "blocked", "ws; a · fix", "Allow Bash:\nls -la").?,
    );
}
