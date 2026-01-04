const std = @import("std");
const xev = @import("xev");
const posix = std.posix;

const Master = @import("master.zig").Master;
const client_mod = @import("client.zig");
const Client = client_mod.Client;
const ClientOptions = client_mod.ClientOptions;
const RingBuffer = @import("ringbuffer.zig").RingBuffer;
const picker_mod = @import("picker.zig");

pub const Protocol = @import("protocol.zig");

/// Version string - increment when making changes that require redeployment
/// 1.4.0 - Added shell integration (OSC 133) for input detection
/// 1.4.1 - Fixed SIGWINCH handling to check on every loop iteration
/// 1.5.0 - Limit initial scrollback to 16KB for faster reconnects
/// 1.6.0 - Add request_scrollback for on-demand old scrollback loading
/// 1.6.1 - Fix ResponseHeader padding (use packed struct for exact 5-byte header)
/// 1.7.0 - Add client_id to attach packet to prevent duplicate connections from same device
/// 1.8.0 - Skip scrollback on attach when in alternate screen mode (fixes TUI app corruption)
/// 1.8.1 - Remove OSC 133 from shell integration (caused resize bugs in Ghostty)
/// 1.8.2 - Track and restore cursor visibility state on reconnect (fixes dual cursor in Claude Code)
/// 1.8.3 - Performance: ReleaseFast, writev for scrollback, debug logs in hot paths
/// 1.8.4 - Explicit SIGWINCH to process group on window size change (fixes TUI redraw)
/// 1.9.0 - Command pipe: scripts write to $RTACH_CMD_FD to send commands to Clauntty
/// 2.0.0 - Framed protocol: ALL data from rtach is now framed [type][len][payload]
///         Adds handshake on attach with magic "RTCH" and protocol version.
///         Fixes race conditions where terminal data was misinterpreted as protocol headers.
/// 2.0.1 - Send alternate screen escape sequence on reconnect (fixes "@" artifact in Claude Code)
/// 2.1.0 - Pause/resume/idle: Battery optimization for inactive tabs.
///         New messages: pause(8), resume(9) from client; idle(4) from server.
///         Paused clients don't receive streaming data; buffered output flushed on resume.
///         Idle notification sent after 2s of no PTY output (enables background notifications).
/// 2.1.1 - Debug logging to /tmp/rtach-debug.log
/// 2.1.2 - More detailed packet reception and idle timer logging
/// 2.1.3 - Add PID to log prefix for multi-session debugging
/// 2.1.4 - Fix: client.zig now forwards pause/resume packets to master
/// 2.2.0 - Phase 2 network optimization complete: pause/resume/idle working
/// 2.3.0 - OSC 0/1/2 title parsing: saves terminal title to .title file for session picker
/// 2.4.0 - Shell integration: bash/zsh/fish set title to current directory and running command
/// 2.5.0 - FIFO command channel: RTACH_CMD_PIPE env var points to named FIFO for commands
///         Scripts write to this path (works even when spawned by Claude Code which closes FDs)
/// 2.5.1 - Fix: client.zig stdin buffer increased from 256 to 4096 bytes, added partial packet buffering
///         This fixes multiline paste where packets > 256 bytes were being dropped
/// 2.5.2 - Fix: writeTitleToFile now uses cwd-relative file operations instead of *Absolute
///         This fixes a panic when rtach is invoked with a relative socket path
/// 2.5.3 - Per-session log files: logs now go to {socket_path}.log instead of /tmp/rtach-debug.log
///         Build: `zig build cross` now defaults to ReleaseFast, use `cross-debug` for debug builds
/// 2.6.0 - Compression: terminal_data payloads are now zlib-compressed when beneficial.
///         High bit (0x80) of response type indicates compressed payload.
///         Reduces bandwidth by 30-60% for typical terminal output.
/// 2.6.2 - Diagnostics: Added signal handlers, heartbeat logging, allocation failure logging.
///         Signals (SIGTERM, SIGPIPE, SIGSEGV, etc.) now logged before process exit.
///         Heartbeat logs every 5 minutes to confirm master is alive.
/// 2.6.3 - Fix: Always send SIGWINCH on resume to trigger TUI repaint.
///         Fixes frozen Claude Code after switching back to inactive tab.
/// 2.6.4 - Fix: Resume now uses a monotonic counter to flush buffered output correctly.
/// 2.6.5 - Fix: Proxy client waits for iOS upgrade before upgrading master.
/// 2.6.6 - Fix: Explicit proxy mode flag to avoid TTY detection mismatch.
/// 2.7.0 - Interactive session picker: run 'rtach' with no args to select a session.
pub const version = "2.7.0";

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = timestampedLog,
};

