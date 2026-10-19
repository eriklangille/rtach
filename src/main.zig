const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");

const Master = @import("master.zig").Master;
const client_mod = @import("client.zig");
const Client = client_mod.Client;
const ClientOptions = client_mod.ClientOptions;
const RingBuffer = @import("ringbuffer.zig").RingBuffer;
const picker_mod = @import("picker.zig");
const cli = @import("cli.zig");
const spawnd = @import("spawnd.zig");
const ws = @import("ws.zig");
const upgrade = @import("upgrade.zig");
const sweep = @import("sweep.zig");

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
/// 2.7.1 - Set BROWSER env var to open-browser for CLI tools (gh, python, etc.)
/// 2.7.2 - Active client claims for window size + command routing.
/// 2.8.2 - Fix: restore mouse, bracketed paste, focus and cursor-key modes on attach.
/// 2.9.0 - `clauntty` command (argv[0] clauntty/open-browser/forward-port/open-tab):
///         open, forward, tab, show <image>, status. Outside rtach sessions it finds
///         the machine's active session via ~/.clauntty/active, written on claim_active.
///         Shell integration adds ~/.clauntty/bin to PATH. Command lines up to 4KB.
/// 2.9.1 - Built with Zig 0.16 and upstream libxev (no behavior change).
/// 2.9.2 - Log timestamps print milliseconds without a "+" sign.
///         Fix: client detaches when stdin hangs up instead of spinning in poll.
/// 2.10.0 - `clauntty show` also leaves each image in ~/.clauntty/inbox/<id> and sends
///          `image;<id>;<path>`. The app deletes entries it has shown and checks the
///          inbox when it connects, so images sent while it's in the background wait.
/// 2.10.1 - Fix: a client kicked by a reattach with the same client id is removed. On
///          macOS it stayed in the client list forever (one more per phone reconnect).
/// 2.11.0 - The PTY takes the size of the client in use, and the next client's size
///          when that one pauses, detaches or disconnects.
/// 2.11.1 - Fix: concurrent `-A` on one session started a master each. `-A` now starts
///          one under {socket}.lock, after checking that nothing answers on the socket
///          (a stale socket no longer fails the attach). A master removes its socket
///          and FIFO on exit only if they're still its own.
/// 2.11.2 - The "shell setup" log line goes to the session log instead of showing at
///          the top of every new session.
/// 2.12.0 - macOS: `rtach spawnd install` adds a LaunchAgent that starts masters in the
///          desktop session, so sessions started over SSH can use the login keychain
///          (code signing). Clients use it when it answers.
/// 2.12.1 - A client waits 3s, not 10s, for a spawnd that launchd can't start (the
///          app's cleanup of old binaries deleted rtach-spawnd), and attaches if the
///          master started anyway.
/// 2.12.2 - A macOS session started outside the desktop session without spawnd says at
///          the top that code signing won't work in it, and how to fix that.
/// 2.13.0 - `rtach ws`: workspaces, tabs and split layouts over sessions, in
///          ~/.clauntty/workspaces. Sessions get RTACH_SESSION_ID and RTACH_SOCKET.
/// 2.13.1 - Fix: a session started without a terminal (the app's `rtach ws` over a
///          plain SSH command) got TERM=dumb and no locale, so zsh garbled typing.
///          Sessions default to TERM=xterm-256color and a UTF-8 LANG.
/// 2.13.2 - Fix: also replace a TERM terminfo doesn't know (login gives commands run
///          without a terminal a placeholder), and start the PTY at 80x24, not 0x0.
/// 2.14.0 - `rtach ws` changes tell the Clauntty app (`workspace;<ws>/<pane>`), which
///          shows a new pane right away. `--quiet` for the app's own commands.
/// 2.14.1 - Outside rtach, `rtach ws` PANE arguments default to the pane the app shows.
/// 2.15.0 - `rtach ws add SESSION...` (sessions become one-pane workspaces) and
///          `rtach ws end WS`: the app makes every tab a workspace.
/// 2.16.0 - Pane state: the master tracks the foreground program and its directory,
///          and an agent's state from `clauntty agent-state` hooks or Claude Code's
///          title. It writes <socket>.state and sends `pane;<id>;<json>` to the app.
///          `ws list` includes it; `ws split` starts in the pane's directory.
/// 2.17.0 - Pane state has the agent's task: the last prompt the user sent (from the
///          UserPromptSubmit hook), for the app's title when Claude hasn't named one.
/// 2.18.0 - Push notifications: an agent that finishes or is blocked while the app is
///          away is posted, with curl, to each phone's push Worker in ~/.clauntty/push.
/// 2.19.0 - Live upgrade: `upgrade;<rtach>` on a session's command pipe makes its master
///          exec the newer binary with `--resume`, keeping the PTY, shell and scrollback.
///          `rtach upgrade` asks every older master on the machine. Pane state has the
///          master's version (`"rtach"`).
/// 2.19.1 - `-a` exits 3 when the session doesn't exist, so the app can tell a closed
///          session from a dropped connection (it no longer re-creates one with -A)
/// 2.20.0 - `clauntty ws` (same as `rtach ws`); `ws new|tab|split ... -- CMD` types CMD
///          at the new pane's first prompt; a new session's shell always gets the
///          integration, even when started from another pane
/// 2.21.0 - `clauntty show` says which pane sent the image (`image;<id>;<pane>;<path>`,
///          and a second line in the inbox entry) and goes through the session the app
///          shows, so the app puts it in that pane's window right away
/// 2.22.0 - A session that ends (its shell exits, or it's stopped) sends `ended` to its
///          clients first, so the app ends the window without reconnecting to check
/// 2.22.1 - A session that ends removes its .state and .title files (they piled up)
/// 2.23.0 - A session that ends normally removes its .log too. `rtach sweep` clears
///          what crashed or killed sessions left, keeping their logs for 7 days.
/// 2.23.1 - A session's shell doesn't get the Claude Code session variables of whoever
///          started it (an agent running `clauntty ws new -- claude`)
/// 2.24.0 - A `ws` pane starts with a fresh environment, as a session the app opens:
///          who the user is, TERM and the locale from the caller, the system PATH, then
///          the shell's startup files. Replaces 2.23.1's list of Claude Code variables.
/// 2.24.1 - zsh reads the user's .zshenv, .zlogin and .zlogout too, and their ZDOTDIR
///          if .zshenv sets one; macOS's default history file is theirs, not ours
pub const version = "2.24.1";

