const std = @import("std");
const builtin = @import("builtin");
// Use platform-appropriate xev backend:
// - Linux: Dynamic (runtime io_uring -> epoll fallback)
// - macOS: Kqueue
// - Other: Dynamic fallback
const xev = if (builtin.os.tag == .linux)
    @import("xev").Dynamic
else if (builtin.os.tag == .macos)
    @import("xev").Kqueue
else
    @import("xev").Dynamic;
const posix = std.posix;
const sys = @import("sys.zig");
const Protocol = @import("protocol.zig");
const RingBuffer = @import("ringbuffer.zig").DynamicRingBuffer;
const ShellIntegration = @import("shell_integration.zig");
const compression = @import("compression.zig");
const QueryFilter = @import("query_filter.zig").QueryFilter;
const history = @import("history.zig");
const TermModes = @import("term_modes.zig").TermModes;
const active = @import("active.zig");
const cli = @import("cli.zig");
const pane_state = @import("pane_state.zig");
const push = @import("push.zig");
const live = @import("upgrade.zig");
const version = @import("main.zig").version;
const workspaces = @import("ws.zig");
const PaneState = pane_state.PaneState;

const log = std.log.scoped(.master);

// Global state for signal handling diagnostics
var g_received_signal: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var g_log_fd: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1);

fn signalHandler(sig: posix.SIG) callconv(.c) void {
    // Store the signal - will be logged when we can
    g_received_signal.store(@intFromEnum(sig), .release);

    // Try to write directly to log file (signal-safe)
    const fd = g_log_fd.load(.acquire);
    if (fd >= 0) {
        const msg = switch (sig) {
            .TERM => "[SIGNAL] Received SIGTERM - terminating\n",
            .INT => "[SIGNAL] Received SIGINT - interrupted\n",
            .HUP => "[SIGNAL] Received SIGHUP - hangup\n",
            .PIPE => "[SIGNAL] Received SIGPIPE - broken pipe\n",
            .SEGV => "[SIGNAL] Received SIGSEGV - segmentation fault\n",
            .BUS => "[SIGNAL] Received SIGBUS - bus error\n",
            .ABRT => "[SIGNAL] Received SIGABRT - aborted\n",
            else => "[SIGNAL] Received unknown signal\n",
        };
        _ = sys.write(fd, msg) catch {};
    }

    // For fatal signals, re-raise with default handler
    if (sig == .SEGV or sig == .BUS or sig == .ABRT) {
        // Reset to default and re-raise
        var sa: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(sig, &sa, null);
        _ = std.c.raise(sig);
    }
}

fn setupSignalHandlers() void {
    // Fatal signals - log diagnostics then crash
    const fatal_signals = [_]posix.SIG{
        posix.SIG.TERM,
        posix.SIG.INT,
        posix.SIG.SEGV,
        posix.SIG.BUS,
        posix.SIG.ABRT,
    };

    for (fatal_signals) |sig| {
        var sa: posix.Sigaction = .{
            .handler = .{ .handler = signalHandler },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESETHAND, // One-shot for fatal signals
        };
        posix.sigaction(sig, &sa, null);
    }

    // Ignore SIGHUP - session daemon should survive terminal hangup
    // Ignore SIGPIPE - handle EPIPE errors in write() instead
    // Both are standard practice for daemons/network servers
    var sa_ign: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.HUP, &sa_ign, null);
    posix.sigaction(posix.SIG.PIPE, &sa_ign, null);
}

/// Write every byte of `iovs_in` to a client socket. Client sockets are non-blocking, so
/// writev can accept only part of the data when the socket buffer fills (e.g. a large
/// resume flush). Ignoring the short count dropped the rest of a frame whose header had
/// promised the full length, which desynced the client's framing and showed compressed
/// bytes as terminal text. Waits for the socket to drain instead; a client that makes no
/// progress for 5s is shut down so it reconnects cleanly rather than receiving a
/// truncated frame. (The wait blocks the event loop; per-client output queues would avoid
/// that if slow clients become a problem.)
fn writeAllVec(fd: posix.fd_t, iovs_in: []const posix.iovec_const) void {
    var iovs: [4]posix.iovec_const = undefined;
    std.debug.assert(iovs_in.len <= iovs.len);
    @memcpy(iovs[0..iovs_in.len], iovs_in);
    var start: usize = 0;
    const end = iovs_in.len;
    while (start < end) {
        const written = sys.writev(fd, iovs[start..end]) catch |err| switch (err) {
            error.WouldBlock => {
                if (!waitWritable(fd)) {
                    // Stalled or gone mid-frame: the frame can't be completed, so end the
                    // connection (the read side then sees EOF and removes the client).
                    sys.shutdown(fd);
                    return;
                }
                continue;
            },
            else => return,
        };
        var left = written;
        while (start < end and left >= iovs[start].len) {
            left -= iovs[start].len;
            start += 1;
        }
        if (start < end and left > 0) {
            iovs[start].base += left;
            iovs[start].len -= left;
        }
    }
}

fn writeAll(fd: posix.fd_t, data: []const u8) void {
    if (data.len == 0) return;
    const iov = [1]posix.iovec_const{.{ .base = data.ptr, .len = data.len }};
    writeAllVec(fd, &iov);
}

/// Wait up to 5s for a socket to become writable. False if it errored or timed out
/// (a stalled or gone client); the caller then drops the rest of the write.
fn waitWritable(fd: posix.fd_t) bool {
    var pfd = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
    const ready = posix.poll(&pfd, 5000) catch return false;
    if (ready == 0) return false;
    return (pfd[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL)) == 0;
}

/// Write multiple slices in a single syscall using writev
/// More efficient than multiple write() calls for ring buffer slices
fn writeSlices(fd: posix.fd_t, first: []const u8, second: []const u8) void {
    if (first.len == 0 and second.len == 0) return;

    // Build iovec array, skipping empty slices
    var iov: [2]posix.iovec_const = undefined;
    var iov_len: usize = 0;

    if (first.len > 0) {
        iov[iov_len] = .{ .base = first.ptr, .len = first.len };
        iov_len += 1;
    }
    if (second.len > 0) {
        iov[iov_len] = .{ .base = second.ptr, .len = second.len };
        iov_len += 1;
    }

    if (iov_len > 0) {
        writeAllVec(fd, iov[0..iov_len]);
    }
}

/// Write framed data to client: [ResponseHeader][data]
/// Uses writev for atomic header+data write in single syscall
fn writeFramed(fd: posix.fd_t, response_type: Protocol.ResponseType, data: []const u8) void {
    if (data.len == 0) return;

    const header = Protocol.ResponseHeader{
        .type = response_type,
        .len = @intCast(data.len),
    };

    var iov = [2]posix.iovec_const{
        .{ .base = header.toBytes().ptr, .len = Protocol.ResponseHeader.WIRE_SIZE },
        .{ .base = data.ptr, .len = data.len },
    };

    writeAllVec(fd, &iov);
}

/// Write framed data using ring buffer slices: [ResponseHeader][first][second]
/// Uses writev for atomic write in single syscall
fn writeFramedSlices(fd: posix.fd_t, response_type: Protocol.ResponseType, first: []const u8, second: []const u8) void {
    const total_len = first.len + second.len;
    if (total_len == 0) return;

    const header = Protocol.ResponseHeader{
        .type = response_type,
        .len = @intCast(total_len),
    };

    var iov: [3]posix.iovec_const = undefined;
    var iov_len: usize = 1;

    iov[0] = .{ .base = header.toBytes().ptr, .len = Protocol.ResponseHeader.WIRE_SIZE };

    if (first.len > 0) {
        iov[iov_len] = .{ .base = first.ptr, .len = first.len };
        iov_len += 1;
    }
    if (second.len > 0) {
        iov[iov_len] = .{ .base = second.ptr, .len = second.len };
        iov_len += 1;
    }

    writeAllVec(fd, iov[0..iov_len]);
}

/// Thread-local buffers for compression
/// Sized for scrollback which can be up to 16KB on initial connect
threadlocal var compression_buf: [32768]u8 = undefined;
threadlocal var concat_buf: [32768]u8 = undefined;

/// Write framed data with optional compression.
/// If compress=true, compresses data if it results in smaller output.
/// Uses high bit of response type to indicate compression.
fn writeFramedMaybeCompressed(fd: posix.fd_t, response_type: Protocol.ResponseType, data: []const u8, compress: bool) void {
    if (data.len == 0) return;

    var was_compressed: bool = false;
    const output = if (compress)
        compression.compressOrPassthrough(data, &compression_buf, &was_compressed)
    else
        data;

    const type_byte = @intFromEnum(response_type);
    const final_type: u8 = if (was_compressed) compression.setCompressed(type_byte) else type_byte;

    // Build header with potentially modified type
    var header_bytes: [Protocol.ResponseHeader.WIRE_SIZE]u8 = undefined;
    header_bytes[0] = final_type;
    std.mem.writeInt(u32, header_bytes[1..5], @intCast(output.len), .little);

    var iov = [2]posix.iovec_const{
        .{ .base = &header_bytes, .len = Protocol.ResponseHeader.WIRE_SIZE },
        .{ .base = output.ptr, .len = output.len },
    };

    writeAllVec(fd, &iov);
}

/// Write framed slices with optional compression.
/// Concatenates slices and compresses if beneficial (when compress=true).
fn writeFramedSlicesMaybeCompressed(fd: posix.fd_t, response_type: Protocol.ResponseType, first: []const u8, second: []const u8, compress: bool) void {
    const total_len = first.len + second.len;
    if (total_len == 0) return;

    if (!compress) {
        writeFramedSlices(fd, response_type, first, second);
        return;
    }

    // Too big for the compression buffer (e.g. a resume flush after a long pause): send it
    // as several compressed frames rather than one large uncompressed frame.
    if (total_len > concat_buf.len) {
        writeChunkedMaybeCompressed(fd, response_type, first);
        writeChunkedMaybeCompressed(fd, response_type, second);
        return;
    }

    // Concatenate slices into temp buffer
    @memcpy(concat_buf[0..first.len], first);
    @memcpy(concat_buf[first.len..][0..second.len], second);
    const data = concat_buf[0..total_len];

    // Try to compress
    writeFramedMaybeCompressed(fd, response_type, data, true);
}

/// Send `data` as consecutive frames of at most concat_buf.len bytes, each compressed when
/// that makes it smaller. Only for stream-like types (terminal data) where splitting is fine.
fn writeChunkedMaybeCompressed(fd: posix.fd_t, response_type: Protocol.ResponseType, data: []const u8) void {
    var offset: usize = 0;
    while (offset < data.len) {
        const n = @min(concat_buf.len, data.len - offset);
        writeFramedMaybeCompressed(fd, response_type, data[offset..][0..n], true);
        offset += n;
    }
}

// Terminal ioctl constants
fn getTIOCSWINSZ() c_int {
    const val: u32 = switch (@import("builtin").os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => 0x80087467,
        .linux => 0x5414,
        .freebsd, .netbsd, .openbsd => 0x80087467,
        else => 0x80087467,
    };
    return @bitCast(val);
}

// PTY functions from libc
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

extern "c" fn mkfifo(path: [*:0]const u8, mode: posix.mode_t) c_int;

pub const MasterOptions = struct {
    socket_path: []const u8,
    command: []const u8,
    scrollback_size: usize = 1024 * 1024,
    /// Written to the terminal before the program starts
    notice: ?[]const u8 = null,
};

/// Client connection state
const ClientConn = struct {
    fd: posix.fd_t,
    stream: xev.Stream,
    reader: Protocol.PacketReader = .{},
    attached: bool = false,
    framed_mode: bool = false, // After upgrade, client input is parsed as packets
    compression_enabled: bool = false, // Client requested zlib compression in upgrade
    client_id: ?[Protocol.CLIENT_ID_SIZE]u8 = null, // Unique client identifier
    completion: xev.Completion = .{},
    read_buf: [512]u8 = undefined,
    master: *Master = undefined,
    /// When true, terminal output is not streamed to this client (battery optimization)
    /// Scrollback continues to buffer, and data is flushed on resume
    paused: bool = false,
    /// Total bytes written when client was paused (used to flush buffered data on resume)
    paused_total_written: u64 = 0,
    /// Absolute stream position where this client's attach replay started; history
    /// pages (request_history) end here
    replay_start: u64 = 0,
    /// When true, fd has been shut down and client will be destroyed when callback fires
    /// Used for safe deferred destruction (e.g., when kicking duplicate clients)
    pending_remove: bool = false,
    /// Timestamp of last input received from this client (nanoseconds)
    last_input_ns: i128 = 0,
    /// Timestamp of last explicit active claim (nanoseconds)
    last_claim_ns: i128 = 0,
    /// Timestamp of last attach event (nanoseconds)
    last_attach_ns: i128 = 0,
    /// Whether this client can receive command frames (e.g., Clauntty)
    supports_commands: bool = false,
    /// This client's terminal size, from its last winch
    size: ?Protocol.Winsize = null,
    /// Set by pause or a background attach, cleared by a claim or input: the client
    /// doesn't take the PTY size from one in use until it's used itself, so a
    /// background pre-fetch (resume, then pause) doesn't take the size back
    yielded: bool = false,
    /// Sent want_size: told the PTY's size when it or the client in use changes
    wants_size: bool = false,
    /// The last pty_size sent, so an unchanged one isn't sent again
    sent_size: ?Protocol.PtySize = null,
    /// Attached with ATTACH_FLAG_READY and hasn't had `ready` yet: the program's output
    /// meanwhile (its redraw for the nudge's short size) isn't sent to it
    awaiting_ready: bool = false,
};

