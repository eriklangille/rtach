//! `rtach spawnd`: starts session masters in the macOS desktop (Aqua) session.
//!
//! A master started over SSH lands in the Background session, where the login
//! keychain isn't available, so code signing fails inside the session. spawnd is a
//! LaunchAgent in the desktop session: launchd listens on its socket and starts it
//! on the first connection. When a client has to create a master and spawnd
//! answers, spawnd runs `<the client's rtach> --no-spawnd -n <socket> ...` with the
//! client's environment and working directory, and the client attaches as usual.
//! The master inherits spawnd's session. Without spawnd the client starts the
//! master itself, as on Linux.
//!
//! Request: NUL-terminated strings: cwd, argc, argv[0..argc], then the environment
//! (KEY=VALUE) until the client shuts down its side. Reply: one byte, the exit code
//! of the command (0: the master listens).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const sys = @import("sys.zig");

const log = std.log.scoped(.spawnd);

pub const supported = builtin.os.tag == .macos;

const label = "com.clauntty.rtach-spawnd";

/// Started by launchd, it exits after this long without requests. launchd keeps the
/// socket and starts it again on the next connection.
const idle_exit_ms = 60_000;
const max_request = 1 << 20;
const max_argc = 32;

/// $RTACH_SPAWND_SOCKET if set (empty: don't use spawnd), else ~/.clauntty/spawnd.sock
fn socketPath(buf: []u8) ?[]const u8 {
    if (sys.getenv("RTACH_SPAWND_SOCKET")) |path| return if (path.len == 0) null else path;
    const home = sys.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.clauntty/spawnd.sock", .{home}) catch null;
}

// MARK: Client

pub const MasterOptions = struct {
    socket_path: []const u8,
    command: ?[]const u8,
    scrollback_size: usize,
};

pub const Result = enum {
    /// No spawnd here: start the master as before
    unavailable,
    started,
    /// spawnd answered the connection but didn't report a master. launchd accepts
    /// connections even when it can't start spawnd (its program is missing, say),
    /// and a slow spawnd may still start one.
    failed,
};

/// Ask spawnd to start a master
pub fn startMaster(allocator: std.mem.Allocator, io: std.Io, options: MasterOptions) Result {
    if (!supported) return .unavailable;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = socketPath(&path_buf) orelse return .unavailable;

    const fd = sys.unixSocket(false) catch return .unavailable;
    defer sys.close(fd);
    sys.connect(fd, path) catch return .unavailable;

    const request = buildRequest(allocator, io, options) catch return .failed;
    defer allocator.free(request);
    writeAll(fd, request) catch return .failed;
    sys.shutdownWrite(fd);

    // Starting spawnd and a master takes well under a second. Longer, and the user
    // is looking at a frozen tab.
    sys.setRecvTimeout(fd, 3);
    var code: [1]u8 = undefined;
    const n = sys.read(fd, &code) catch return .failed;
    return if (n == 1 and code[0] == 0) .started else .failed;
}

fn buildRequest(allocator: std.mem.Allocator, io: std.Io, options: MasterOptions) ![]u8 {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = exe_buf[0..try std.process.executablePath(io, &exe_buf)];
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.NoCwd;
    const cwd = std.mem.sliceTo(cwd_ptr, 0);
    var size_buf: [24]u8 = undefined;
    const size = try std.fmt.bufPrint(&size_buf, "{d}", .{options.scrollback_size});

    var argv: [7][]const u8 = .{ exe, "--no-spawnd", "-n", "-s", size, options.socket_path, "" };
    var argc: usize = 6;
    if (options.command) |command| {
        argv[argc] = command;
        argc += 1;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendString(allocator, &out, cwd);
    var argc_buf: [8]u8 = undefined;
    try appendString(allocator, &out, try std.fmt.bufPrint(&argc_buf, "{d}", .{argc}));
    for (argv[0..argc]) |arg| try appendString(allocator, &out, arg);
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        try appendString(allocator, &out, std.mem.span(entry));
    }
    return out.toOwnedSlice(allocator);
}

fn appendString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    if (std.mem.indexOfScalar(u8, s, 0) != null) return error.NulInString;
    try out.appendSlice(allocator, s);
    try out.append(allocator, 0);
}

fn writeAll(fd: sys.fd_t, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) sent += try sys.write(fd, bytes[sent..]);
}