/// Custom log function that adds timestamp and PID prefix
fn timestampedLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    const level_prefix = switch (level) {
        .err => "ERR ",
        .warn => "WARN",
        .info => "INFO",
        .debug => "DBG ",
    };

    // Get current time for timestamp
    const now_ns = std.time.nanoTimestamp();
    const now_s = @divFloor(now_ns, std.time.ns_per_s);
    const subsec_ms = @divFloor(@rem(now_ns, std.time.ns_per_s), std.time.ns_per_ms);

    // Get process ID (cross-platform)
    const pid = std.c.getpid();

    // Write to stderr using posix.write (zig 0.15 compatible)
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[{d}.{d:0>3}][{d}] {s} {s}" ++ format ++ "\n", .{ now_s, subsec_ms, pid, level_prefix, scope_prefix } ++ args) catch return;
    _ = std.posix.write(std.posix.STDERR_FILENO, msg) catch {};
}

const Args = struct {
    mode: Mode,
    socket_path: []const u8,
    command: ?[]const u8 = null,
    redraw_method: ClientOptions.RedrawMethod = .none,
    no_detach_char: bool = false,
    detach_char: u8 = 0x1c, // Ctrl+\ by default
    scrollback_size: usize = 1024 * 1024, // 1MB default
    client_id: ?[Protocol.CLIENT_ID_SIZE]u8 = null, // Unique client identifier (UUID)
    proxy_mode: bool = false,

    const Mode = enum {
        create, // -c: Create new session, attach to it
        create_or_attach, // -A: Create if needed, attach
        attach, // -a: Attach to existing
        create_detached, // -n: Create detached (no attach)
        picker, // No args: show interactive session picker
    };
};

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = parseArgs(allocator) catch {
        // Don't print to stderr - it goes to SSH and corrupts protocol
        std.process.exit(1);
    };

    // Note: We catch all errors silently because stderr goes to the SSH channel
    // and would corrupt the framed protocol. Exit codes indicate success/failure.
    switch (args.mode) {
        .picker => {
            // Interactive session picker
            const result = picker_mod.showPicker(allocator) catch std.process.exit(1);
            switch (result) {
                .new_session => {
                    // Generate new session ID and create
                    const session_id = generateSessionId() catch std.process.exit(1);
                    var new_args = args;
                    new_args.socket_path = buildSessionPath(allocator, &session_id) catch std.process.exit(1);
                    new_args.mode = .create_or_attach;
                    createAndAttach(allocator, new_args, false) catch std.process.exit(1);
                },
                .existing => |session_id| {
                    // Attach to existing session
                    var new_args = args;
                    new_args.socket_path = buildSessionPath(allocator, session_id) catch std.process.exit(1);
                    new_args.mode = .attach;
                    attach(allocator, new_args) catch std.process.exit(1);
                },
                .quit => std.process.exit(0),
            }
        },
        .create => {
            // Create new session and attach
            createAndAttach(allocator, args, false) catch std.process.exit(1);
        },
        .create_or_attach => {
            // Try to attach, create if doesn't exist
            if (socketExists(args.socket_path)) {
                attach(allocator, args) catch std.process.exit(1);
            } else {
                createAndAttach(allocator, args, false) catch std.process.exit(1);
            }
        },
        .attach => {
            // Attach only, fail if doesn't exist
            attach(allocator, args) catch std.process.exit(1);
        },
        .create_detached => {
            // Create detached (master only, no client)
            createAndAttach(allocator, args, true) catch std.process.exit(1);
        },
    }
}