/// `-a`'s exit code when the session doesn't exist (it ended)
pub const no_session_exit: u8 = 3;

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
    const now_ns = sys.realtimeNs();
    const now_s = @divFloor(now_ns, std.time.ns_per_s);
    // Unsigned: a signed value with a width prints a sign ("+484")
    const subsec_ms: u16 = @intCast(@divFloor(@mod(now_ns, std.time.ns_per_s), std.time.ns_per_ms));

    // Get process ID (cross-platform)
    const pid = std.c.getpid();

    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[{d}.{d:0>3}][{d}] {s} {s}" ++ format ++ "\n", .{ now_s, subsec_ms, pid, level_prefix, scope_prefix } ++ args) catch return;
    _ = sys.write(posix.STDERR_FILENO, msg) catch {};
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
    /// Start the master here even if spawnd could (spawnd's own request)
    no_spawnd: bool = false,

    const Mode = enum {
        create, // -c: Create new session, attach to it
        create_or_attach, // -A: Create if needed, attach
        attach, // -a: Attach to existing
        create_detached, // -n: Create detached (no attach)
        picker, // No args: show interactive session picker
    };
};

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;
    const io = init.io;

    // Invoked as `clauntty` (or an older helper name): send a command to the app
    var argv = init.minimal.args.iterate();
    if (argv.next()) |argv0| {
        if (cli.isCommandName(argv0)) std.process.exit(cli.main(allocator, io, init.minimal.args));
    }
    if (argv.next()) |arg1| {
        if (std.mem.eql(u8, arg1, "spawnd")) std.process.exit(spawnd.main(allocator, io, init.minimal.args));
        if (std.mem.eql(u8, arg1, "ws")) std.process.exit(ws.main(allocator, io, init.minimal.args));
        if (std.mem.eql(u8, arg1, "upgrade")) std.process.exit(upgrade.main(allocator, io, init.minimal.args));
        if (std.mem.eql(u8, arg1, "sweep")) std.process.exit(sweep.main(allocator, io, init.minimal.args));
        if (std.mem.eql(u8, arg1, "--resume")) resumeMaster(allocator, io, init.minimal.args);
    }

    const args = parseArgs(init.minimal.args) catch {
        // Don't print to stderr - it goes to SSH and corrupts protocol
        std.process.exit(1);
    };

    // Note: We catch all errors silently because stderr goes to the SSH channel
    // and would corrupt the framed protocol. Exit codes indicate success/failure.
    switch (args.mode) {
        .picker => {
            // Interactive session picker
            const result = picker_mod.showPicker(allocator, io) catch std.process.exit(1);
            switch (result) {
                .new_session => {
                    // Generate new session ID and create
                    const session_id = generateSessionId(io) catch std.process.exit(1);
                    var new_args = args;
                    new_args.socket_path = buildSessionPath(allocator, &session_id) catch std.process.exit(1);
                    new_args.mode = .create_or_attach;
                    createAndAttach(allocator, io, new_args, false, null) catch std.process.exit(1);
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
            createAndAttach(allocator, io, args, false, null) catch std.process.exit(1);
        },
        .create_or_attach => {
            // One -A per session at a time decides whether to start a master, so two
            // can't both start one. The lock is held until the new master listens.
            const lock = lockSession(args.socket_path) catch std.process.exit(1);
            if (socketLive(args.socket_path)) {
                sys.close(lock);
                attach(allocator, args) catch std.process.exit(1);
            } else {
                // No socket, or a stale one left by a master that died
                createAndAttach(allocator, io, args, false, lock) catch std.process.exit(1);
            }
        },
        .attach => {
            // Attach only, fail if doesn't exist: with `no_session_exit` when there's no
            // session (no socket, or no master on it), so the app can tell a closed
            // session from a failed connection
            attach(allocator, args) catch |err| std.process.exit(switch (err) {
                error.FileNotFound, error.ConnectionRefused => no_session_exit,
                else => 1,
            });
        },
        .create_detached => {
            // Create detached (master only, no client)
            createAndAttach(allocator, io, args, true, null) catch std.process.exit(1);
        },
    }
}

/// Fork the master and attach to it. With `lock`, the session lock is released
/// once the master listens.
fn createAndAttach(allocator: std.mem.Allocator, io: std.Io, args: Args, detached: bool, lock: ?sys.fd_t) !void {
    // On macOS, spawnd starts it in the desktop session, where the keychain works
    if (!args.no_spawnd) {
        const result = spawnd.startMaster(allocator, io, .{
            .socket_path = args.socket_path,
            .command = args.command,
            .scrollback_size = args.scrollback_size,
        });
        // spawnd may have started it after all, and a second one would replace it
        if (result == .started or (result == .failed and socketLive(args.socket_path))) {
            if (lock) |fd| sys.close(fd);
            if (detached) return;
            return attach(allocator, args);
        }
    }

    const command = args.command orelse sys.getenv("SHELL") orelse "/bin/sh";
    // Started over SSH on macOS without spawnd: say why code signing will fail
    const notice: ?[]const u8 = if (!args.no_spawnd and spawnd.outsideDesktopSession(allocator, io))
        spawnd.keychain_notice
    else
        null;

    // The master writes a byte here once it listens, or exits without writing
    const ready = try sys.pipe();

    // Fork: child becomes master (can properly daemonize), parent becomes client
    const pid = try sys.fork();

    if (pid == 0) {
        // Child becomes the master (daemon)
        // Close, don't unlock: unlocking would release the parent's lock too
        if (lock) |fd| sys.close(fd);
        sys.close(ready[0]);
        // setsid() works here because child is not a process group leader
        sys.setsid();

        // Redirect stdin to /dev/null, but stderr to a log file for debugging
        const dev_null = sys.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch null;
        if (dev_null) |null_fd| {
            sys.dup2(null_fd, posix.STDIN_FILENO);
            sys.dup2(null_fd, posix.STDOUT_FILENO);
            if (null_fd > 2) sys.close(null_fd);
        }

        // Open per-session log file for stderr (debug logging)
        // Uses {socket_path}.log so logs are easy to correlate with sessions
        var log_path_buf: [512]u8 = undefined;
        const log_path = std.fmt.bufPrint(&log_path_buf, "{s}.log", .{args.socket_path}) catch null;
        if (log_path) |path| {
            // Null-terminate for open
            var path_z: [513]u8 = undefined;
            @memcpy(path_z[0..path.len], path);
            path_z[path.len] = 0;
            const log_fd = sys.open(path_z[0..path.len :0], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch null;
            if (log_fd) |fd| {
                sys.dup2(fd, posix.STDERR_FILENO);
                if (fd > 2) sys.close(fd);
            }
        }

        var master = Master.init(allocator, io, .{
            .socket_path = args.socket_path,
            .command = command,
            .scrollback_size = args.scrollback_size,
            .notice = notice,
        }) catch std.process.exit(1);
        _ = sys.write(ready[1], "1") catch {};
        sys.close(ready[1]);

        master.run() catch std.process.exit(1);
        // exit skips defers: clean up explicitly so the socket, FIFO and active
        // pointer don't outlive the session
        master.deinit();
        ws.paneEnded(allocator, io, args.socket_path);
        std.process.exit(0);
    } else {
        // Parent becomes client (or exits if detached), once the master listens
        sys.close(ready[1]);
        var byte: [1]u8 = undefined;
        const listening = (sys.read(ready[0], &byte) catch 0) == 1;
        sys.close(ready[0]);
        if (lock) |fd| sys.close(fd);
        if (!listening) return error.MasterFailed;

        if (detached) {
            // Detached mode: just exit, master runs in background
            return;
        }
        // Attach to the session we just created
        try attach(allocator, args);
    }
}

/// `--resume <socket> <pty fd> <socket fd> <pipe fd> <shell pid>`: an older master
/// exec'd this binary to upgrade (upgrade.zig). Same process as before, so stdin,
/// stdout and the session log are already in place.
fn resumeMaster(allocator: std.mem.Allocator, io: std.Io, process_args: std.process.Args) noreturn {
    var rest: [5][]const u8 = undefined;
    var count: usize = 0;
    var it = process_args.iterate();
    _ = it.skip(); // rtach
    _ = it.skip(); // --resume
    while (it.next()) |arg| : (count += 1) {
        if (count == rest.len) std.process.exit(1);
        rest[count] = arg;
    }
    const kept = upgrade.parseResumeArgs(rest[0..count]) orelse std.process.exit(1);
    var master = Master.resumeFrom(allocator, io, kept) catch |err| {
        std.log.err("resume failed: {}", .{err});
        std.process.exit(1);
    };
    master.run() catch std.process.exit(1);
    master.deinit();
    ws.paneEnded(allocator, io, kept.socket_path);
    std.process.exit(0);
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

/// Lock {socket_path}.lock. The file stays: removing it would let a process
/// waiting on the old file and one creating a new file both hold "the" lock.
fn lockSession(socket_path: []const u8) !sys.fd_t {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}.lock", .{socket_path});
    return sys.lockFile(path);
}

/// Whether a master answers on the socket. The file can outlive its master.
fn socketLive(path: []const u8) bool {
    const fd = sys.unixSocket(false) catch return false;
    defer sys.close(fd);
    sys.connect(fd, path) catch return false;
    return true;
}

/// Generate a new UUID-format session ID
fn generateSessionId(io: std.Io) ![36]u8 {
    var uuid_bytes: [16]u8 = undefined;
    io.random(&uuid_bytes);

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
    const home = sys.getenv("HOME") orelse return error.NoHome;
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

fn parseArgs(process_args: std.process.Args) !Args {
    var args_iter = process_args.iterate();
    _ = args_iter.skip(); // Skip program name

    var result = Args{
        .mode = .create_or_attach,
        .socket_path = "",
    };

    var found_socket = false;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            // Print version and exit
            _ = sys.write(posix.STDOUT_FILENO, version ++ "\n") catch {};
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
        } else if (std.mem.eql(u8, arg, "--no-spawnd")) {
            result.no_spawnd = true;
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
        \\
        \\  rtach ws ...  Workspaces, tabs and split layouts (rtach ws for help)
        \\  rtach spawnd install|uninstall|status
        \\              macOS: start sessions in the desktop session (keychain)
        \\  rtach upgrade [--json] [SESSION...]
        \\              Move running sessions to this rtach without ending them
        \\  rtach sweep [--json]
        \\              Clear files left by sessions that crashed (logs kept 7 days)
        \\  -v          Print version
        \\  -h          Print this help
        \\
        \\Examples:
        \\  rtach                           # Interactive session picker
        \\  rtach -A ~/.rtach/session $SHELL
        \\  rtach -a ~/.rtach/session
        \\
    ;
    _ = sys.write(posix.STDOUT_FILENO, usage) catch {};
}

test {
    _ = @import("ringbuffer.zig");
    _ = @import("protocol.zig");
    _ = @import("master.zig");
    _ = @import("client.zig");
    _ = @import("compression.zig");
    _ = @import("picker.zig");
    _ = @import("query_filter.zig");
    _ = @import("history.zig");
    _ = @import("term_modes.zig");
    _ = @import("ws.zig");
    _ = @import("pane_state.zig");
    _ = @import("active.zig");
    _ = @import("inbox.zig");
    _ = @import("cli.zig");
    _ = @import("sys.zig");
}