/// Shown at the top of a session that can't use the login keychain
pub const keychain_notice = "\x1b[2mrtach: this session isn't in the desktop session, so code signing and the " ++
    "login keychain don't work in it. For new sessions: rtach spawnd install\x1b[0m\n";

/// Whether this process is outside the macOS desktop (Aqua) session, as SSH logins are
pub fn outsideDesktopSession(allocator: std.mem.Allocator, io: std.Io) bool {
    if (!supported) return false;
    const result = std.process.run(allocator, io, .{ .argv = &.{ "/bin/launchctl", "managername" } }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return !std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \n"), "Aqua");
}

// MARK: Server

extern "c" fn launch_activate_socket(name: [*:0]const u8, fds: *?[*]c_int, count: *usize) c_int;

/// The socket launchd listens on for us, if launchd started us
fn launchdSocket() ?sys.fd_t {
    var fds: ?[*]c_int = null;
    var count: usize = 0;
    if (launch_activate_socket("Listeners", &fds, &count) != 0) return null;
    const list = fds orelse return null;
    defer std.c.free(list);
    for (list[1..count]) |extra| sys.close(extra);
    return if (count > 0) list[0] else null;
}

/// Run by hand (tests): listen on the socket ourselves
fn listenOn(path: []const u8) !sys.fd_t {
    sys.unlink(path);
    const fd = try sys.unixSocket(false);
    errdefer sys.close(fd);
    try sys.bindAndListen(fd, path, 64);
    var path_z: [std.fs.max_path_bytes:0]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    _ = std.c.chmod(&path_z, 0o600);
    return fd;
}

fn run(allocator: std.mem.Allocator) u8 {
    const from_launchd = launchdSocket();
    const listener = from_launchd orelse blk: {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = socketPath(&path_buf) orelse {
            log.err("no socket path (HOME isn't set)", .{});
            return 1;
        };
        break :blk listenOn(path) catch |err| {
            log.err("can't listen on {s}: {}", .{ path, err });
            return 1;
        };
    };
    sys.setCloexec(listener);
    log.info("listening ({s})", .{if (from_launchd != null) "launchd" else "own socket"});

    // A client that gives up before the reply mustn't kill us
    var ignore: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(posix.SIG.PIPE, &ignore, null);

    while (true) {
        const timeout: i32 = if (from_launchd != null) idle_exit_ms else -1;
        if (!sys.waitReadable(listener, timeout)) {
            log.info("idle, exiting", .{});
            return 0;
        }
        const conn = sys.accept(listener) catch continue;
        sys.setCloexec(conn);
        serve(allocator, conn);
        sys.close(conn);
    }
}

fn serve(allocator: std.mem.Allocator, conn: sys.fd_t) void {
    const uid = sys.peerUid(conn) orelse return;
    if (uid != std.c.getuid()) {
        log.warn("refused a request from uid {d}", .{uid});
        return;
    }
    sys.setRecvTimeout(conn, 5);
    const request = readRequest(allocator, conn) catch |err| {
        log.warn("bad request: {}", .{err});
        return;
    };
    defer allocator.free(request);
    // A connection that sends nothing checks that spawnd answers (`status`)
    if (request.len == 0) return;

    const code = spawn(allocator, request) catch |err| blk: {
        log.err("can't start a master: {}", .{err});
        break :blk 255;
    };
    _ = sys.write(conn, &.{code}) catch {};
}

fn readRequest(allocator: std.mem.Allocator, conn: sys.fd_t) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = try sys.read(conn, &buf);
        if (n == 0) break;
        if (out.items.len + n > max_request) return error.RequestTooLarge;
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

/// Run the request's command and wait for it. Its exit code, 255 if killed.
fn spawn(allocator: std.mem.Allocator, request: []const u8) !u8 {
    // Every string ends in a NUL, so pointers into the request are C strings
    if (request.len == 0 or request[request.len - 1] != 0) return error.BadRequest;
    var strings = std.mem.splitScalar(u8, request[0 .. request.len - 1], 0);

    const cwd = strings.next() orelse return error.BadRequest;
    const argc = std.fmt.parseInt(usize, strings.next() orelse return error.BadRequest, 10) catch return error.BadRequest;
    if (argc == 0 or argc > max_argc) return error.BadRequest;

    var argv: [max_argc + 1]?[*:0]const u8 = @splat(null);
    for (0..argc) |i| argv[i] = @ptrCast((strings.next() orelse return error.BadRequest).ptr);
    const program = std.mem.span(argv[0].?);
    if (!std.fs.path.isAbsolute(program)) return error.BadRequest;

    var env: std.ArrayList(?[*:0]const u8) = .empty;
    defer env.deinit(allocator);
    while (strings.next()) |entry| try env.append(allocator, @ptrCast(entry.ptr));
    try env.append(allocator, null);

    const pid = try sys.fork();
    if (pid == 0) {
        _ = std.c.chdir(@ptrCast(cwd.ptr));
        sys.execveZ(argv[0].?, @ptrCast(&argv), @ptrCast(env.items.ptr));
        std.process.exit(127);
    }
    const code = sys.waitExitCode(pid) orelse 255;
    log.info("ran {s} ... {s}: exit {d}", .{ program, std.mem.span(argv[argc - 1].?), code });
    return code;
}

// MARK: Install

const Paths = struct {
    program: []const u8,
    plist: []const u8,
    socket: []const u8,
    log: []const u8,

    fn init(allocator: std.mem.Allocator) !Paths {
        const home = sys.getenv("HOME") orelse return error.NoHome;
        return .{
            .program = try std.fmt.allocPrint(allocator, "{s}/.clauntty/bin/rtach-spawnd", .{home}),
            .plist = try std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents/" ++ label ++ ".plist", .{home}),
            .socket = try std.fmt.allocPrint(allocator, "{s}/.clauntty/spawnd.sock", .{home}),
            .log = try std.fmt.allocPrint(allocator, "{s}/.clauntty/spawnd.log", .{home}),
        };
    }
};

fn plistContents(allocator: std.mem.Allocator, paths: Paths) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<!-- Written by `rtach spawnd install`. Starts rtach sessions in the desktop
        \\     session, so they can use the login keychain (code signing). -->
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>{s}</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>{f}</string>
        \\        <string>spawnd</string>
        \\        <string>run</string>
        \\    </array>
        \\    <key>Sockets</key>
        \\    <dict>
        \\        <key>Listeners</key>
        \\        <dict>
        \\            <key>SockPathName</key>
        \\            <string>{f}</string>
        \\            <key>SockPathMode</key>
        \\            <integer>384</integer>
        \\        </dict>
        \\    </dict>
        \\    <key>LimitLoadToSessionType</key>
        \\    <string>Aqua</string>
        \\    <key>ProcessType</key>
        \\    <string>Interactive</string>
        \\    <key>AbandonProcessGroup</key>
        \\    <true/>
        \\    <key>StandardErrorPath</key>
        \\    <string>{f}</string>
        \\</dict>
        \\</plist>
        \\
    , .{ label, xml(paths.program), xml(paths.socket), xml(paths.log) });
}