fn createAndAttach(allocator: std.mem.Allocator, args: Args, detached: bool) !void {
    const command = args.command orelse std.posix.getenv("SHELL") orelse "/bin/sh";

    // Fork: child becomes master (can properly daemonize), parent becomes client
    const pid = try posix.fork();

    if (pid == 0) {
        // Child becomes the master (daemon)
        // setsid() works here because child is not a process group leader
        _ = posix.setsid() catch {};

        // Redirect stdin to /dev/null, but stderr to a log file for debugging
        const dev_null = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch null;
        if (dev_null) |null_fd| {
            posix.dup2(null_fd, posix.STDIN_FILENO) catch {};
            posix.dup2(null_fd, posix.STDOUT_FILENO) catch {};
            if (null_fd > 2) posix.close(null_fd);
        }

        // Open per-session log file for stderr (debug logging)
        // Uses {socket_path}.log so logs are easy to correlate with sessions
        var log_path_buf: [512]u8 = undefined;
        const log_path = std.fmt.bufPrint(&log_path_buf, "{s}.log", .{args.socket_path}) catch null;
        if (log_path) |path| {
            // Null-terminate for posix.open
            var path_z: [513]u8 = undefined;
            @memcpy(path_z[0..path.len], path);
            path_z[path.len] = 0;
            const log_fd = posix.open(path_z[0..path.len :0], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch null;
            if (log_fd) |fd| {
                posix.dup2(fd, posix.STDERR_FILENO) catch {};
                if (fd > 2) posix.close(fd);
            }
        }

        var master = Master.init(allocator, .{
            .socket_path = args.socket_path,
            .command = command,
            .scrollback_size = args.scrollback_size,
        }) catch posix.exit(1);
        defer master.deinit();

        master.run() catch posix.exit(1);
        posix.exit(0);
    } else {
        // Parent becomes client (or exits if detached)
        if (detached) {
            // Detached mode: just exit, master runs in background
            return;
        }
        // Small delay to let master set up
        std.Thread.sleep(50 * std.time.ns_per_ms);
        // Attach to the session we just created
        try attach(allocator, args);
    }
}

fn attach(allocator: std.mem.Allocator, args: Args) !void {
    var client = try Client.init(allocator, .{
        .socket_path = args.socket_path,
        .detach_char = if (args.no_detach_char) null else args.detach_char,
        .redraw_method = args.redraw_method,
        .client_id = args.client_id,
        .proxy_mode = args.proxy_mode,
    });
    defer client.deinit();

    try client.run();
}

fn socketExists(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    return stat.kind == .unix_domain_socket;
}

/// Generate a new UUID-format session ID
fn generateSessionId() ![36]u8 {
    var uuid_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&uuid_bytes);

    // Set version (4) and variant bits
    uuid_bytes[6] = (uuid_bytes[6] & 0x0f) | 0x40; // Version 4
    uuid_bytes[8] = (uuid_bytes[8] & 0x3f) | 0x80; // Variant 1

    // Format as UUID string with dashes
    var result: [36]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}", .{
        std.mem.readInt(u32, uuid_bytes[0..4], .big),
        std.mem.readInt(u16, uuid_bytes[4..6], .big),
        std.mem.readInt(u16, uuid_bytes[6..8], .big),
        std.mem.readInt(u16, uuid_bytes[8..10], .big),
        std.mem.readInt(u48, uuid_bytes[10..16], .big),
    }) catch unreachable;

    return result;
}

/// Build full socket path from session ID
fn buildSessionPath(allocator: std.mem.Allocator, session_id: []const u8) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.clauntty/sessions/{s}", .{ home, session_id });
}

/// Parse UUID string (with or without dashes) to 16-byte array
fn parseClientId(id_str: []const u8) ?[Protocol.CLIENT_ID_SIZE]u8 {
    var result: [Protocol.CLIENT_ID_SIZE]u8 = undefined;
    var out_idx: usize = 0;

    var i: usize = 0;
    while (i < id_str.len and out_idx < Protocol.CLIENT_ID_SIZE) {
        // Skip dashes
        if (id_str[i] == '-') {
            i += 1;
            continue;
        }

        // Need at least 2 hex chars
        if (i + 1 >= id_str.len) break;

        const high = std.fmt.charToDigit(id_str[i], 16) catch return null;
        const low = std.fmt.charToDigit(id_str[i + 1], 16) catch return null;
        result[out_idx] = (high << 4) | low;
        out_idx += 1;
        i += 2;
    }

    if (out_idx != Protocol.CLIENT_ID_SIZE) return null;
    return result;
}

