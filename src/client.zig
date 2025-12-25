const std = @import("std");
const xev = @import("xev");
const posix = std.posix;
const Protocol = @import("protocol.zig");

const log = std.log.scoped(.client);

const STDIN_FILENO = posix.STDIN_FILENO;
const STDOUT_FILENO = posix.STDOUT_FILENO;

pub const ClientOptions = struct {
    pub const RedrawMethod = enum { none, ctrl_l, winch };

    socket_path: []const u8,
    detach_char: ?u8 = 0x1c, // Ctrl+\ by default
    redraw_method: RedrawMethod = .none,
    client_id: ?[Protocol.CLIENT_ID_SIZE]u8 = null, // Unique client identifier
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    options: ClientOptions,
    socket_fd: posix.fd_t = -1,
    orig_termios: ?std.c.termios = null,
    running: bool = true,

    pub fn init(allocator: std.mem.Allocator, options: ClientOptions) !*Client {
        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .options = options,
        };

        try self.connect();
        return self;
    }

    pub fn deinit(self: *Client) void {
        self.restoreTerminal();
        if (self.socket_fd >= 0) {
            posix.close(self.socket_fd);
        }
        self.allocator.destroy(self);
    }

    fn connect(self: *Client) !void {
        // Create Unix domain socket
        self.socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        errdefer {
            posix.close(self.socket_fd);
            self.socket_fd = -1;
        }

        // Connect to server
        var addr = std.posix.sockaddr.un{ .path = undefined, .family = posix.AF.UNIX };
        const path_len = @min(self.options.socket_path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], self.options.socket_path[0..path_len]);
        addr.path[path_len] = 0;

        try posix.connect(self.socket_fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        log.info("connected to {s}", .{self.options.socket_path});
    }

    fn setupRawTerminal(self: *Client) !void {
        if (!posix.isatty(STDIN_FILENO)) {
            return;
        }

        var termios = try posix.tcgetattr(STDIN_FILENO);
        self.orig_termios = termios;

        // Raw mode
        termios.iflag.IGNBRK = false;
        termios.iflag.BRKINT = false;
        termios.iflag.PARMRK = false;
        termios.iflag.ISTRIP = false;
        termios.iflag.INLCR = false;
        termios.iflag.IGNCR = false;
        termios.iflag.ICRNL = false;
        termios.iflag.IXON = false;

        termios.oflag.OPOST = false;

        termios.lflag.ECHO = false;
        termios.lflag.ECHONL = false;
        termios.lflag.ICANON = false;
        termios.lflag.ISIG = false;
        termios.lflag.IEXTEN = false;

        termios.cflag.CSIZE = .CS8;
        termios.cflag.PARENB = false;

        termios.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        termios.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try posix.tcsetattr(STDIN_FILENO, .FLUSH, termios);
    }

    fn restoreTerminal(self: *Client) void {
        if (self.orig_termios) |termios| {
            posix.tcsetattr(STDIN_FILENO, .FLUSH, termios) catch {};
            self.orig_termios = null;
        }
    }

    fn sendWindowSize(self: *Client) !void {
        var ws: posix.winsize = undefined;
        if (std.c.ioctl(STDOUT_FILENO, std.c.T.IOCGWINSZ, &ws) == 0) {
            const pkt = Protocol.Packet.initWinch(.{
                .rows = ws.row,
                .cols = ws.col,
                .xpixel = ws.xpixel,
                .ypixel = ws.ypixel,
            });
            _ = try posix.write(self.socket_fd, pkt.serialize());
        }
    }

    pub fn run(self: *Client) !void {
        // Setup raw terminal
        try self.setupRawTerminal();
        errdefer self.restoreTerminal();

        // Send attach message with optional client_id
        const client_id_ptr: ?*const [Protocol.CLIENT_ID_SIZE]u8 = if (self.options.client_id) |*id| id else null;
        const attach_pkt = Protocol.Packet.initAttach(client_id_ptr);
        _ = try posix.write(self.socket_fd, attach_pkt.serialize());

        // Send initial window size
        try self.sendWindowSize();

        // Handle redraw request if specified
        switch (self.options.redraw_method) {
            .ctrl_l => {
                // Send Ctrl+L
                const pkt = Protocol.Packet.init(.push, "\x0c");
                _ = try posix.write(self.socket_fd, pkt.serialize());
            },
            .winch => {
                // Send redraw request
                const pkt = Protocol.Packet.initRedraw();
                _ = try posix.write(self.socket_fd, pkt.serialize());
            },
            .none => {},
        }

        // Setup SIGWINCH handler
        var sa = posix.Sigaction{
            .handler = .{ .handler = handleSigwinch },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.WINCH, &sa, null);

        // Store self pointer for signal handler
        global_client = self;
        defer global_client = null;

        // Main loop
        var poll_fds = [_]posix.pollfd{
            .{ .fd = STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.socket_fd, .events = posix.POLL.IN, .revents = 0 },
        };

        while (self.running) {
            // Check for pending window size change on every iteration
            // (signal may have arrived without interrupting poll)
            if (winch_pending) {
                winch_pending = false;
                self.sendWindowSize() catch {};
            }

            const ready = posix.poll(&poll_fds, -1) catch |err| {
                if (err == error.Interrupted) {
                    continue; // Will check winch_pending at top of loop
                }
                return err;
            };

            if (ready == 0) continue;

            // Check stdin
            if (poll_fds[0].revents & posix.POLL.IN != 0) {
                if (try self.handleStdin()) {
                    break; // Detach requested
                }
            }

            // Check socket
            if (poll_fds[1].revents & posix.POLL.IN != 0) {
                self.handleSocket() catch break;
            }

            if (poll_fds[1].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
                log.info("connection closed", .{});
                break;
            }
        }

        // Send detach
        const detach_pkt = Protocol.Packet.initDetach();
        _ = posix.write(self.socket_fd, detach_pkt.serialize()) catch {};

        self.restoreTerminal();
        log.info("detached", .{});
    }

    fn handleStdin(self: *Client) !bool {
        var buf: [256]u8 = undefined;
        const n = try posix.read(STDIN_FILENO, &buf);
        if (n == 0) return true;

        // Check for detach character
        if (self.options.detach_char) |detach_char| {
            for (buf[0..n]) |c| {
                if (c == detach_char) {
                    return true; // Detach
                }
            }
        }

        // Send to master
        var offset: usize = 0;
        while (offset < n) {
            const chunk_size = @min(n - offset, Protocol.MAX_PAYLOAD_SIZE);
            const pkt = Protocol.Packet.init(.push, buf[offset..][0..chunk_size]);
            _ = try posix.write(self.socket_fd, pkt.serialize());
            offset += chunk_size;
        }

        return false;
    }

    fn handleSocket(self: *Client) !void {
        var buf: [4096]u8 = undefined;
        const n = try posix.read(self.socket_fd, &buf);
        if (n == 0) return error.ConnectionClosed;

        // Write directly to stdout (raw terminal output from master)
        _ = try posix.write(STDOUT_FILENO, buf[0..n]);
    }
};

// Global for signal handler
var global_client: ?*Client = null;
var winch_pending: bool = false;

fn handleSigwinch(_: c_int) callconv(.c) void {
    winch_pending = true;
}