fn xml(s: []const u8) XmlText {
    return .{ .s = s };
}

const XmlText = struct {
    s: []const u8,

    pub fn format(self: XmlText, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.s) |c| switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            else => try writer.writeByte(c),
        };
    }
};

fn launchctl(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
    const result = std.process.run(allocator, io, .{ .argv = argv }) catch return false;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

/// Write `data` to a temp file and rename it over `path`
fn replaceFile(io: std.Io, path: []const u8, data: []const u8, mode: posix.mode_t) !void {
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.{d}.tmp", .{ path, std.c.getpid() });
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = data, .flags = .{ .permissions = .fromMode(mode) } });
    cwd.rename(tmp, cwd, path, io) catch |err| {
        cwd.deleteFile(io, tmp) catch {};
        return err;
    };
}

fn install(allocator: std.mem.Allocator, io: std.Io) !void {
    const paths = try Paths.init(allocator);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, std.fs.path.dirname(paths.program).?);
    try cwd.createDirPath(io, std.fs.path.dirname(paths.plist).?);

    // Its own copy: the app deletes old versioned rtach binaries (rtach-<version>). launchd starts the
    // program fresh after each idle exit, so a new copy takes over by itself.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = exe_buf[0..try std.process.executablePath(io, &exe_buf)];
    if (!std.mem.eql(u8, exe, paths.program)) {
        const program = try cwd.readFileAlloc(io, exe, allocator, .limited(64 * 1024 * 1024));
        try replaceFile(io, paths.program, program, 0o755);
    }

    const plist = try plistContents(allocator, paths);
    const unchanged = if (cwd.readFileAlloc(io, paths.plist, allocator, .limited(64 * 1024))) |old|
        std.mem.eql(u8, old, plist)
    else |_|
        false;
    if (!unchanged) try replaceFile(io, paths.plist, plist, 0o644);

    const domain = try std.fmt.allocPrint(allocator, "gui/{d}", .{std.c.getuid()});
    const service = try std.fmt.allocPrint(allocator, "{s}/" ++ label, .{domain});
    const loaded = launchctl(allocator, io, &.{ "launchctl", "print", service });
    if (loaded and unchanged) {
        say("spawnd is installed and loaded. New sessions start in the desktop session.\n", .{});
        return;
    }
    if (loaded) _ = launchctl(allocator, io, &.{ "launchctl", "bootout", service });
    // bootstrap can fail for a moment right after a bootout
    for (0..10) |_| {
        if (launchctl(allocator, io, &.{ "launchctl", "bootstrap", domain, paths.plist })) {
            say("spawnd is installed and loaded. New sessions start in the desktop session.\n", .{});
            return;
        }
        io.sleep(.fromMilliseconds(200), .awake) catch {};
    }
    say("spawnd is installed, but launchd didn't load it (is anyone logged in at the desktop?).\n" ++
        "It loads at the next desktop login, or run: launchctl bootstrap {s} {s}\n", .{ domain, paths.plist });
}