fn parseArgs(allocator: std.mem.Allocator) !Args {
    _ = allocator;
    var args_iter = std.process.args();
    _ = args_iter.skip(); // Skip program name

    var result = Args{
        .mode = .create_or_attach,
        .socket_path = "",
    };

    var found_socket = false;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            // Print version and exit
            const stdout = std.posix.STDOUT_FILENO;
            _ = std.posix.write(stdout, version ++ "\n") catch {};
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-c")) {
            result.mode = .create;
        } else if (std.mem.eql(u8, arg, "-A")) {
            result.mode = .create_or_attach;
        } else if (std.mem.eql(u8, arg, "-a")) {
            result.mode = .attach;
        } else if (std.mem.eql(u8, arg, "-n")) {
            result.mode = .create_detached;
        } else if (std.mem.eql(u8, arg, "-r")) {
            if (args_iter.next()) |method| {
                if (std.mem.eql(u8, method, "ctrl_l")) {
                    result.redraw_method = .ctrl_l;
                } else if (std.mem.eql(u8, method, "winch")) {
                    result.redraw_method = .winch;
                } else if (std.mem.eql(u8, method, "none")) {
                    result.redraw_method = .none;
                }
            }
        } else if (std.mem.eql(u8, arg, "-e")) {
            if (args_iter.next()) |char_str| {
                if (char_str.len > 0) {
                    if (char_str[0] == '^' and char_str.len == 2) {
                        // ^X format
                        result.detach_char = char_str[1] & 0x1f;
                    } else {
                        result.detach_char = char_str[0];
                    }
                }
            }
        } else if (std.mem.eql(u8, arg, "-E")) {
            result.no_detach_char = true;
        } else if (std.mem.eql(u8, arg, "--proxy")) {
            result.proxy_mode = true;
        } else if (std.mem.eql(u8, arg, "-s")) {
            if (args_iter.next()) |size_str| {
                result.scrollback_size = std.fmt.parseInt(usize, size_str, 10) catch 1024 * 1024;
            }
        } else if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--client-id")) {
            // Parse client ID as UUID string (32 hex chars or 36 with dashes)
            if (args_iter.next()) |id_str| {
                result.client_id = parseClientId(id_str);
            }
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            std.process.exit(0);
        } else if (!found_socket) {
            result.socket_path = arg;
            found_socket = true;
        } else {
            // Everything after socket path is the command
            result.command = arg;
        }
    }

    if (!found_socket or result.socket_path.len == 0) {
        // No socket path given - enter interactive picker mode
        result.mode = .picker;
    }

    return result;
}

fn printUsage() void {
    const usage =
        \\rtach - persistent terminal sessions with scrollback
        \\
        \\Usage: rtach [options] [socket] [command]
        \\
        \\If no socket is given, shows an interactive session picker.
        \\
        \\Options:
        \\  -c          Create new session and attach
        \\  -A          Create if needed, attach (default)
        \\  -a          Attach to existing session
        \\  -n          Create detached (no attach)
        \\  -e CHAR     Set detach character (default: ^\)
        \\  -E          Disable detach character
        \\  --proxy     Proxy mode (forward handshake, wait for client upgrade)
        \\  -r METHOD   Redraw method: none, ctrl_l, winch
        \\  -s SIZE     Scrollback buffer size in bytes (default: 1MB)
        \\  -C UUID     Client ID for deduplication
        \\  -v          Print version
        \\  -h          Print this help
        \\
        \\Examples:
        \\  rtach                           # Interactive session picker
        \\  rtach -A ~/.rtach/session $SHELL
        \\  rtach -a ~/.rtach/session
        \\
    ;
    const stdout = std.posix.STDOUT_FILENO;
    _ = std.posix.write(stdout, usage) catch {};
}

test {
    _ = @import("ringbuffer.zig");
    _ = @import("protocol.zig");
    _ = @import("master.zig");
    _ = @import("client.zig");
    _ = @import("compression.zig");
    _ = @import("picker.zig");
}