pub const Master = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: MasterOptions,

    // PTY
    pty_master: posix.fd_t = -1,
    pty_stream: xev.Stream = undefined,
    pty_slave_path: [256]u8 = undefined,
    child_pid: posix.pid_t = 0,

    // Command FIFO - for scripts to send commands to Clauntty
    // FIFO path is {socket_path}.cmd, exposed as RTACH_CMD_PIPE env var
    cmd_fifo_fd: posix.fd_t = -1,
    cmd_fifo_path: [512]u8 = undefined,
    cmd_fifo_path_len: usize = 0,
    cmd_fifo_inode: ?std.Io.File.INode = null,
    cmd_fifo_stream: xev.Stream = undefined,
    cmd_fifo_completion: xev.Completion = .{},
    cmd_fifo_buf: [512]u8 = undefined,
    cmd_line_buf: [4096]u8 = undefined, // Buffer for accumulating partial lines (OAuth URLs run long)
    /// ~/.clauntty/active: points at this session's FIFO while its Clauntty client is
    /// the machine's most recently active one (see active.zig)
    active_pointer_path: [std.fs.max_path_bytes]u8 = undefined,
    active_pointer_len: usize = 0,
    cmd_line_len: usize = 0,

    // Unix socket (using TCP abstraction which works for any socket)
    socket_fd: posix.fd_t = -1,
    /// The socket file this master created. On exit it removes the path only if
    /// that's still the file: a newer master may have replaced it.
    socket_inode: ?std.Io.File.INode = null,
    socket: xev.TCP = undefined,

    // Scrollback buffer
    scrollback: RingBuffer,
    /// Monotonic counter of total bytes written to scrollback
    scrollback_total_written: u64 = 0,
    /// Where the stream was when this master took over from an older one (live
    /// upgrade); clients that reattach with ATTACH_FLAG_RESUME get what came after
    resumed_at: ?u64 = null,

    // Connected clients
    clients: std.ArrayList(*ClientConn) = .empty,
    /// Active client for command routing
    active_client: ?*ClientConn = null,
    /// Client whose size the PTY has: the one in use (see pickSizeClient)
    size_client: ?*ClientConn = null,

    // Event loop
    loop: xev.Loop,

    // xev completions for PTY and socket
    pty_completion: xev.Completion = .{},
    socket_completion: xev.Completion = .{},
    pty_read_buf: [4096]u8 = undefined,
    /// Strips terminal queries from output stored for replay (see query_filter.zig)
    replay_filter: QueryFilter = .{},
    replay_buf: [4096 + QueryFilter.max_pending]u8 = undefined,

    // Window size
    winsize: Protocol.Winsize = .{ .rows = 24, .cols = 80 },

    /// What's happening in the session (foreground process, agent state), for the app
    pane: PaneState = .{},
    pane_dirty: bool = false,
    last_pane_probe_ns: i128 = 0,
    /// The status last sent to the app, to see what changed
    flushed_status: pane_state.Status = .none,
    /// The last push this pane asked for, and when: an agent going blocked, working,
    /// blocked again within PUSH_REPEAT_NS pushes once
    pushed_status: pane_state.Status = .none,
    pushed_ns: i128 = 0,
    /// From `upgrade;<path>`: the rtach to replace this one with, once the pipe's
    /// current read is handled (see upgrade.zig)
    upgrade_to: [std.fs.max_path_bytes]u8 = undefined,
    upgrade_to_len: usize = 0,

    // Terminal mode tracking (alternate screen, cursor visibility, mouse, bracketed paste...)
    // In the alternate screen (vim, less, Claude Code, etc.) we skip sending scrollback on
    // attach since the TUI will redraw itself; the other modes are restored on attach
    modes: TermModes = .{},

    /// The repaint nudge (startNudge): the PTY is one row short of `winsize` until the
    /// program redraws for it, or NUDGE_TIMEOUT_NS passes
    nudging: bool = false,
    nudge_started_ns: i128 = 0,

    // Idle detection for battery optimization
    // When PTY has no output for IDLE_THRESHOLD_NS, send idle notification to paused clients
    last_pty_write_ns: i128 = 0,
    idle_timer: xev.Timer = undefined,
    idle_timer_completion: xev.Completion = .{},
    idle_notified: bool = false, // Avoid sending duplicate idle notifications

    // Terminal title from OSC 0/1/2 escape sequences
    // Stored to .title file for session picker display
    terminal_title: [256]u8 = undefined,
    terminal_title_len: u8 = 0,
    title_dirty: bool = false,
    last_title_write_ns: i128 = 0,
    // OSC parsing state (for sequences spanning multiple reads)
    osc_state: OscParseState = .none,
    osc_buf: [256]u8 = undefined,
    osc_buf_len: u8 = 0,
    // Heartbeat counter for diagnostic logging
    heartbeat_counter: u32 = 0,

    const OscParseState = enum {
        none, // Not in OSC sequence
        got_esc, // Got ESC, waiting for ]
        got_osc, // Got ESC ], waiting for 0/1/2
        got_cmd, // Got 0/1/2, waiting for ;
        in_title, // Collecting title bytes until BEL or ST
        got_esc_in_title, // Got ESC while in title, checking for ST (\)
    };

    const IDLE_THRESHOLD_NS: i128 = 2 * std.time.ns_per_s; // 2 seconds
    const IDLE_CHECK_INTERVAL_MS: u64 = 500; // Check every 500ms
    /// A program that hasn't redrawn for the nudge by then won't (checked on the idle tick)
    const NUDGE_TIMEOUT_NS: i128 = 500 * std.time.ns_per_ms;
    const TITLE_WRITE_DEBOUNCE_NS: i128 = 500 * std.time.ns_per_ms; // 500ms
    const PANE_PROBE_INTERVAL_NS: i128 = std.time.ns_per_s;
    const PUSH_REPEAT_NS: i128 = 10 * std.time.ns_per_s;
    const HEARTBEAT_INTERVAL_TICKS: u32 = 600; // Log heartbeat every 600 ticks (5 minutes at 500ms)

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: MasterOptions) !*Master {
        const self = try allocator.create(Master);
        errdefer allocator.destroy(self);

        // On Linux, detect available backend (io_uring -> epoll fallback)
        if (comptime builtin.os.tag == .linux) {
            xev.detect() catch |err| {
                log.err("No available event backends: {}", .{err});
                return error.NoEventBackend;
            };
            log.info("Using backend: {s}", .{@tagName(xev.backend)});
        }

        self.* = .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .scrollback = try RingBuffer.init(allocator, options.scrollback_size),
            .clients = .empty,
            .loop = try xev.Loop.init(.{}),
            .cmd_line_len = 0,
        };

        try self.createSocket();
        errdefer self.closeSocket();

        try self.createPty();
        errdefer self.closePty();

        if (active.pointerPath(options.socket_path, &self.active_pointer_path)) |path| {
            self.active_pointer_len = path.len;
        }

        return self;
    }

    /// A master that replaced an older one (upgradeTo): the session's fds and shell are
    /// already there, the rest comes from the state file if it can be read
    pub fn resumeFrom(allocator: std.mem.Allocator, io: std.Io, kept: live.Kept) !*Master {
        for ([_]posix.fd_t{ kept.pty, kept.socket, kept.fifo }) |fd| {
            if (!sys.isOpen(fd)) return error.NotUpgrading;
        }
        if (comptime builtin.os.tag == .linux) try xev.detect();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const loaded = live.load(io, arena.allocator(), kept.socket_path);
        const state: live.State = if (loaded) |l| l.state else .{};
        // For logs only; kept as long as the master
        const command = try allocator.dupe(u8, if (state.command.len > 0) state.command else "(resumed)");

        const self = try allocator.create(Master);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .options = .{
                .socket_path = kept.socket_path,
                .command = command,
                .scrollback_size = if (state.scrollback_capacity > 0) state.scrollback_capacity else 1024 * 1024,
            },
            .scrollback = try RingBuffer.init(allocator, if (state.scrollback_capacity > 0) state.scrollback_capacity else 1024 * 1024),
            .clients = .empty,
            .loop = try xev.Loop.init(.{}),
            .cmd_line_len = 0,
        };

        // The session's fds: closed on exec again, so a later upgrade starts clean
        self.pty_master = kept.pty;
        self.socket_fd = kept.socket;
        self.cmd_fifo_fd = kept.fifo;
        for ([_]posix.fd_t{ kept.pty, kept.socket, kept.fifo }) |fd| sys.setCloexec(fd);
        self.child_pid = kept.child_pid;
        self.pty_stream = xev.Stream.initFd(kept.pty);
        self.socket = xev.TCP.initFd(kept.socket);
        self.cmd_fifo_stream = xev.Stream.initFd(kept.fifo);
        self.socket_inode = self.inodeOf(kept.socket_path);
        const fifo_path = std.fmt.bufPrint(&self.cmd_fifo_path, "{s}.cmd", .{kept.socket_path}) catch return error.FifoPathTooLong;
        self.cmd_fifo_path_len = fifo_path.len;
        self.cmd_fifo_path[fifo_path.len] = 0;
        self.cmd_fifo_inode = self.inodeOf(fifo_path);
        if (ptsname(kept.pty)) |slave| {
            const slave_path = std.mem.span(slave);
            @memcpy(self.pty_slave_path[0..slave_path.len], slave_path);
            self.pty_slave_path[slave_path.len] = 0;
        }
        if (active.pointerPath(kept.socket_path, &self.active_pointer_path)) |path| {
            self.active_pointer_len = path.len;
        }

        if (loaded) |l| {
            self.scrollback.write(l.scrollback);
            self.scrollback_total_written = @max(state.scrollback_total_written, l.scrollback.len);
            self.winsize = .{ .rows = state.rows, .cols = state.cols };
            self.modes.alt_screen = state.alt_screen;
            self.modes.cursor_visible = state.cursor_visible;
            self.modes.flags.mask = @truncate(state.mode_flags);
            self.modes.mouse_event = state.mouse_event;
            self.modes.mouse_format = state.mouse_format;
            self.modes.autowrap = state.autowrap;
            self.modes.keypad_app = state.keypad_app;
            self.modes.kitty_main = .{ .flags = state.kitty_main, .idx = @truncate(state.kitty_main_idx) };
            self.modes.kitty_alt = .{ .flags = state.kitty_alt, .idx = @truncate(state.kitty_alt_idx) };
            self.modes.modify_keys = state.modify_keys;
            self.modes.cursor_style = state.cursor_style;
            const title_len = @min(state.title.len, self.terminal_title.len);
            @memcpy(self.terminal_title[0..title_len], state.title[0..title_len]);
            self.terminal_title_len = @intCast(title_len);
            self.pane.restore(state.fg, state.cwd, state.agent, state.status, state.note, state.task, state.from_hook);
            self.flushed_status = std.meta.stringToEnum(pane_state.Status, state.flushed_status) orelse .none;
            self.pushed_status = std.meta.stringToEnum(pane_state.Status, state.pushed_status) orelse .none;
            const partial = @min(state.cmd_partial.len, self.cmd_line_buf.len);
            @memcpy(self.cmd_line_buf[0..partial], state.cmd_partial[0..partial]);
            self.cmd_line_len = partial;
            log.info("resumed from {s}: {} bytes of scrollback", .{ if (state.rtach.len > 0) state.rtach else "?", l.scrollback.len });
        } else {
            log.warn("resumed without the previous master's state (scrollback, modes and title start empty)", .{});
        }
        self.resumed_at = self.scrollback_total_written;
        // Tell the app, and `rtach upgrade`, which version runs now
        self.pane_dirty = true;
        return self;
    }

    pub fn deinit(self: *Master) void {
        self.idle_timer.deinit();
        self.loop.deinit();
        // Before the socket: once it's gone a new session can start on this path
        self.removeSessionFiles();
        self.closeSocket();
        self.closePty();
        self.scrollback.deinit();

        for (self.clients.items) |client| {
            sys.close(client.fd);
            self.allocator.destroy(client);
        }
        self.clients.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    fn createSocket(self: *Master) !void {
        sys.unlink(self.options.socket_path);

        self.socket_fd = try sys.unixSocket(true);
        errdefer sys.close(self.socket_fd);

        // A full backlog refuses connections on macOS, and `-A` takes a refused
        // socket for a stale one
        try sys.bindAndListen(self.socket_fd, self.options.socket_path, 64);
        self.socket_inode = self.inodeOf(self.options.socket_path);

        // Wrap in TCP abstraction (works for Unix sockets too)
        self.socket = xev.TCP.initFd(self.socket_fd);

        _ = std.c.chmod(@ptrCast(self.options.socket_path.ptr), 0o600);

        log.info("listening on {s}", .{self.options.socket_path});
    }

    fn closeSocket(self: *Master) void {
        if (self.socket_fd >= 0) {
            sys.close(self.socket_fd);
            self.unlinkIfOurs(self.options.socket_path, self.socket_inode);
            self.socket_fd = -1;
        }
    }

    fn inodeOf(self: *Master, path: []const u8) ?std.Io.File.INode {
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return null;
        return stat.inode;
    }

    /// The session ended normally: its `.state` and `.title` describe a running session
    /// and its `.log` is only wanted when something went wrong, so they go with it (they
    /// piled up in ~/.clauntty/sessions). Only while the socket is still this master's.
    /// `.lock` stays (see `-A`). A master that crashes leaves its files for `rtach sweep`.
    fn removeSessionFiles(self: *Master) void {
        const ours = self.socket_inode orelse return;
        if (self.inodeOf(self.options.socket_path) != ours) return;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        for ([_][]const u8{ ".state", ".state.tmp", ".title", ".title.tmp", ".log" }) |suffix| {
            const path = std.fmt.bufPrint(&buf, "{s}{s}", .{ self.options.socket_path, suffix }) catch continue;
            sys.unlink(path);
        }
    }

    /// Remove a file this master created, unless another file has taken its path
    fn unlinkIfOurs(self: *Master, path: []const u8, inode: ?std.Io.File.INode) void {
        const ours = inode orelse return;
        if (self.inodeOf(path) != ours) return;
        sys.unlink(path);
    }

    /// Whether this machine's terminfo has an entry for `term`. A command run over SSH
    /// without a terminal can carry a placeholder (login's "network", "unknown") that
    /// isn't one, and zsh then can't move the cursor or show colors.
    fn terminfoHas(term: []const u8) bool {
        if (term.len == 0 or std.mem.indexOfScalar(u8, term, '/') != null) return false;
        var dirs_buf: [8][]const u8 = undefined;
        var dirs: std.ArrayList([]const u8) = .initBuffer(&dirs_buf);
        var home_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (sys.getenv("TERMINFO")) |dir| dirs.appendAssumeCapacity(dir);
        if (sys.getenv("HOME")) |home| {
            if (std.fmt.bufPrint(&home_buf, "{s}/.terminfo", .{home})) |dir| dirs.appendAssumeCapacity(dir) else |_| {}
        }
        for ([_][]const u8{ "/etc/terminfo", "/lib/terminfo", "/usr/share/terminfo", "/usr/lib/terminfo" }) |dir| {
            dirs.appendAssumeCapacity(dir);
        }
        var extra = std.mem.splitScalar(u8, sys.getenv("TERMINFO_DIRS") orelse "", ':');
        while (extra.next()) |dir| {
            if (dir.len > 0 and terminfoIn(dir, term)) return true;
        }
        for (dirs.items) |dir| {
            if (terminfoIn(dir, term)) return true;
        }
        return false;
    }

    /// Entries live in <dir>/<first char>/<name> (Linux) or <dir>/<hex of it>/<name> (macOS)
    fn terminfoIn(dir: []const u8, term: []const u8) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const by_char = std.fmt.bufPrintZ(&buf, "{s}/{c}/{s}", .{ dir, term[0], term }) catch return false;
        if (std.c.access(by_char, std.c.F_OK) == 0) return true;
        const by_hex = std.fmt.bufPrintZ(&buf, "{s}/{x:0>2}/{s}", .{ dir, term[0], term }) catch return false;
        return std.c.access(by_hex, std.c.F_OK) == 0;
    }

    fn stderrToPty(slave_fd: posix.fd_t) void {
        sys.dup2(slave_fd, 2);
        if (slave_fd > 2) sys.close(slave_fd);
    }

    fn createPty(self: *Master) !void {
        const master_fd = sys.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .NONBLOCK = true }, 0) catch |err| {
            log.err("failed to open /dev/ptmx: {}", .{err});
            return err;
        };
        errdefer sys.close(master_fd);

        if (grantpt(master_fd) != 0) return error.GrantPtyFailed;
        if (unlockpt(master_fd) != 0) return error.UnlockPtyFailed;

        const slave_path = ptsname(master_fd) orelse return error.PtsnameFailed;
        const slave_len = std.mem.len(slave_path);
        @memcpy(self.pty_slave_path[0..slave_len], slave_path[0..slave_len]);
        self.pty_slave_path[slave_len] = 0;

        self.pty_master = master_fd;
        // A shell that starts before any client attaches (a `rtach ws` pane, or `-n`)
        // mustn't see a 0x0 terminal: zsh then edits lines as if it can't move the
        // cursor, and stays that way after the real size arrives
        // (applyWinsize would skip it: self.winsize already says 80x24)
        const initial = posix.winsize{ .row = self.winsize.rows, .col = self.winsize.cols, .xpixel = 0, .ypixel = 0 };
        _ = std.c.ioctl(master_fd, getTIOCSWINSZ(), &initial);
        self.pty_stream = xev.Stream.initFd(master_fd);

        // Create command FIFO for scripts to send commands to Clauntty
        // FIFO path is {socket_path}.cmd - scripts write to this path via RTACH_CMD_PIPE env var
        // This works even when subprocess FDs are closed (unlike inherited pipe FDs)
        const fifo_path_slice = std.fmt.bufPrint(&self.cmd_fifo_path, "{s}.cmd", .{self.options.socket_path}) catch {
            return error.FifoPathTooLong;
        };
        self.cmd_fifo_path_len = fifo_path_slice.len;
        self.cmd_fifo_path[fifo_path_slice.len] = 0; // null-terminate for C functions

        // Get a null-terminated pointer for C functions
        const fifo_path_z: [*:0]const u8 = @ptrCast(&self.cmd_fifo_path);

        // Remove any existing FIFO
        _ = std.c.unlink(fifo_path_z);

        // Create FIFO with mode 0600
        const mkfifo_result = mkfifo(fifo_path_z, 0o600);
        if (mkfifo_result != 0) {
            const err = std.c._errno().*;
            log.err("mkfifo failed for path '{s}': errno={}", .{ self.cmd_fifo_path[0..self.cmd_fifo_path_len], err });
            return error.MkfifoFailed;
        }
        self.cmd_fifo_inode = self.inodeOf(self.cmd_fifo_path[0..self.cmd_fifo_path_len]);
        log.info("created command FIFO at {s}", .{self.cmd_fifo_path[0..self.cmd_fifo_path_len]});

        // Open FIFO with O_RDWR | O_NONBLOCK
        // O_RDWR keeps at least one "writer" attached (ourselves), preventing immediate EOF
        self.cmd_fifo_fd = sys.open(
            self.cmd_fifo_path[0..self.cmd_fifo_path_len :0],
            .{ .ACCMODE = .RDWR, .NONBLOCK = true },
            0,
        ) catch |err| {
            log.err("failed to open command FIFO: {}", .{err});
            _ = std.c.unlink(fifo_path_z);
            return err;
        };

        self.cmd_fifo_stream = xev.Stream.initFd(self.cmd_fifo_fd);

        const pid = try sys.fork();
        if (pid == 0) {
            // Child process
            sys.close(master_fd);
            sys.close(self.cmd_fifo_fd); // Close parent's FIFO fd in child
            sys.setsid();

            const slave_fd = sys.open(
                @ptrCast(&self.pty_slave_path),
                .{ .ACCMODE = .RDWR },
                0,
            ) catch {
                std.process.exit(1);
            };

            // NOTE: Do NOT set PTY to raw mode here!
            // The shell should inherit default (cooked mode) PTY settings.
            // The shell will configure the terminal as needed (bash uses cooked mode,
            // vim/nano switch to raw mode when they start, etc.)

            sys.dup2(slave_fd, 0);
            sys.dup2(slave_fd, 1);
            if (self.options.notice) |notice| _ = sys.write(1, notice) catch {};
            // stderr stays on the session log until exec, so setup logs don't show
            // in the terminal

            // Set RTACH_CMD_PIPE environment variable for scripts to send commands
            // This is the path to the FIFO that scripts can write to
            _ = setenv("RTACH_CMD_PIPE", fifo_path_z, 1);
            // A new shell gets the integration even when whoever started the session
            // had it (`rtach ws split` run in another pane)
            _ = unsetenv("CLAUNTTY_SHELL_INTEGRATION");
            // The session is a terminal even when whoever started it had none (`rtach ws`
            // run over a plain SSH command): zsh with no TERM edits lines like a dumb
            // terminal, and with no locale it mangles UTF-8
            const term = sys.getenv("TERM") orelse "";
            if (std.mem.eql(u8, term, "dumb") or !terminfoHas(term)) _ = setenv("TERM", "xterm-256color", 1);
            if (sys.getenv("LANG") == null and sys.getenv("LC_ALL") == null and sys.getenv("LC_CTYPE") == null) {
                _ = setenv("LANG", if (@import("builtin").os.tag == .macos) "en_US.UTF-8" else "C.UTF-8", 1);
            }

            // Which session this is, for `rtach ws` and scripts. The socket path came
            // from argv, so it's NUL-terminated (as createSocket assumes).
            var socket_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (std.c.realpath(@ptrCast(self.options.socket_path.ptr), &socket_buf)) |socket_z| {
                _ = setenv("RTACH_SOCKET", socket_z, 1);
                const socket = std.mem.span(socket_z);
                const id = std.fs.path.basename(socket);
                _ = setenv("RTACH_SESSION_ID", @ptrCast(socket[socket.len - id.len ..].ptr), 1);
            }

            // Set BROWSER to open-browser so CLI tools use iOS browser
            if (sys.getenv("HOME")) |home| {
                var browser_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const browser_path = std.fmt.bufPrintZ(&browser_path_buf, "{s}/.clauntty/bin/open-browser", .{home}) catch null;
                if (browser_path) |path| {
                    _ = setenv("BROWSER", path, 1);
                }

                // The clauntty command, also for shells without our integration
                // (the integration adds it too, after the user's rc files)
                const old_path = sys.getenv("PATH") orelse "/usr/bin:/bin";
                var path_env_buf: [8192]u8 = undefined;
                const path_env = std.fmt.bufPrintZ(&path_env_buf, "{s}:{s}/.clauntty/bin", .{ old_path, home }) catch null;
                if (path_env) |value| {
                    _ = setenv("PATH", value, 1);
                }
            }

            // Deploy shell integration files
            ShellIntegration.deployIntegrationFiles(self.io) catch |err| {
                log.warn("failed to deploy shell integration: {}", .{err});
            };

            // Detect shell type and prepare args with integration
            const shell_type = ShellIntegration.detectShellType(self.options.command);

            const shell_setup = ShellIntegration.prepareShellArgs(
                self.allocator,
                @ptrCast(self.options.command.ptr),
                shell_type,
            ) catch |err| {
                log.warn("failed to prepare shell args: {}, falling back to direct exec", .{err});
                // Fall back to direct exec
                const argv = [_:null]?[*:0]const u8{
                    @ptrCast(self.options.command.ptr),
                    null,
                };
                stderrToPty(slave_fd);
                sys.execvpZ(@ptrCast(self.options.command.ptr), &argv);
                std.process.exit(127);
            };

            // Set extra environment variable if needed (e.g., ZDOTDIR for zsh)
            if (shell_setup.env_name) |name| {
                if (shell_setup.env_value) |value| {
                    _ = setenv(name, value, 1);
                }
            }

            const arg1 = if (shell_setup.argc > 1 and shell_setup.argv[1] != null)
                std.mem.span(shell_setup.argv[1].?)
            else
                "-";
            const arg2 = if (shell_setup.argc > 2 and shell_setup.argv[2] != null)
                std.mem.span(shell_setup.argv[2].?)
            else
                "-";

            const integration_dir = blk: {
                if (sys.getenv("HOME")) |home| {
                    var path_buf: [512]u8 = undefined;
                    const path = std.fmt.bufPrint(&path_buf, "{s}/.clauntty/shell-integration", .{home}) catch break :blk "unknown";
                    break :blk path;
                }
                break :blk "unknown";
            };

            const session_name = blk: {
                if (std.mem.lastIndexOf(u8, self.options.socket_path, "/")) |idx| {
                    break :blk self.options.socket_path[idx + 1 ..];
                }
                break :blk self.options.socket_path;
            };

            log.info(
                "shell setup: dir={s} shell={s} exec={s} arg1={s} arg2={s} detach=Ctrl-\\ kill=pkill -f 'rtach.*{s}'",
                .{ integration_dir, @tagName(shell_type), shell_setup.argv[0].?, arg1, arg2, session_name },
            );

            // Execute shell with integration
            stderrToPty(slave_fd);
            sys.execvpZ(shell_setup.argv[0].?, &shell_setup.argv);
            std.process.exit(127);
        }

        self.child_pid = pid;

        log.info("started child pid={} command={s}, fifo={s}", .{ pid, self.options.command, self.cmd_fifo_path[0..self.cmd_fifo_path_len] });
    }

    fn closePty(self: *Master) void {
        if (self.pty_master >= 0) {
            sys.close(self.pty_master);
            self.pty_master = -1;
        }
        if (self.cmd_fifo_fd >= 0) {
            sys.close(self.cmd_fifo_fd);
            self.cmd_fifo_fd = -1;
        }
        // Remove the FIFO file
        if (self.cmd_fifo_path_len > 0) {
            self.clearActivePointer();
            self.unlinkIfOurs(self.cmd_fifo_path[0..self.cmd_fifo_path_len], self.cmd_fifo_inode);
            self.cmd_fifo_path_len = 0;
        }
        if (self.child_pid > 0) {
            _ = posix.kill(self.child_pid, posix.SIG.TERM) catch {};
            self.child_pid = 0;
        }
    }

    pub fn run(self: *Master) !void {
        // Set up signal handlers for diagnostic logging
        setupSignalHandlers();
        // Store stderr fd for signal handler to use (signal-safe writes)
        g_log_fd.store(2, .release); // stderr = fd 2

        log.info("master running with xev, scrollback={}KB, pid={}", .{ self.options.scrollback_size / 1024, std.c.getpid() });

        // Set up PTY read using Stream abstraction
        self.pty_stream.read(
            &self.loop,
            &self.pty_completion,
            .{ .slice = &self.pty_read_buf },
            Master,
            self,
            ptyReadCallback,
        );

        // Set up command FIFO read (for scripts to send commands to clients)
        if (self.cmd_fifo_fd >= 0) {
            self.cmd_fifo_stream.read(
                &self.loop,
                &self.cmd_fifo_completion,
                .{ .slice = &self.cmd_fifo_buf },
                Master,
                self,
                cmdFifoReadCallback,
            );
        }

        // Set up socket accept using TCP abstraction
        self.socket.accept(
            &self.loop,
            &self.socket_completion,
            Master,
            self,
            acceptCallback,
        );

        // Set up idle detection timer (checks every 500ms)
        self.idle_timer = try xev.Timer.init();
        self.last_pty_write_ns = self.nowNs(); // Initialize to now
        self.idle_timer.run(
            &self.loop,
            &self.idle_timer_completion,
            IDLE_CHECK_INTERVAL_MS,
            Master,
            self,
            idleTimerCallback,
        );

        // Run the event loop
        try self.loop.run(.until_done);

        log.info("master shutting down", .{});
        self.announceEnded();
    }

    /// The session is over (its shell exited, or the master was told to stop): say so
    /// to every framed client before they're closed, so the app ends the window now
    /// instead of reconnecting to find no session. Not on a live upgrade, which execs
    /// before the loop returns. Terminal clients ignore command frames.
    fn announceEnded(self: *Master) void {
        for (self.clients.items) |client| {
            if (client.pending_remove or !client.framed_mode) continue;
            writeFramed(client.fd, .command, "ended");
        }
    }

    fn ptyReadCallback(
        self_opt: ?*Master,
        loop: *xev.Loop,
        _: *xev.Completion,
        _: xev.Stream,
        _: xev.ReadBuffer,
        result: xev.ReadError!usize,
    ) xev.CallbackAction {
        const self = self_opt orelse return .disarm;

        const n = result catch |err| {
            if (err == error.Again) {
                // Re-arm PTY read
                self.pty_stream.read(
                    loop,
                    &self.pty_completion,
                    .{ .slice = &self.pty_read_buf },
                    Master,
                    self,
                    ptyReadCallback,
                );
                return .disarm;
            }
            log.err("PTY read error: {}", .{err});
            loop.stop();
            return .disarm;
        };

        if (n == 0) {
            log.info("PTY closed", .{});
            loop.stop();
            return .disarm;
        }

        const data = self.pty_read_buf[0..n];

        // Track terminal modes (alternate screen, cursor, mouse, ...) for restore on attach
        self.modes.process(data);

        // Parse OSC title sequences (OSC 0/1/2)
        self.updateTerminalTitle(data);

        // Record timestamp for idle detection
        self.last_pty_write_ns = self.nowNs();
        self.idle_notified = false; // Reset - we have new output

        // Store in scrollback, minus queries: stored output is only replayed, and a
        // replayed query gets a stale reply typed into the program's input
        const stored = self.replay_filter.process(data, &self.replay_buf);
        self.scrollback.write(stored);
        self.scrollback_total_written += @intCast(stored.len);

        // Forward to all attached, non-paused clients
        // Paused clients will receive buffered data when they resume
        for (self.clients.items) |client| {
            if (client.pending_remove) continue;
            // Waiting for `ready`: this is the redraw for the nudge's short size
            if (client.attached and !client.paused and !client.awaiting_ready) {
                if (client.framed_mode) {
                    // Use compression for PTY output streaming (if client requested it)
                    writeFramedMaybeCompressed(client.fd, .terminal_data, data, client.compression_enabled);
                } else {
                    // Raw mode - send terminal data without framing
                    writeAll(client.fd, data);
                }
            }
        }

        // The program drew for the nudge's short size (a whole synchronized frame, if it
        // draws in them): it read the change, so the size can go back
        if (self.nudging and !self.modes.sync_frame) self.finishNudge();

        // Re-arm PTY read
        self.pty_stream.read(
            loop,
            &self.pty_completion,
            .{ .slice = &self.pty_read_buf },
            Master,
            self,
            ptyReadCallback,
        );
        return .disarm;
    }

    // MARK: Repaint nudge

    /// Make a program on the alternate screen redraw for clients that just attached
    /// (awaiting_ready): they get no replay, and programs only redraw on a real size
    /// change (Node ignores a SIGWINCH at the same size). The PTY goes one row short;
    /// once the program has drawn for that, or NUDGE_TIMEOUT_NS passes (a program that
    /// doesn't redraw), the size goes back and they get `ready`: what follows is the
    /// redraw at the real size. Their output meanwhile (the short redraw) isn't sent.
    /// A program busy writing anyway (a spinner) can write once before it reads the
    /// change; going back on that output can leave it without a redraw.
    fn startNudge(self: *Master) void {
        // The one under way covers this client too
        if (self.nudging) return;
        if (self.winsize.rows <= 2) return self.finishNudge();
        self.signalSize(self.winsize.rows - 1, self.winsize.cols);
        self.nudging = true;
        self.nudge_started_ns = self.nowNs();
        log.info("nudge: {}x{} for a redraw", .{ self.winsize.cols, self.winsize.rows - 1 });
    }

    /// Put the PTY back at its size, and tell the clients waiting the screen is ready
    fn finishNudge(self: *Master) void {
        if (self.nudging) {
            self.nudging = false;
            self.signalSize(self.winsize.rows, self.winsize.cols);
            log.info("nudge: back to {}x{}", .{ self.winsize.cols, self.winsize.rows });
        }
        for (self.clients.items) |client| {
            if (client.awaiting_ready and !client.pending_remove) self.sendReady(client);
        }
    }

    fn sendReady(self: *Master, client: *ClientConn) void {
        _ = self;
        client.awaiting_ready = false;
        // Empty: just the header (writeFramed skips empty payloads)
        const header = Protocol.ResponseHeader{ .type = .ready, .len = 0 };
        writeAll(client.fd, header.toBytes());
    }

    /// Set the PTY's size and signal the program, without changing `winsize`
    fn signalSize(self: *Master, rows: u16, cols: u16) void {
        const c_ws = posix.winsize{ .row = rows, .col = cols, .xpixel = self.winsize.xpixel, .ypixel = self.winsize.ypixel };
        _ = std.c.ioctl(self.pty_master, getTIOCSWINSZ(), &c_ws);
        if (self.child_pid > 0) _ = std.c.kill(-self.child_pid, posix.SIG.WINCH);
    }

    fn idleTimerCallback(
        self_opt: ?*Master,
        loop: *xev.Loop,
        _: *xev.Completion,
        result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        const self = self_opt orelse return .disarm;

        // SIGTERM/SIGINT (e.g. the app's pkill when a tab is closed): stop the loop so
        // the master cleans up (socket, FIFO, active pointer, shell) and exits. The
        // handlers are one-shot, so a second signal kills outright if this is stuck.
        const sig = g_received_signal.load(.acquire);
        if (sig == @intFromEnum(posix.SIG.TERM) or sig == @intFromEnum(posix.SIG.INT)) {
            log.info("received signal {}, shutting down", .{sig});
            loop.stop();
            return .disarm;
        }

        _ = result catch |err| {
            log.warn("idle timer error: {}", .{err});
            // Timer error - just re-arm
            self.idle_timer.run(
                loop,
                &self.idle_timer_completion,
                IDLE_CHECK_INTERVAL_MS,
                Master,
                self,
                idleTimerCallback,
            );
            return .disarm;
        };

        // Heartbeat logging (every 5 minutes) - confirms master is still alive
        self.heartbeat_counter += 1;
        if (self.heartbeat_counter >= HEARTBEAT_INTERVAL_TICKS) {
            self.heartbeat_counter = 0;
            log.info("heartbeat: clients={}, scrollback={}KB", .{
                self.clients.items.len,
                self.scrollback.len / 1024,
            });
        }

        // Check if we're idle (no PTY output for IDLE_THRESHOLD_NS)
        const now = self.nowNs();
        const elapsed = now - self.last_pty_write_ns;
        const elapsed_ms = @divFloor(elapsed, std.time.ns_per_ms);

        // Count attached and paused clients for debugging
        var attached_count: usize = 0;
        var paused_count: usize = 0;
        for (self.clients.items) |client| {
            if (client.pending_remove) continue;
            if (client.attached) attached_count += 1;
            if (client.paused) paused_count += 1;
        }

        // Only log when there's something interesting to report
        if (elapsed >= IDLE_THRESHOLD_NS and !self.idle_notified and paused_count > 0) {
            log.debug("idle check: elapsed={}ms, clients={}, attached={}, paused={}", .{
                elapsed_ms,
                self.clients.items.len,
                attached_count,
                paused_count,
            });
        }

        if (elapsed >= IDLE_THRESHOLD_NS and !self.idle_notified) {
            // Send idle notification to all attached framed clients
            // Active clients need it for UI indicator, paused clients for pre-fetch trigger
            // Raw clients don't understand protocol headers (would see 5 bytes garbage)
            var sent_count: usize = 0;
            for (self.clients.items) |client| {
                if (client.pending_remove) continue;
                if (client.attached and client.framed_mode) {
                    // Send empty idle response (just header, no payload)
                    const header = Protocol.ResponseHeader{
                        .type = .idle,
                        .len = 0,
                    };
                    writeAll(client.fd, header.toBytes());
                    sent_count += 1;
                    log.info("sent idle to client fd={} (paused={})", .{ client.fd, client.paused });
                }
            }

            if (sent_count > 0) {
                log.info("idle detected: notified {} clients", .{sent_count});
            } else {
                log.info("idle detected but no attached clients to notify", .{});
            }
            self.idle_notified = true;
        }

        // A program that doesn't redraw for the nudge
        if (self.nudging and now - self.nudge_started_ns >= NUDGE_TIMEOUT_NS) {
            log.info("nudge: no redraw, going back", .{});
            self.finishNudge();
        }

        // Write title to file if dirty (debounced)
        self.writeTitleToFile();
        self.probePane();

        // Re-arm timer
        self.idle_timer.run(
            loop,
            &self.idle_timer_completion,
            IDLE_CHECK_INTERVAL_MS,
            Master,
            self,
            idleTimerCallback,
        );
        return .disarm;
    }

    fn cmdFifoReadCallback(
        self_opt: ?*Master,
        loop: *xev.Loop,
        _: *xev.Completion,
        _: xev.Stream,
        _: xev.ReadBuffer,
        result: xev.ReadError!usize,
    ) xev.CallbackAction {
        const self = self_opt orelse return .disarm;

        const n = result catch |err| {
            if (err == error.Again) {
                // Re-arm command FIFO read
                self.cmd_fifo_stream.read(
                    loop,
                    &self.cmd_fifo_completion,
                    .{ .slice = &self.cmd_fifo_buf },
                    Master,
                    self,
                    cmdFifoReadCallback,
                );
                return .disarm;
            }
            log.warn("command FIFO read error: {}", .{err});
            return .disarm;
        };

        if (n == 0) {
            // FIFO opened with O_RDWR shouldn't get EOF, but handle gracefully
            // Re-arm to wait for more data
            self.cmd_fifo_stream.read(
                loop,
                &self.cmd_fifo_completion,
                .{ .slice = &self.cmd_fifo_buf },
                Master,
                self,
                cmdFifoReadCallback,
            );
            return .disarm;
        }

        // Process incoming bytes, looking for newline-delimited commands
        const data = self.cmd_fifo_buf[0..n];
        for (data) |byte| {
            if (byte == '\n') {
                // Complete command - send to clients, except agent state, which is ours
                if (self.cmd_line_len > 0) {
                    const line = self.cmd_line_buf[0..self.cmd_line_len];
                    if (std.mem.startsWith(u8, line, "state;")) {
                        self.handleAgentState(line["state;".len..]);
                    } else if (std.mem.startsWith(u8, line, "task;")) {
                        // Goes out with the state line after it
                        if (self.pane.setTask(line["task;".len..])) self.pane_dirty = true;
                    } else if (std.mem.startsWith(u8, line, "push;")) {
                        self.handlePush(line["push;".len..]);
                    } else if (line.len > 0 and line[0] == '@') {
                        self.sendCommandToDevice(line[1..]);
                    } else if (std.mem.startsWith(u8, line, "upgrade;")) {
                        const path = line["upgrade;".len..];
                        if (path.len < self.upgrade_to.len) {
                            @memcpy(self.upgrade_to[0..path.len], path);
                            self.upgrade_to_len = path.len;
                        }
                    } else {
                        self.sendCommandToClients(line);
                    }
                    self.cmd_line_len = 0;
                }
            } else {
                // Accumulate byte
                if (self.cmd_line_len < self.cmd_line_buf.len) {
                    self.cmd_line_buf[self.cmd_line_len] = byte;
                    self.cmd_line_len += 1;
                }
            }
        }

        // Only returns if it didn't happen
        if (self.upgrade_to_len > 0) {
            const path = self.upgrade_to[0..self.upgrade_to_len];
            self.upgrade_to_len = 0;
            self.upgradeTo(path);
        }

        // Re-arm command FIFO read
        self.cmd_fifo_stream.read(
            loop,
            &self.cmd_fifo_completion,
            .{ .slice = &self.cmd_fifo_buf },
            Master,
            self,
            cmdFifoReadCallback,
        );
        return .disarm;
    }

    /// Replace this process with the rtach at `path`, keeping the session: its PTY,
    /// socket, command pipe and shell (upgrade.zig). Returns only if that didn't happen,
    /// and then this master carries on as it was.
    fn upgradeTo(self: *Master, path: []const u8) void {
        // Not with the PTY one row short
        if (self.nudging) self.finishNudge();
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return;
        if (std.c.access(path_z, std.c.X_OK) != 0) {
            log.warn("upgrade: {s} isn't an executable, staying on {s}", .{ path, version });
            return;
        }
        // The same binary (a second upgrade request, already handled)
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.process.executablePath(self.io, &exe_buf)) |exe_len| {
            if (std.c.realpath(path_z, &real_buf)) |real| {
                if (std.mem.eql(u8, std.mem.span(real), exe_buf[0..exe_len])) {
                    log.info("upgrade: already running {s}", .{path});
                    return;
                }
            }
        } else |_| {}

        const pane = &self.pane;
        const state: live.State = .{
            .rtach = version,
            .command = self.options.command,
            .scrollback_capacity = self.scrollback.capacity(),
            .scrollback_total_written = self.scrollback_total_written,
            .rows = self.winsize.rows,
            .cols = self.winsize.cols,
            .alt_screen = self.modes.alt_screen,
            .cursor_visible = self.modes.cursor_visible,
            .mode_flags = @intCast(self.modes.flags.mask),
            .mouse_event = self.modes.mouse_event,
            .mouse_format = self.modes.mouse_format,
            .autowrap = self.modes.autowrap,
            .keypad_app = self.modes.keypad_app,
            .kitty_main = self.modes.kitty_main.flags,
            .kitty_main_idx = self.modes.kitty_main.idx,
            .kitty_alt = self.modes.kitty_alt.flags,
            .kitty_alt_idx = self.modes.kitty_alt.idx,
            .modify_keys = self.modes.modify_keys,
            .cursor_style = self.modes.cursor_style,
            .title = self.terminal_title[0..self.terminal_title_len],
            .fg = pane.fgName(),
            .cwd = pane.cwdPath(),
            .agent = @tagName(pane.agent),
            .status = @tagName(pane.status),
            .note = pane.noteText(),
            .task = pane.taskText(),
            .from_hook = pane.from_hook,
            .flushed_status = @tagName(self.flushed_status),
            .pushed_status = @tagName(self.pushed_status),
            .cmd_partial = self.cmd_line_buf[0..self.cmd_line_len],
        };
        const stored = self.scrollback.slices();
        live.save(self.io, self.allocator, self.options.socket_path, state, stored.first, stored.second) catch |err| {
            log.warn("upgrade: couldn't save the session's state ({}), staying on {s}", .{ err, version });
            return;
        };

        var args: [4][32:0]u8 = undefined;
        const values = [_]i64{ self.pty_master, self.socket_fd, self.cmd_fifo_fd, self.child_pid };
        var argv: [8:null]?[*:0]const u8 = undefined;
        argv[0] = path_z;
        argv[1] = "--resume";
        argv[2] = @ptrCast(self.options.socket_path.ptr); // NUL-terminated: from argv
        for (values, 0..) |value, i| {
            _ = std.fmt.bufPrintZ(&args[i], "{d}", .{value}) catch return;
            argv[3 + i] = &args[i];
        }
        argv[7] = null;

        // Clients reconnect to the new master. Shut down, not closed: if the exec fails,
        // their callbacks clean them up as usual.
        for (self.clients.items) |client| {
            if (client.pending_remove) continue;
            sys.shutdown(client.fd);
            client.pending_remove = true;
        }
        // Everything else closes on exec: the event loop's fds above all, which could
        // otherwise hold reads on the PTY
        var fd: posix.fd_t = 3;
        while (fd < 4096) : (fd += 1) {
            if (sys.isOpen(fd)) sys.setCloexec(fd);
        }
        for ([_]posix.fd_t{ self.pty_master, self.socket_fd, self.cmd_fifo_fd }) |kept| sys.clearCloexec(kept);

        log.info("upgrade: {s} -> {s}", .{ version, path });
        sys.execveZ(path_z, &argv, @ptrCast(std.c.environ));

        // Still here: the exec failed
        log.err("upgrade: exec {s} failed, staying on {s}", .{ path, version });
        var state_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (live.statePath(&state_buf, self.options.socket_path)) |state_path| sys.unlink(state_path);
    }

    /// Send a command to all attached clients via protocol message
    fn sendCommandToClients(self: *Master, cmd: []const u8) void {
        log.info("sending command to clients: {s}", .{cmd});

        const target = self.pickCommandTarget();
        if (target) |client| {
            writeFramed(client.fd, .command, cmd);
        } else {
            log.info("no eligible command client (dropping command)", .{});
        }
    }

    fn isClientEligible(self: *Master, client: *ClientConn, require_commands: bool) bool {
        _ = self;
        if (client.pending_remove or !client.attached) return false;
        if (require_commands and (!client.supports_commands or !client.framed_mode)) return false;
        return true;
    }

    fn mostRecentActivityClient(self: *Master, require_commands: bool) ?*ClientConn {
        var best: ?*ClientConn = null;
        var best_time: i128 = 0;

        for (self.clients.items) |client| {
            if (!self.isClientEligible(client, require_commands)) continue;
            const activity = @max(client.last_claim_ns, client.last_input_ns);
            if (activity == 0) continue;
            if (activity > best_time) {
                best_time = activity;
                best = client;
            }
        }

        return best;
    }

    fn mostRecentAttachClient(self: *Master, require_commands: bool) ?*ClientConn {
        var best: ?*ClientConn = null;
        var best_time: i128 = 0;

        for (self.clients.items) |client| {
            if (!self.isClientEligible(client, require_commands)) continue;
            if (client.last_attach_ns == 0) continue;
            if (client.last_attach_ns > best_time) {
                best_time = client.last_attach_ns;
                best = client;
            }
        }

        return best;
    }

    fn pickActiveClient(self: *Master) ?*ClientConn {
        if (self.mostRecentActivityClient(false)) |activity| {
            return activity;
        }

        return self.mostRecentAttachClient(false);
    }

    fn updateActiveClient(self: *Master) void {
        const previous = self.active_client;
        const chosen = self.pickActiveClient();
        if (previous != chosen) {
            log.debug("active client update: {} -> {}", .{
                if (previous) |client| client.fd else -1,
                if (chosen) |client| client.fd else -1,
            });
        }
        self.active_client = chosen;
    }

    fn isSizeEligible(self: *Master, client: *ClientConn) bool {
        if (!self.isClientEligible(client, false)) return false;
        return client.size != null and !client.paused;
    }

    /// The client in use: latest claim or input, else latest attach, among clients
    /// that are showing the session. Yielded ones (paused since, or attached in the
    /// background) only when no other client is: they don't take the size from one in
    /// use, but a pane nobody else shows gets the size of the one showing it.
    fn pickSizeClient(self: *Master) ?*ClientConn {
        var best: ?*ClientConn = null;
        var best_activity: i128 = 0;
        var best_attach: i128 = 0;
        for (self.clients.items) |client| {
            if (!self.isSizeEligible(client)) continue;
            const activity = @max(client.last_claim_ns, client.last_input_ns);
            const better = if (best) |current|
                if (current.yielded != client.yielded)
                    current.yielded
                else
                    activity > best_activity or (activity == best_activity and client.last_attach_ns > best_attach)
            else
                true;
            if (better) {
                best = client;
                best_activity = activity;
                best_attach = client.last_attach_ns;
            }
        }
        return best;
    }

    /// Give the PTY the size of the client in use. With none (e.g. the only client
    /// paused in the background), the size stays as it is.
    fn updateSizeClient(self: *Master) void {
        const chosen = self.pickSizeClient();
        if (chosen != self.size_client) {
            log.debug("size client update: {} -> {}", .{
                if (self.size_client) |client| client.fd else -1,
                if (chosen) |client| client.fd else -1,
            });
            self.size_client = chosen;
        }
        if (chosen) |client| self.applyWinsize(client.size.?);
        self.tellSizes();
    }

    /// Tell the clients that asked (want_size) the PTY's size and whether it's theirs,
    /// when that changed. A client whose size it isn't gets output drawn for another
    /// client's size: the app then draws the terminal at this size, scaled to fit.
    fn tellSizes(self: *Master) void {
        for (self.clients.items) |client| {
            if (!client.wants_size or !client.framed_mode or client.pending_remove) continue;
            const size = Protocol.PtySize{
                .rows = self.winsize.rows,
                .cols = self.winsize.cols,
                .yours = self.size_client == client,
            };
            if (client.sent_size) |sent| {
                if (std.meta.eql(sent, size)) continue;
            }
            client.sent_size = size;
            writeFramed(client.fd, .pty_size, &size.toBytes());
        }
    }

    /// Resize the PTY, and signal the program when the size changed
    fn applyWinsize(self: *Master, ws: Protocol.Winsize) void {
        const size_changed = ws.cols != self.winsize.cols or ws.rows != self.winsize.rows;
        const pixels_changed = ws.xpixel != self.winsize.xpixel or ws.ypixel != self.winsize.ypixel;
        if (!size_changed and !pixels_changed) return;
        // A real size change is a redraw of its own: the nudge is done, at the new size
        const ends_nudge = self.nudging and size_changed;
        if (ends_nudge) self.nudging = false;
        defer if (ends_nudge) {
            for (self.clients.items) |client| {
                if (client.awaiting_ready and !client.pending_remove) self.sendReady(client);
            }
        };
        self.winsize = ws;
        const c_ws = posix.winsize{
            .row = ws.rows,
            .col = ws.cols,
            .xpixel = ws.xpixel,
            .ypixel = ws.ypixel,
        };
        _ = std.c.ioctl(self.pty_master, getTIOCSWINSZ(), &c_ws);

        // Explicitly send SIGWINCH to ensure the app redraws
        // TIOCSWINSZ should do this automatically, but it's not always reliable
        // Send to process GROUP (negative pid) so it reaches foreground apps like Claude Code
        if (size_changed and self.child_pid > 0) {
            _ = std.c.kill(-self.child_pid, posix.SIG.WINCH);
            log.info("winsize {}x{} -> sent SIGWINCH to pgrp {}", .{ ws.cols, ws.rows, self.child_pid });
        } else {
            log.debug("winsize {}x{}", .{ ws.cols, ws.rows });
        }
    }

    fn pickCommandTarget(self: *Master) ?*ClientConn {
        self.updateActiveClient();

        if (self.active_client) |client| {
            if (self.isClientEligible(client, true)) return client;
        }

        if (self.mostRecentActivityClient(true)) |activity| return activity;
        return self.mostRecentAttachClient(true);
    }

    /// Stored output as history.Stored: ring buffer slices plus the absolute position of
    /// the oldest byte
    fn storedOutput(self: *const Master) history.Stored {
        const slices = self.scrollback.slices();
        const len: u64 = slices.first.len + slices.second.len;
        return .{ .first = slices.first, .second = slices.second, .oldest = self.scrollback_total_written - len };
    }

    /// Send handshake to client after attach
    fn sendHandshake(client_fd: posix.fd_t) void {
        const handshake = Protocol.Handshake{ .flags = Protocol.HANDSHAKE_FLAG_HISTORY | Protocol.HANDSHAKE_FLAG_PTY_SIZE | Protocol.HANDSHAKE_FLAG_READY };
        const header = Protocol.ResponseHeader{
            .type = .handshake,
            .len = Protocol.Handshake.WIRE_SIZE,
        };

        var iov = [2]posix.iovec_const{
            .{ .base = header.toBytes().ptr, .len = Protocol.ResponseHeader.WIRE_SIZE },
            .{ .base = handshake.toBytes().ptr, .len = Protocol.Handshake.WIRE_SIZE },
        };

        writeAllVec(client_fd, &iov);
        log.info("sent handshake to client fd={}", .{client_fd});
    }

    fn acceptCallback(
        self_opt: ?*Master,
        loop: *xev.Loop,
        _: *xev.Completion,
        result: xev.AcceptError!xev.TCP,
    ) xev.CallbackAction {
        const self = self_opt orelse return .disarm;

        const client_tcp = result catch |err| {
            if (err == error.Again) {
                // Re-arm accept
                self.socket.accept(
                    loop,
                    &self.socket_completion,
                    Master,
                    self,
                    acceptCallback,
                );
                return .disarm;
            }
            log.err("accept error: {}", .{err});
            // Re-arm accept
            self.socket.accept(
                loop,
                &self.socket_completion,
                Master,
                self,
                acceptCallback,
            );
            return .disarm;
        };

        // Get the fd from the TCP wrapper (API differs between backends)
        // TCPStream (kqueue) has fd as a field, TCPDynamic (linux) has fd() method
        const client_fd = if (@hasField(@TypeOf(client_tcp), "fd"))
            client_tcp.fd
        else
            client_tcp.fd();

        // Create client state
        const client = self.allocator.create(ClientConn) catch {
            log.err("failed to allocate ClientConn for fd={}", .{client_fd});
            sys.close(client_fd);
            // Re-arm accept
            self.socket.accept(
                loop,
                &self.socket_completion,
                Master,
                self,
                acceptCallback,
            );
            return .disarm;
        };

        client.* = .{
            .fd = client_fd,
            .stream = xev.Stream.initFd(client_fd),
            .master = self,
        };

        self.clients.append(self.allocator, client) catch {
            log.err("failed to append client to list for fd={}", .{client_fd});
            self.allocator.destroy(client);
            sys.close(client_fd);
            // Re-arm accept
            self.socket.accept(
                loop,
                &self.socket_completion,
                Master,
                self,
                acceptCallback,
            );
            return .disarm;
        };

        log.info("client connected fd={}", .{client_fd});

        // Send handshake immediately so client knows rtach is running
        // This allows client to detect rtach and send upgrade packet
        sendHandshake(client_fd);

        // Set up read for this client using Stream abstraction
        client.stream.read(
            loop,
            &client.completion,
            .{ .slice = &client.read_buf },
            ClientConn,
            client,
            clientReadCallback,
        );

        // Re-arm accept
        self.socket.accept(
            loop,
            &self.socket_completion,
            Master,
            self,
            acceptCallback,
        );
        return .disarm;
    }

    fn clientReadCallback(
        client_opt: ?*ClientConn,
        loop: *xev.Loop,
        _: *xev.Completion,
        _: xev.Stream,
        _: xev.ReadBuffer,
        result: xev.ReadError!usize,
    ) xev.CallbackAction {
        const client = client_opt orelse return .disarm;
        const self = client.master;

        // Find client index
        var client_idx: ?usize = null;
        for (self.clients.items, 0..) |c, i| {
            if (c == client) {
                client_idx = i;
                break;
            }
        }

        const idx = client_idx orelse return .disarm;

        // Check for deferred destruction (e.g., duplicate client was kicked)
        if (client.pending_remove) {
            self.removeClient(idx);
            return .disarm;
        }

        const n = result catch |err| {
            if (err == error.Again) {
                // Re-arm client read
                client.stream.read(
                    loop,
                    &client.completion,
                    .{ .slice = &client.read_buf },
                    ClientConn,
                    client,
                    clientReadCallback,
                );
                return .disarm;
            }
            self.removeClient(idx);
            return .disarm;
        };

        if (n == 0) {
            self.removeClient(idx);
            return .disarm;
        }

        // Log received bytes for debugging (debug level to reduce noise)
        log.debug("client {} recv {} bytes, framed={}, first bytes: {any}", .{
            idx,
            n,
            client.framed_mode,
            client.read_buf[0..@min(n, 10)],
        });

        // Handle based on framed_mode
        if (client.framed_mode) {
            // Framed mode: parse input as packets
            var offset: usize = 0;
            while (offset < n) {
                const feed_result = client.reader.feed(client.read_buf[offset..n]);
                offset += feed_result.consumed;

                if (feed_result.packet) |pkt| {
                    self.handleClientPacket(idx, pkt) catch {
                        self.removeClient(idx);
                        return .disarm;
                    };
                }

                if (feed_result.consumed == 0) {
                    break;
                }
            }
        } else {
            // Raw mode: forward input to PTY, but watch for upgrade/attach packets
            var data = client.read_buf[0..n];

            // Check if data starts with upgrade packet [7, len, ...]
            // len can be 0 (no compression) or 1+ (with compression type)
            if (data.len >= 2 and data[0] == @intFromEnum(Protocol.MessageType.upgrade)) {
                const payload_len = data[1];
                const upgrade_packet_size: usize = 2 + @as(usize, payload_len);

                if (data.len >= upgrade_packet_size) {
                    // Upgrade detected! Switch to framed mode
                    client.framed_mode = true;

                    // Check for compression type in payload
                    if (payload_len >= 1 and data[2] == Protocol.COMPRESSION_ZLIB) {
                        client.compression_enabled = true;
                        log.info("client {} upgraded to framed mode with compression (detected in raw stream)", .{idx});
                    } else {
                        log.info("client {} upgraded to framed mode (detected in raw stream)", .{idx});
                    }

                    // Process remaining data (if any) as framed packets
                    if (data.len > upgrade_packet_size) {
                        var offset: usize = 0;
                        const remaining = data[upgrade_packet_size..];
                        while (offset < remaining.len) {
                            const feed_result = client.reader.feed(remaining[offset..]);
                            offset += feed_result.consumed;

                            if (feed_result.packet) |pkt| {
                                self.handleClientPacket(idx, pkt) catch {
                                    self.removeClient(idx);
                                    return .disarm;
                                };
                            }

                            if (feed_result.consumed == 0) break;
                        }
                    }
                }
            } else if (data.len >= 2 and data[0] == @intFromEnum(Protocol.MessageType.attach)) {
                // Attach packet in raw mode - process it (raw clients can still attach)
                const payload_len = data[1];
                const packet_len = 2 + @as(usize, payload_len);
                if (data.len >= packet_len) {
                    // Parse as attach packet using Packet.init
                    const pkt = Protocol.Packet.init(.attach, data[2..packet_len]);
                    self.handleClientPacket(idx, pkt) catch {
                        self.removeClient(idx);
                        return .disarm;
                    };
                    // Forward remaining data to PTY (if any)
                    if (data.len > packet_len) {
                        client.last_input_ns = self.nowNs();
                        self.updateActiveClient();
                        _ = sys.write(self.pty_master, data[packet_len..]) catch |err| {
                            log.warn("failed to write to PTY: {}", .{err});
                        };
                    }
                }
            } else {
                // Forward to PTY as raw input
                client.last_input_ns = self.nowNs();
                self.updateActiveClient();
                _ = sys.write(self.pty_master, data) catch |err| {
                    log.warn("failed to write to PTY: {}", .{err});
                };
            }
        }

        // Re-arm client read
        client.stream.read(
            loop,
            &client.completion,
            .{ .slice = &client.read_buf },
            ClientConn,
            client,
            clientReadCallback,
        );
        return .disarm;
    }

    fn handleClientPacket(self: *Master, idx: usize, pkt: Protocol.Packet) !void {
        switch (pkt.header.type) {
            .attach => {
                // Get client ID from attach packet (if provided)
                const client_id = pkt.getClientId();
                const resuming = pkt.getAttachFlags() & Protocol.ATTACH_FLAG_RESUME != 0;
                const wants_ready = pkt.getAttachFlags() & Protocol.ATTACH_FLAG_READY != 0;
                const background = pkt.getAttachFlags() & Protocol.ATTACH_FLAG_BACKGROUND != 0;

                // If client ID provided, kick any existing connection with same ID
                if (client_id) |id| {
                    for (self.clients.items) |other| {
                        if (other != self.clients.items[idx] and
                            !other.pending_remove and
                            other.client_id != null and
                            std.mem.eql(u8, &other.client_id.?, &id))
                        {
                            log.info("kicking duplicate client {} (same client_id as {})", .{ other.fd, idx });
                            // Mark for deferred destruction - don't destroy immediately because
                            // there may be an in-flight completion in the event loop that would
                            // cause a use-after-free when it fires.
                            other.pending_remove = true;
                            // Shut down rather than close: the pending read then returns EOF
                            // and its callback removes the client. Closing dropped the read
                            // silently on kqueue, so kicked clients were never removed.
                            sys.shutdown(other.fd);
                        }
                    }
                    self.clients.items[idx].client_id = id;
                }

                log.info("client {} attached (client_id: {}, alt_screen: {}, background: {})", .{ idx, if (client_id != null) @as(u64, @bitCast(client_id.?[0..8].*)) else 0, self.modes.alt_screen, background });
                self.clients.items[idx].attached = true;
                self.clients.items[idx].last_attach_ns = self.nowNs();
                // Loading the pane, not using it: leave the size with a client that is
                self.clients.items[idx].yielded = background;
                const size_before = self.winsize;
                self.updateActiveClient();
                self.updateSizeClient();
                // The attach resized the PTY: the program has a real size change to redraw for
                const resized = size_before.rows != self.winsize.rows or size_before.cols != self.winsize.cols;

                // Handshake already sent on connect, now send scrollback

                if (resuming) {
                    // Back after this master's live upgrade: its terminal has everything
                    // up to then, modes included. Only what came after.
                    const client = self.clients.items[idx];
                    const stored = self.storedOutput();
                    const from = @max(self.resumed_at orelse stored.end(), stored.oldest);
                    client.replay_start = from;
                    const offset: usize = @intCast(from - stored.oldest);
                    const range = self.scrollback.sliceRange(offset, stored.len() - offset);
                    writeFramedSlicesMaybeCompressed(client.fd, .terminal_data, range.first, range.second, client.compression_enabled);
                    log.info("client {} resumed after the upgrade: {} bytes since", .{ idx, stored.len() - offset });
                } else if (self.modes.alt_screen) {
                    // Skip sending scrollback if in alternate screen mode (vim, less, Claude Code, etc.)
                    // The TUI app will redraw itself when it receives SIGWINCH
                    // Sending old scrollback would corrupt the display
                    log.info("skipping scrollback (alternate screen active)", .{});
                    self.clients.items[idx].replay_start = self.scrollback_total_written;
                    // Switch client to alternate screen mode so it knows to interpret
                    // the following TUI content correctly. Without this, the client's
                    // terminal emulator thinks it's on the normal screen and scrolling
                    // behaves incorrectly (e.g., shows "@" artifacts in Claude Code).
                    // The main screen's keyboard flags first: Ghostty keeps them per
                    // screen, and they're back when the program leaves this one
                    var main_buf: [TermModes.KittyStack.max_restore_len]u8 = undefined;
                    const main = self.modes.mainScreenRestore(&main_buf);
                    if (main.len > 0) writeFramed(self.clients.items[idx].fd, .terminal_data, main);
                    writeFramed(self.clients.items[idx].fd, .terminal_data, "\x1b[?1049h");
                    log.debug("sent alternate screen switch", .{});
                    self.restoreModes(idx);
                } else {
                    // Only send last 16KB of scrollback on attach (a few screens worth)
                    // This prevents UI freezes when reconnecting to sessions with large history
                    // Older output is paged in on demand (request_history)
                    const max_initial_scrollback: usize = 16 * 1024;
                    const stored = self.storedOutput();
                    const total_len = stored.len();

                    // Start at a line start so the replay and the history before it
                    // don't split a line
                    var start = stored.oldest;
                    if (total_len > max_initial_scrollback) {
                        start = history.nextLineStart(stored, stored.end() - max_initial_scrollback);
                    }
                    const client = self.clients.items[idx];
                    client.replay_start = start;

                    const offset: usize = @intCast(start - stored.oldest);
                    const range = self.scrollback.sliceRange(offset, total_len - offset);
                    writeFramedSlicesMaybeCompressed(client.fd, .terminal_data, range.first, range.second, client.compression_enabled);
                    log.debug("sent last {}KB of {}KB scrollback", .{ (total_len - offset) / 1024, total_len / 1024 });

                    // The replay may start after the modes were set
                    self.restoreModes(idx);
                }

                if (wants_ready) {
                    const client = self.clients.items[idx];
                    if (!resuming and self.modes.alt_screen and !resized) {
                        // No replay, and no size change for the program to redraw for
                        client.awaiting_ready = true;
                        self.startNudge();
                    } else {
                        self.sendReady(client);
                    }
                }

                // Send idle notification if session is already idle
                // This ensures clients that attach to an idle session get the notification
                if (self.idle_notified) {
                    const header = Protocol.ResponseHeader{
                        .type = .idle,
                        .len = 0,
                    };
                    writeAll(self.clients.items[idx].fd, header.toBytes());
                    log.info("sent idle to newly attached client {} (session was already idle)", .{idx});
                }
            },
            _ => log.debug("client {} sent unknown packet type {}", .{ idx, @intFromEnum(pkt.header.type) }),
            .claim_active => {
                const client = self.clients.items[idx];
                const payload = pkt.getPayload();
                const commands_only = payload.len >= 1 and payload[0] & Protocol.CLAIM_FLAG_COMMANDS_ONLY != 0;
                client.supports_commands = true;
                if (!commands_only) {
                    client.last_claim_ns = self.nowNs();
                    client.yielded = false;
                }
                self.updateActiveClient();
                self.updateSizeClient();
                log.info("client {} claimed active{s}", .{ client.fd, if (commands_only) " (commands only)" else "" });
                self.writeActivePointer();
                self.writeDevicePointer(client);
            },
            .detach => {
                log.info("client {} detached", .{idx});
                self.clients.items[idx].attached = false;
                self.updateActiveClient();
                self.updateSizeClient();
                self.clearActivePointerIfUnreachable();
                self.clearDevicePointer(self.clients.items[idx]);
            },
            .push => {
                const payload = pkt.getPayload();
                if (payload.len > 0) {
                    const client = self.clients.items[idx];
                    client.last_input_ns = self.nowNs();
                    client.yielded = false;
                    self.updateActiveClient();
                    if (self.size_client != client) self.updateSizeClient();
                    _ = try sys.write(self.pty_master, payload);
                }
            },
            .winch => {
                // Every client's size is kept; the PTY takes the one in use
                const ws = pkt.getWinsize() orelse return;
                const client = self.clients.items[idx];
                client.size = ws;
                self.updateSizeClient();
            },
            .want_size => {
                const client = self.clients.items[idx];
                client.wants_size = true;
                client.sent_size = null;
                self.tellSizes();
            },
            .redraw => {
                if (self.modes.alt_screen) {
                    log.info("client {} redraw: skipping scrollback (alternate screen active)", .{idx});
                    if (self.child_pid > 0) {
                        _ = std.c.kill(-self.child_pid, posix.SIG.WINCH);
                        log.info("client {} redraw: sent SIGWINCH to pgrp {}", .{ idx, self.child_pid });
                    }
                    return;
                }

                const client = self.clients.items[idx];
                const slices = self.scrollback.slices();
                const total_len = slices.first.len + slices.second.len;
                log.info("client {} redraw: sending {}KB scrollback", .{ idx, total_len / 1024 });
                writeFramedSlicesMaybeCompressed(client.fd, .terminal_data, slices.first, slices.second, client.compression_enabled);
            },
            .request_scrollback => {
                // Client requests old scrollback (everything before the 16KB initial send)
                // LEGACY: sends all old scrollback at once - use request_scrollback_page instead

                // Skip if alternate screen is active
                if (self.modes.alt_screen) {
                    log.info("scrollback request: skipping (alternate screen active)", .{});
                    const header = Protocol.ResponseHeader{
                        .type = .scrollback,
                        .len = 0,
                    };
                    writeAll(self.clients.items[idx].fd, header.toBytes());
                    return;
                }

                const max_initial: usize = 16 * 1024;
                const slices = self.scrollback.slices();
                const total_len = slices.first.len + slices.second.len;

                if (total_len <= max_initial) {
                    // All scrollback was already sent on attach, nothing more to send
                    // Send empty response
                    const header = Protocol.ResponseHeader{
                        .type = .scrollback,
                        .len = 0,
                    };
                    writeAll(self.clients.items[idx].fd, header.toBytes());
                    log.info("scrollback request: no additional data (all sent on attach)", .{});
                } else {
                    // Send the OLD scrollback (everything before the last 16KB)
                    const old_len = total_len - max_initial;
                    const header = Protocol.ResponseHeader{
                        .type = .scrollback,
                        .len = @intCast(old_len),
                    };
                    writeAll(self.clients.items[idx].fd, header.toBytes());

                    // Send old scrollback data
                    if (old_len <= slices.first.len) {
                        // Old scrollback is entirely in first slice
                        writeAll(self.clients.items[idx].fd, slices.first[0..old_len]);
                    } else {
                        // Old scrollback spans first slice + part of second
                        const second_len = old_len - slices.first.len;
                        writeSlices(self.clients.items[idx].fd, slices.first, slices.second[0..second_len]);
                    }
                    log.debug("scrollback request: sent {}KB of old scrollback", .{old_len / 1024});
                }
            },
            .request_history => {
                const payload = pkt.getPayload();
                if (payload.len < Protocol.HistoryRequest.WIRE_SIZE) {
                    log.warn("request_history too short: {} bytes", .{payload.len});
                    return;
                }
                const req = Protocol.HistoryRequest.fromBytes(payload[0..Protocol.HistoryRequest.WIRE_SIZE]);
                const client = self.clients.items[idx];
                const before = if (req.before == Protocol.HISTORY_BEFORE_REPLAY) client.replay_start else req.before;

                const stored = self.storedOutput();
                const range = history.selectPage(stored, before, req.limit);
                var data: std.ArrayList(u8) = .empty;
                defer data.deinit(self.allocator);
                history.appendWithoutAltScreen(self.allocator, stored, range, &data) catch |err| {
                    log.warn("request_history: {}", .{err});
                    data.clearRetainingCapacity();
                };

                const meta = Protocol.HistoryPageMeta{ .start = range.start, .end = range.end, .oldest = stored.oldest };
                const meta_bytes = meta.toBytes();
                const header = Protocol.ResponseHeader{
                    .type = .history_page,
                    .len = @intCast(Protocol.HistoryPageMeta.WIRE_SIZE + data.items.len),
                };
                var iov = [3]posix.iovec_const{
                    .{ .base = header.toBytes().ptr, .len = Protocol.ResponseHeader.WIRE_SIZE },
                    .{ .base = &meta_bytes, .len = meta_bytes.len },
                    .{ .base = data.items.ptr, .len = data.items.len },
                };
                writeAllVec(client.fd, &iov);
                log.debug("history page {}..{} ({} bytes sent, oldest {})", .{ range.start, range.end, data.items.len, stored.oldest });
            },
            .request_scrollback_page => {
                // Paginated scrollback request - returns a chunk with metadata
                // Skip if alternate screen is active (vim, less, Claude Code, etc.)
                // These apps manage their own display and scrollback is irrelevant
                if (self.modes.alt_screen) {
                    log.info("scrollback_page: skipping (alternate screen active)", .{});
                    // Send empty response so client knows we're done
                    const header = Protocol.ResponseHeader{
                        .type = .scrollback_page,
                        .len = Protocol.ScrollbackPageMeta.WIRE_SIZE,
                    };
                    const meta = Protocol.ScrollbackPageMeta{
                        .total_len = 0,
                        .offset = 0,
                    };
                    const client_fd = self.clients.items[idx].fd;
                    writeAll(client_fd, header.toBytes());
                    writeAll(client_fd, meta.toBytes());
                    return;
                }

                const payload = pkt.getPayload();
                if (payload.len < Protocol.ScrollbackPageRequest.WIRE_SIZE) {
                    log.warn("scrollback_page request too short: {} bytes", .{payload.len});
                    return;
                }

                const req = Protocol.ScrollbackPageRequest.fromBytes(
                    payload[0..Protocol.ScrollbackPageRequest.WIRE_SIZE],
                );

                const total_len: u32 = @intCast(self.scrollback.size());
                const start: u32 = @min(req.offset, total_len);
                const available = total_len - start;
                const to_send: u32 = @min(available, req.limit);

                // Build response header (includes metadata size + data size)
                const response_len = Protocol.ScrollbackPageMeta.WIRE_SIZE + to_send;
                const header = Protocol.ResponseHeader{
                    .type = .scrollback_page,
                    .len = @intCast(response_len),
                };

                // Build metadata
                const meta = Protocol.ScrollbackPageMeta{
                    .total_len = total_len,
                    .offset = start,
                };

                const client_fd = self.clients.items[idx].fd;

                // Send header + metadata
                writeAll(client_fd, header.toBytes());
                writeAll(client_fd, meta.toBytes());

                // Send data slice using sliceRange helper
                if (to_send > 0) {
                    const range = self.scrollback.sliceRange(start, to_send);
                    writeSlices(client_fd, range.first, range.second);
                }

                log.debug("scrollback_page: offset={} limit={} sent={} total={}", .{
                    req.offset,
                    req.limit,
                    to_send,
                    total_len,
                });
            },
            .upgrade => {
                // Client signals it will now frame all input
                // Switch to framed mode - parse all subsequent input as packets
                const client = self.clients.items[idx];
                client.framed_mode = true;

                // Check for compression type in payload: [compression_type: 1 byte]
                // 0x01 = zlib compression requested
                const payload = pkt.getPayload();
                if (payload.len >= 1 and payload[0] == Protocol.COMPRESSION_ZLIB) {
                    client.compression_enabled = true;
                    log.info("client {} upgraded to framed mode with compression", .{idx});
                } else {
                    log.info("client {} upgraded to framed mode (no compression)", .{idx});
                }
            },
            .pause => {
                // Client requests to pause terminal output streaming (battery optimization)
                // We continue to buffer in scrollback, but don't send to this client
                const client = self.clients.items[idx];
                if (!client.paused) {
                    client.paused = true;
                    client.paused_total_written = self.scrollback_total_written;
                    log.info("client {} paused at total_written {}", .{ idx, client.paused_total_written });
                }
                client.yielded = true;
                self.updateSizeClient();
            },
            .@"resume" => {
                // Client requests to resume terminal output streaming
                // Send any buffered data since pause, then resume normal streaming
                const client = self.clients.items[idx];
                if (client.paused) {
                    const total_written = self.scrollback_total_written;
                    const buffer_len: u64 = @intCast(self.scrollback.size());
                    const oldest_available: u64 = if (total_written > buffer_len) total_written - buffer_len else 0;
                    var start: u64 = client.paused_total_written;

                    if (start < oldest_available) {
                        const dropped = oldest_available - start;
                        log.warn("client {} resume: buffered output overwritten ({} bytes lost)", .{ idx, dropped });
                        start = oldest_available;
                    }

                    const available = total_written - start;

                    if (available > 0 and buffer_len > 0) {
                        const len_to_send: u64 = @min(available, buffer_len);
                        const offset = @as(usize, @intCast(start - oldest_available));
                        const send_len = @as(usize, @intCast(len_to_send));
                        // Send buffered data since pause (best-effort if buffer wrapped)
                        const range = self.scrollback.sliceRange(offset, send_len);
                        writeFramedSlicesMaybeCompressed(client.fd, .terminal_data, range.first, range.second, client.compression_enabled);
                        log.info("client {} resumed: flushed {} bytes", .{ idx, len_to_send });
                    } else {
                        log.info("client {} resumed: no buffered data", .{idx});
                    }

                    client.paused = false;
                    client.paused_total_written = 0;
                    // Showing the pane again: it may be the only client that does
                    self.updateSizeClient();

                    // Always send SIGWINCH on resume to trigger TUI repaint
                    // This is needed because paused clients miss intermediate repaints
                    // (e.g., Claude Code spinner/timer stops while tab is inactive)
                    if (self.child_pid > 0) {
                        _ = std.c.kill(-self.child_pid, posix.SIG.WINCH);
                        log.info("client {} resume: sent SIGWINCH to pgrp {} ({}x{})", .{
                            idx,
                            self.child_pid,
                            self.winsize.cols,
                            self.winsize.rows,
                        });
                    }
                }
            },
        }
    }

    /// Put a newly attached client's terminal into the tracked modes. Programs set
    /// modes like mouse tracking once at startup, so a fresh terminal would lose them.
    fn restoreModes(self: *Master, idx: usize) void {
        var buf: [TermModes.max_restore_len]u8 = undefined;
        const seq = self.modes.restoreSequence(&buf);
        if (seq.len == 0) return;
        writeFramed(self.clients.items[idx].fd, .terminal_data, seq);
        log.debug("restored terminal modes ({} bytes)", .{seq.len});
    }

    /// Parse OSC 0/1/2 title sequences from terminal data
    /// OSC format: ESC ] N ; <title> (BEL | ST)
    /// Where N is 0, 1, or 2, BEL is 0x07, ST is ESC \
    /// Handles partial sequences across multiple PTY reads
    fn updateTerminalTitle(self: *Master, data: []const u8) void {
        for (data) |byte| {
            switch (self.osc_state) {
                .none => {
                    if (byte == 0x1B) { // ESC
                        self.osc_state = .got_esc;
                    }
                },
                .got_esc => {
                    if (byte == ']') { // OSC introducer
                        log.debug("OSC: got ESC ]", .{});
                        self.osc_state = .got_osc;
                    } else {
                        self.osc_state = .none;
                    }
                },
                .got_osc => {
                    // Looking for 0, 1, or 2 (title commands)
                    if (byte == '0' or byte == '1' or byte == '2') {
                        log.debug("OSC: got cmd {c}", .{byte});
                        self.osc_state = .got_cmd;
                    } else {
                        log.debug("OSC: unexpected byte after ESC ]: 0x{x:0>2}", .{byte});
                        self.osc_state = .none;
                    }
                },
                .got_cmd => {
                    if (byte == ';') {
                        // Start collecting title
                        log.debug("OSC: got semicolon, collecting title", .{});
                        self.osc_state = .in_title;
                        self.osc_buf_len = 0;
                    } else {
                        log.debug("OSC: expected semicolon but got 0x{x:0>2}", .{byte});
                        self.osc_state = .none;
                    }
                },
                .in_title => {
                    if (byte == 0x07) { // BEL - end of title
                        log.debug("OSC: got BEL, finishing title", .{});
                        self.finishTitle();
                        self.osc_state = .none;
                    } else if (byte == 0x1B) { // ESC - might be start of ST
                        log.debug("OSC: got ESC in title, checking for ST", .{});
                        self.osc_state = .got_esc_in_title;
                    } else if (self.osc_buf_len < self.osc_buf.len) {
                        self.osc_buf[self.osc_buf_len] = byte;
                        self.osc_buf_len += 1;
                    }
                    // If buffer full, keep collecting but don't store (truncate)
                },
                .got_esc_in_title => {
                    if (byte == '\\') { // ST (String Terminator) = ESC \
                        log.debug("OSC: got ST (ESC \\), finishing title", .{});
                        self.finishTitle();
                        self.osc_state = .none;
                    } else if (byte == ']') {
                        // New OSC starting, finish current and start new
                        log.debug("OSC: new OSC starting, finishing current", .{});
                        self.finishTitle();
                        self.osc_state = .got_osc;
                    } else {
                        // Not ST, store the ESC and this byte as part of title
                        log.debug("OSC: ESC not followed by ST, storing in title", .{});
                        if (self.osc_buf_len < self.osc_buf.len) {
                            self.osc_buf[self.osc_buf_len] = 0x1B;
                            self.osc_buf_len += 1;
                        }
                        if (self.osc_buf_len < self.osc_buf.len) {
                            self.osc_buf[self.osc_buf_len] = byte;
                            self.osc_buf_len += 1;
                        }
                        self.osc_state = .in_title;
                    }
                },
            }
        }
    }

    /// Complete title parsing - copy to terminal_title and mark dirty
    fn finishTitle(self: *Master) void {
        if (self.osc_buf_len > 0) {
            @memcpy(self.terminal_title[0..self.osc_buf_len], self.osc_buf[0..self.osc_buf_len]);
            self.terminal_title_len = self.osc_buf_len;
            self.title_dirty = true;
            log.debug("title set: \"{s}\"", .{self.terminal_title[0..self.terminal_title_len]});
            if (self.pane.applyTitle(self.terminal_title[0..self.terminal_title_len])) self.pane_dirty = true;
        }
    }

    /// `state;<status>;<note>` from an agent hook (`clauntty agent-state`)
    fn handleAgentState(self: *Master, args: []const u8) void {
        var parts = std.mem.splitScalar(u8, args, ';');
        const status = parts.next() orelse return;
        const note = parts.rest();
        log.info("agent state: {s}", .{status});
        if (self.pane.applyHook(status, note)) {
            // Right away: the app may notify the user
            self.pane_dirty = true;
            self.flushPaneState();
        }
    }

    /// Check the foreground process (every second, from the idle tick), and flush
    fn probePane(self: *Master) void {
        const now = self.nowNs();
        if (now - self.last_pane_probe_ns >= PANE_PROBE_INTERVAL_NS and self.pty_master >= 0) {
            self.last_pane_probe_ns = now;
            var name: [64]u8 = undefined;
            var cwd: [1024]u8 = undefined;
            if (pane_state.probe(self.pty_master, &name, &cwd)) |fg| {
                if (self.pane.setForeground(fg.name, fg.cwd)) self.pane_dirty = true;
            }
        }
        self.flushPaneState();
    }

    /// Write <socket>.state and tell the app (`pane;<id>;<json>`), if anything changed
    fn flushPaneState(self: *Master) void {
        if (!self.pane_dirty) return;
        self.pane_dirty = false;
        const status_changed = self.pane.status != self.flushed_status;
        self.flushed_status = self.pane.status;

        var json_buf: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&json_buf);
        self.pane.writeJson(&w, self.terminal_title[0..self.terminal_title_len], version) catch return;
        const json = w.buffered();

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}.state", .{self.options.socket_path}) catch return;
        const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.state.tmp", .{self.options.socket_path}) catch return;
        const cwd = std.Io.Dir.cwd();
        cwd.writeFile(self.io, .{ .sub_path = tmp, .data = json }) catch return;
        cwd.rename(tmp, cwd, path, self.io) catch return;

        // Only the app's sessions (~/.clauntty/sessions), not tests or sockets elsewhere
        const home = sys.getenv("HOME") orelse return;
        var sessions_buf: [std.fs.max_path_bytes]u8 = undefined;
        const sessions = std.fmt.bufPrint(&sessions_buf, "{s}/.clauntty/sessions/", .{home}) catch return;
        if (!std.mem.startsWith(u8, self.options.socket_path, sessions)) return;

        var msg_buf: [2200]u8 = undefined;
        const id = std.fs.path.basename(self.options.socket_path);
        const msg = std.fmt.bufPrint(&msg_buf, "{s};{s}", .{ id, json }) catch return;
        cli.notify(self.io, "pane", msg);
        if (status_changed) self.announce(id);
    }

    /// The agent finished or wants the user: a push, if the app isn't looking. The
    /// master of the session the app shows decides (it's where the app would be told),
    /// or this one when there's no such session.
    fn announce(self: *Master, id: []const u8) void {
        const status = self.pane.status;
        if (status != .done and status != .blocked) return;
        const now = self.nowNs();
        if (status == self.pushed_status and now - self.pushed_ns < PUSH_REPEAT_NS) return;
        self.pushed_status = status;
        self.pushed_ns = now;

        var label_buf: [160]u8 = undefined;
        const label = self.pane.agentLabel(self.terminal_title[0..self.terminal_title_len]);
        var name_buf: [128]u8 = undefined;
        const title = if (workspaces.workspaceName(self.allocator, self.io, id, &name_buf)) |name|
            if (std.mem.eql(u8, name, label)) name else std.fmt.bufPrint(&label_buf, "{s} · {s}", .{ name, label[0..@min(label.len, 120)] }) catch name
        else
            label;
        const body = if (status == .blocked)
            (if (self.pane.note_len > 0) self.pane.noteText() else "Needs you")
        else
            "Finished";

        var line_buf: [900]u8 = undefined;
        const notice = push.line(&line_buf, id, @tagName(status), title, body) orelse return;
        if (!cli.notifyActive(self.io, "push", notice)) self.handlePush(notice);
    }

    /// A pane's push notice (`push.line`): sent on unless the app is here and in the
    /// foreground (a paused client is an app in the background)
    fn handlePush(self: *Master, notice: []const u8) void {
        for (self.clients.items) |client| {
            if (client.attached and !client.paused and !client.pending_remove and client.supports_commands) {
                log.info("push: the app is here, not sending", .{});
                return;
            }
        }
        push.send(self.io, notice);
    }

    /// Write title to .title file (debounced, called from idle timer)
    fn writeTitleToFile(self: *Master) void {
        if (!self.title_dirty) return;

        const now = self.nowNs();
        if (now - self.last_title_write_ns < TITLE_WRITE_DEBOUNCE_NS) return;

        // Construct title file path: socket_path + ".title"
        var path_buf: [512]u8 = undefined;
        const title_path = std.fmt.bufPrint(&path_buf, "{s}.title", .{self.options.socket_path}) catch return;

        // Write atomically: write to .tmp, then rename
        var tmp_path_buf: [512]u8 = undefined;
        const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.title.tmp", .{self.options.socket_path}) catch return;

        // Use cwd-relative file operations (handles both absolute and relative paths)
        const cwd = std.Io.Dir.cwd();
        cwd.writeFile(self.io, .{ .sub_path = tmp_path, .data = self.terminal_title[0..self.terminal_title_len] }) catch |err| {
            log.warn("failed to write title: {}", .{err});
            return;
        };

        cwd.rename(tmp_path, cwd, title_path, self.io) catch |err| {
            log.warn("failed to rename title file: {}", .{err});
            return;
        };

        self.title_dirty = false;
        self.last_title_write_ns = now;
        log.info("wrote title to file: \"{s}\"", .{self.terminal_title[0..self.terminal_title_len]});
    }

    /// Monotonic nanoseconds, for idle detection and client activity ordering
    fn nowNs(self: *const Master) i128 {
        return std.Io.Timestamp.now(self.io, .awake).nanoseconds;
    }

    fn removeClient(self: *Master, idx: usize) void {
        const client = self.clients.items[idx];
        log.info("client {} disconnected", .{client.fd});
        if (self.active_client != null and self.active_client.? == client) {
            self.active_client = null;
        }
        if (self.size_client == client) self.size_client = null;
        client.attached = false;
        self.clearDevicePointer(client);
        sys.close(client.fd);
        self.allocator.destroy(client);
        _ = self.clients.swapRemove(idx);
        self.updateActiveClient();
        self.updateSizeClient();
        self.clearActivePointerIfUnreachable();
    }

    // MARK: Active session pointer

    fn writeActivePointer(self: *Master) void {
        if (self.active_pointer_len == 0 or self.cmd_fifo_path_len == 0) return;
        const pointer = self.active_pointer_path[0..self.active_pointer_len];
        active.write(self.io, pointer, self.cmd_fifo_path[0..self.cmd_fifo_path_len]) catch |err| {
            log.warn("failed to write active pointer {s}: {}", .{ pointer, err });
        };
    }

    /// This device's pointer at this session (active.devicePath)
    fn writeDevicePointer(self: *Master, client: *ClientConn) void {
        const id = client.client_id orelse return;
        if (self.active_pointer_len == 0 or self.cmd_fifo_path_len == 0) return;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = active.devicePath(self.active_pointer_path[0..self.active_pointer_len], &id, &buf) orelse return;
        if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};
        active.write(self.io, path, self.cmd_fifo_path[0..self.cmd_fifo_path_len]) catch |err| {
            log.warn("failed to write device pointer {s}: {}", .{ path, err });
        };
    }

    /// The device left this session: its pointer stops pointing here, unless another of
    /// its clients is still attached
    fn clearDevicePointer(self: *Master, leaving: *ClientConn) void {
        const id = leaving.client_id orelse return;
        for (self.clients.items) |client| {
            if (client == leaving or client.pending_remove or !client.attached) continue;
            if (client.client_id) |other| if (std.mem.eql(u8, &other, &id)) return;
        }
        if (self.active_pointer_len == 0 or self.cmd_fifo_path_len == 0) return;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = active.devicePath(self.active_pointer_path[0..self.active_pointer_len], &id, &buf) orelse return;
        active.clearIf(self.io, path, self.cmd_fifo_path[0..self.cmd_fifo_path_len]);
    }

    /// `@<client id in hex>;<command>` (cli.notify): the command for that device's
    /// client only
    fn sendCommandToDevice(self: *Master, addressed: []const u8) void {
        const sep = std.mem.indexOfScalar(u8, addressed, ';') orelse return;
        const hex = addressed[0..sep];
        const cmd = addressed[sep + 1 ..];
        for (self.clients.items) |client| {
            if (!self.isClientEligible(client, true)) continue;
            const id = client.client_id orelse continue;
            const id_hex = std.fmt.bytesToHex(id, .lower);
            if (std.mem.eql(u8, &id_hex, hex)) {
                writeFramed(client.fd, .command, cmd);
                return;
            }
        }
        log.debug("no client for device {s}, dropping: {s}", .{ hex, cmd });
    }

    fn clearActivePointer(self: *Master) void {
        if (self.active_pointer_len == 0 or self.cmd_fifo_path_len == 0) return;
        active.clearIf(self.io, self.active_pointer_path[0..self.active_pointer_len], self.cmd_fifo_path[0..self.cmd_fifo_path_len]);
    }

    /// Commands sent here would be dropped once no Clauntty client is left, so stop
    /// pointing at this session
    fn clearActivePointerIfUnreachable(self: *Master) void {
        for (self.clients.items) |client| {
            if (self.isClientEligible(client, true)) return;
        }
        self.clearActivePointer();
    }
};
