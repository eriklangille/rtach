const std = @import("std");
const xev = @import("xev");
const posix = std.posix;

const Master = @import("master.zig").Master;
const client_mod = @import("client.zig");
const Client = client_mod.Client;
const ClientOptions = client_mod.ClientOptions;
const RingBuffer = @import("ringbuffer.zig").RingBuffer;

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
/// 2.0.0 - Paginated scrollback (request_scrollback_page) to prevent iOS watchdog kills
pub const version = "2.0.0";

pub const std_options: std.Options = .{
    .log_level = .info,
};

const Args = struct {
    mode: Mode,
    socket_path: []const u8,
    command: ?[]const u8 = null,
    redraw_method: ClientOptions.RedrawMethod = .none,
    no_detach_char: bool = false,
    detach_char: u8 = 0x1c, // Ctrl+\ by default
    scrollback_size: usize = 1024 * 1024, // 1MB default
    client_id: ?[Protocol.CLIENT_ID_SIZE]u8 = null, // Unique client identifier (UUID)

    const Mode = enum {
        create, // -c: Create new session, attach to it
        create_or_attach, // -A: Create if needed, attach
        attach, // -a: Attach to existing
        create_detached, // -n: Create detached (no attach)
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);

    switch (args.mode) {
        .create => {
            // Create new session and attach
            try createAndAttach(allocator, args, false);
        },
        .create_or_attach => {
            // Try to attach, create if doesn't exist
            if (socketExists(args.socket_path)) {
                try attach(allocator, args);
            } else {
                try createAndAttach(allocator, args, false);
            }
        },
        .attach => {
            // Attach only, fail if doesn't exist
            try attach(allocator, args);
        },
        .create_detached => {
            // Create detached (master only, no client)
            try createAndAttach(allocator, args, true);
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

        // Redirect stdin/stdout/stderr to /dev/null to fully detach from terminal
        const dev_null = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch null;
        if (dev_null) |null_fd| {
            posix.dup2(null_fd, posix.STDIN_FILENO) catch {};
            posix.dup2(null_fd, posix.STDOUT_FILENO) catch {};
            posix.dup2(null_fd, posix.STDERR_FILENO) catch {};
            if (null_fd > 2) posix.close(null_fd);
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
    });
    defer client.deinit();

    try client.run();
}

fn socketExists(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    return stat.kind == .unix_domain_socket;
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
        std.debug.print("Error: socket path required\n\n", .{});
        printUsage();
        std.process.exit(1);
    }

    return result;
}

fn printUsage() void {
    const usage =
        \\rtach - terminal session manager with scrollback
        \\
        \\Usage: rtach [options] <socket> [command]
        \\
        \\Modes:
        \\  -A <socket>    Create session or attach if exists (default)
        \\  -a <socket>    Attach to existing session only
        \\  -c <socket>    Create new session and attach
        \\  -n <socket>    Create new session, don't attach (detached)
        \\
        \\Options:
        \\  -e <char>      Set detach character (default: ^\)
        \\  -E             Disable detach character
        \\  -r <method>    Redraw on attach: none, ctrl_l, winch
        \\  -s <bytes>     Scrollback buffer size (default: 1048576)
        \\  -h, --help     Show this help
        \\
        \\Examples:
        \\  rtach -A /tmp/session bash
        \\  rtach -a /tmp/session
        \\  rtach -A /tmp/claude -s 4194304 claude
        \\
    ;
    std.debug.print("{s}", .{usage});
}

test {
    _ = @import("ringbuffer.zig");
    _ = @import("protocol.zig");
    _ = @import("master.zig");
    _ = @import("client.zig");
}