fn uninstall(allocator: std.mem.Allocator, io: std.Io) !void {
    const paths = try Paths.init(allocator);
    const service = try std.fmt.allocPrint(allocator, "gui/{d}/" ++ label, .{std.c.getuid()});
    _ = launchctl(allocator, io, &.{ "launchctl", "bootout", service });
    const cwd = std.Io.Dir.cwd();
    for ([_][]const u8{ paths.plist, paths.program, paths.socket }) |path| cwd.deleteFile(io, path) catch {};
    say("spawnd is uninstalled. Running sessions keep running.\n", .{});
}

fn status(allocator: std.mem.Allocator, io: std.Io) !u8 {
    const paths = try Paths.init(allocator);
    const service = try std.fmt.allocPrint(allocator, "gui/{d}/" ++ label, .{std.c.getuid()});
    const installed = if (std.Io.Dir.cwd().statFile(io, paths.plist, .{})) |_| true else |_| false;
    const loaded = launchctl(allocator, io, &.{ "launchctl", "print", service });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const answers = if (socketPath(&path_buf)) |path| blk: {
        const fd = sys.unixSocket(false) catch break :blk false;
        defer sys.close(fd);
        sys.connect(fd, path) catch break :blk false;
        break :blk true;
    } else false;
    say("installed: {}\nloaded: {}\nanswers: {}\n", .{ installed, loaded, answers });
    return if (answers) 0 else 1;
}

fn say(comptime format: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, format, args) catch return;
    _ = sys.write(posix.STDOUT_FILENO, msg) catch {};
}

const usage =
    \\Usage: rtach spawnd <command>
    \\
    \\Start rtach sessions in the macOS desktop session, so they can use the
    \\login keychain (code signing), even when the session is started over SSH.
    \\
    \\Commands:
    \\  install     Install and load the LaunchAgent (com.clauntty.rtach-spawnd)
    \\  uninstall   Unload and remove it; running sessions keep running
    \\  status      Show whether it's installed, loaded and answering
    \\  run         Serve requests (what launchd runs)
    \\
;

/// `rtach spawnd <command>`
pub fn main(allocator: std.mem.Allocator, io: std.Io, process_args: std.process.Args) u8 {
    if (!supported) {
        say("spawnd is only for macOS.\n", .{});
        return 1;
    }
    var args = process_args.iterate();
    _ = args.skip(); // rtach
    _ = args.skip(); // spawnd
    const command = args.next() orelse {
        say(usage, .{});
        return 2;
    };
    const eql = std.mem.eql;
    if (eql(u8, command, "run")) return run(allocator);
    if (eql(u8, command, "status")) return status(allocator, io) catch 1;
    const result = if (eql(u8, command, "install"))
        install(allocator, io)
    else if (eql(u8, command, "uninstall"))
        uninstall(allocator, io)
    else {
        say(usage, .{});
        return 2;
    };
    result catch |err| {
        say("spawnd {s} failed: {s}\n", .{ command, @errorName(err) });
        return 1;
    };
    return 0;
}
