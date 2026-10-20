const std = @import("std");
const xev = @import("xev");
const posix = std.posix;
const sys = @import("sys.zig");
const Protocol = @import("protocol.zig");
const compression = @import("compression.zig");

const log = std.log.scoped(.client);

const STDIN_FILENO = posix.STDIN_FILENO;
const STDOUT_FILENO = posix.STDOUT_FILENO;

pub const ClientOptions = struct {
    pub const RedrawMethod = enum { none, ctrl_l, winch };

    socket_path: []const u8,
    detach_char: ?u8 = 0x1c, // Ctrl+\ by default
    redraw_method: RedrawMethod = .none,
    client_id: ?[Protocol.CLIENT_ID_SIZE]u8 = null, // Unique client identifier
    proxy_mode: bool = false,
    /// Attach with ATTACH_FLAG_READY (the app asks with --ready)
    want_ready: bool = false,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    options: ClientOptions,
    socket_fd: posix.fd_t = -1,
    orig_termios: ?std.c.termios = null,
    running: bool = true,
    stdin_framed: bool = false, // True after iOS sends upgrade packet
    stdin_is_tty: bool = false,
    handshake_received: bool = false,
    pending_post_upgrade_setup: bool = false,
    socket_header_buf: [Protocol.RESPONSE_HEADER_SIZE]u8 = undefined,
    socket_header_read: usize = 0,
    socket_payload_remaining: usize = 0,
    socket_payload_type: u8 = 0,
    raw_socket_buffer: std.ArrayList(u8),
    // Buffer for incomplete framed packets (when packet spans multiple reads)
    // 4KB buffer handles packets up to ~16 max-size push packets
    stdin_buffer: [4096]u8 = undefined,
    stdin_buffered: usize = 0,
    /// The master said the session ended (`ended`): a closed connection is the end,
    /// not a live upgrade to reattach after
    ended: bool = false,
    /// A command frame being read, to spot `ended`
    command_buf: [16]u8 = undefined,
    command_len: usize = 0,
    /// Reattaching after a live upgrade: the attach asks for only what's new
    reattaching: bool = false,
    /// Reattaches in a row without output in between, so a master that keeps closing
    /// the connection doesn't keep this client reconnecting
    reattach_tries: u8 = 0,

    pub fn init(allocator: std.mem.Allocator, options: ClientOptions) !*Client {
        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .options = options,
            .raw_socket_buffer = .empty,
        };

        try self.connect();
        return self;
    }

    pub fn deinit(self: *Client) void {
        self.restoreTerminal();
        if (self.socket_fd >= 0) {
            sys.close(self.socket_fd);
        }
        self.raw_socket_buffer.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn connect(self: *Client) !void {
        // Create Unix domain socket
        self.socket_fd = try sys.unixSocket(false);
        errdefer {
            sys.close(self.socket_fd);
            self.socket_fd = -1;
        }

        // Connect to server
        try sys.connect(self.socket_fd, self.options.socket_path);
        // Note: Don't log here - stderr goes to SSH channel and corrupts the framed protocol
    }

    fn setupRawTerminal(self: *Client) !void {
        self.stdin_is_tty = sys.isatty(STDIN_FILENO);
        if (!self.stdin_is_tty) {
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
            _ = try sys.write(self.socket_fd, pkt.serialize());
        }
    }

    fn sendPostUpgradeSetup(self: *Client) !void {
        const client_id_ptr: ?*const [Protocol.CLIENT_ID_SIZE]u8 = if (self.options.client_id) |*id| id else null;
        if (self.reattaching) {
            self.reattaching = false;
            const attach_pkt = Protocol.Packet.initAttachFlags(client_id_ptr, Protocol.ATTACH_FLAG_RESUME);
            _ = try sys.write(self.socket_fd, attach_pkt.serialize());
            return self.sendWindowSize();
        }
        const attach_pkt = if (self.options.want_ready)
            Protocol.Packet.initAttachFlags(client_id_ptr, Protocol.ATTACH_FLAG_READY)
        else
            Protocol.Packet.initAttach(client_id_ptr);
        _ = try sys.write(self.socket_fd, attach_pkt.serialize());

        try self.sendWindowSize();

        // Handle redraw request if specified
        switch (self.options.redraw_method) {
            .ctrl_l => {
                const pkt = Protocol.Packet.init(.push, "\x0c");
                _ = try sys.write(self.socket_fd, pkt.serialize());
            },
            .winch => {
                const pkt = Protocol.Packet.initRedraw();
                _ = try sys.write(self.socket_fd, pkt.serialize());
            },
            .none => {},
        }
    }

    pub fn run(self: *Client) !void {
        // Setup raw terminal
        try self.setupRawTerminal();
        errdefer self.restoreTerminal();

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

            // Typing waits for the handshake: it would reach the master ahead of the
            // upgrade and attach, which then went to the shell as typed text and left
            // this client never attached. (Proxy mode reads the app's upgrade from stdin.)
            poll_fds[0].fd = if (self.handshake_received or self.options.proxy_mode) STDIN_FILENO else -1;
            poll_fds[0].revents = 0;

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
            } else if (poll_fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
                // stdin is gone with nothing left to read (e.g. a pipe whose writer closed,
                // or /dev/null on macOS, which poll reports as NVAL). Polling again would
                // return immediately forever and spin a core.
                log.info("stdin closed", .{});
                break;
            }

            // Check socket
            var closed = false;
            if (poll_fds[1].revents & posix.POLL.IN != 0) {
                self.handleSocket() catch {
                    closed = true;
                };
            }
            if (!closed and poll_fds[1].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
                closed = true;
            }
            if (closed) {
                log.info("connection closed", .{});
                if (!self.reattach()) break;
                poll_fds[1].fd = self.socket_fd;
            }
        }

        // Send detach
        const detach_pkt = Protocol.Packet.initDetach();
        _ = sys.write(self.socket_fd, detach_pkt.serialize()) catch {};

        self.restoreTerminal();
        log.info("detached", .{});
    }

    /// After the connection closed: if the session didn't end, its master was replaced
    /// by a newer rtach (live upgrade), which listens on the same socket. Attach to it
    /// again, so the terminal stays in the session. A master that's gone (crashed,
    /// killed) refuses the connection, and this returns false.
    fn reattach(self: *Client) bool {
        if (self.options.proxy_mode or self.ended or self.reattach_tries >= 3) return false;
        self.reattach_tries += 1;
        sys.close(self.socket_fd);
        self.socket_fd = -1;
        self.connect() catch return false;
        self.handshake_received = false;
        self.raw_socket_buffer.items.len = 0;
        self.socket_header_read = 0;
        self.socket_payload_remaining = 0;
        self.socket_payload_type = 0;
        self.command_len = 0;
        self.reattaching = true;
        log.info("reattaching after the master closed the connection", .{});
        return true;
    }

    fn handleStdin(self: *Client) !bool {
        // Read into remaining space in stdin_buffer (after any buffered data)
        const space_left = self.stdin_buffer.len - self.stdin_buffered;
        if (space_left == 0) {
            // Buffer full with incomplete data - shouldn't happen with 4KB buffer
            log.warn("stdin_buffer full, discarding", .{});
            self.stdin_buffered = 0;
            return false;
        }

        const n = try posix.read(STDIN_FILENO, self.stdin_buffer[self.stdin_buffered..]);
        if (n == 0) return true;

        self.stdin_buffered += n;
        var data = self.stdin_buffer[0..self.stdin_buffered];

        // Check for upgrade packet from iOS if not already in framed mode
        // Upgrade packet: [type=7][len=0 or 1][compression_type?]
        if (!self.stdin_framed) {
            if (data.len >= 2 and data[0] == @intFromEnum(Protocol.MessageType.upgrade)) {
                const payload_len = data[1];
                const upgrade_packet_size: usize = 2 + @as(usize, payload_len);

                if (data.len >= upgrade_packet_size) {
                    // iOS sent upgrade, switch to framed stdin parsing
                    self.stdin_framed = true;

                    // Forward upgrade packet to master so it knows compression preference
                    _ = sys.write(self.socket_fd, data[0..upgrade_packet_size]) catch {};
                    if (self.pending_post_upgrade_setup) {
                        self.pending_post_upgrade_setup = false;
                        self.sendPostUpgradeSetup() catch {};
                    }

                    data = data[upgrade_packet_size..]; // Skip upgrade packet
                    // Update buffer to skip upgrade packet
                    if (data.len > 0) {
                        std.mem.copyForwards(u8, &self.stdin_buffer, data);
                        self.stdin_buffered = data.len;
                        data = self.stdin_buffer[0..self.stdin_buffered];
                    } else {
                        self.stdin_buffered = 0;
                        return false;
                    }
                } else if (self.options.proxy_mode and self.handshake_received) {
                    // Wait for full upgrade packet before forwarding any input
                    return false;
                }
            } else if (self.options.proxy_mode and self.handshake_received) {
                if (data.len < 2) {
                    // Possible start of upgrade packet - wait for more
                    return false;
                }
                // Drop any non-upgrade bytes while waiting for iOS upgrade
                self.stdin_buffered = 0;
                return false;
            }
        }

        if (self.stdin_framed) {
            // Parse framed packets from iOS
            var offset: usize = 0;
            var pkt_count: usize = 0;
            while (offset + 2 <= data.len) {
                const pkt_type = data[offset];
                const pkt_len = data[offset + 1];
                const pkt_len_usize: usize = @as(usize, pkt_len);

                if (offset + 2 + pkt_len_usize > data.len) {
                    break; // Incomplete packet - wait for more data
                }

                pkt_count += 1;
                if (pkt_type == @intFromEnum(Protocol.MessageType.push) or
                    pkt_type == @intFromEnum(Protocol.MessageType.redraw) or
                    pkt_type == @intFromEnum(Protocol.MessageType.request_scrollback) or
                    pkt_type == @intFromEnum(Protocol.MessageType.request_scrollback_page) or
                    pkt_type == @intFromEnum(Protocol.MessageType.request_history) or
                    pkt_type == @intFromEnum(Protocol.MessageType.want_size))
                {
                    // Forward the raw packet (header + payload) to master
                    const packet_size: usize = 2 + pkt_len_usize;
                    const raw_packet = data[offset..][0..packet_size];
                    _ = sys.write(self.socket_fd, raw_packet) catch return error.BrokenPipe;
                } else if (pkt_type == @intFromEnum(Protocol.MessageType.winch)) {
                    // Forward winch to master
                    if (pkt_len == 8) {
                        const payload = data[offset + 2 ..][0..8];
                        const pkt = Protocol.Packet.initWinch(.{
                            .rows = std.mem.readInt(u16, payload[0..2], .little),
                            .cols = std.mem.readInt(u16, payload[2..4], .little),
                            .xpixel = std.mem.readInt(u16, payload[4..6], .little),
                            .ypixel = std.mem.readInt(u16, payload[6..8], .little),
                        });
                        _ = try sys.write(self.socket_fd, pkt.serialize());
                    }
                } else if (pkt_type == @intFromEnum(Protocol.MessageType.detach)) {
                    self.stdin_buffered = 0;
                    return true; // Detach
                } else if (pkt_type == @intFromEnum(Protocol.MessageType.pause)) {
                    // Forward pause to master
                    const pkt = Protocol.Packet.initPause();
                    _ = try sys.write(self.socket_fd, pkt.serialize());
                } else if (pkt_type == @intFromEnum(Protocol.MessageType.@"resume")) {
                    // Forward resume to master
                    const pkt = Protocol.Packet.initResume();
                    _ = try sys.write(self.socket_fd, pkt.serialize());
                } else if (pkt_type == @intFromEnum(Protocol.MessageType.claim_active)) {
                    // Forward active claim to master
                    const pkt = Protocol.Packet.initClaimActive();
                    _ = try sys.write(self.socket_fd, pkt.serialize());
                }
                // Other packet types: ignore
                offset += 2 + pkt_len_usize;
            }

            // Keep unprocessed data in buffer for next read
            if (offset > 0 and offset < data.len) {
                const remaining = data.len - offset;
                std.mem.copyForwards(u8, &self.stdin_buffer, data[offset..]);
                self.stdin_buffered = remaining;
            } else if (offset >= data.len) {
                // All data consumed
                self.stdin_buffered = 0;
            }
            // If offset == 0 and we have incomplete data, keep it all buffered (stdin_buffered unchanged)
        } else {
            // Raw mode: check for detach character and forward to master
            if (self.options.detach_char) |detach_char| {
                if (hasDetachKey(data, detach_char)) {
                    self.stdin_buffered = 0;
                    return true; // Detach
                }
            }

            // Send to master as push packets
            var offset: usize = 0;
            while (offset < data.len) {
                const chunk_size = @min(data.len - offset, Protocol.MAX_PAYLOAD_SIZE);
                const pkt = Protocol.Packet.init(.push, data[offset..][0..chunk_size]);
                _ = try sys.write(self.socket_fd, pkt.serialize());
                offset += chunk_size;
            }
            // Raw mode always consumes all data
            self.stdin_buffered = 0;
        }

        return false;
    }

    fn handleSocket(self: *Client) !void {
        var buf: [4096]u8 = undefined;
        const n = try posix.read(self.socket_fd, &buf);
        if (n == 0) return error.ConnectionClosed;

        if (self.options.proxy_mode) {
            if (!self.handshake_received) {
                try self.processRawSocketData(buf[0..n]);
            } else {
                _ = sys.write(STDOUT_FILENO, buf[0..n]) catch {};
            }
            return;
        }

        if (!self.handshake_received) {
            try self.processRawSocketData(buf[0..n]);
            return;
        }

        self.processFramedSocket(buf[0..n]);
    }

    fn dropRawPrefix(self: *Client, count: usize) void {
        if (count == 0) return;
        if (count >= self.raw_socket_buffer.items.len) {
            self.raw_socket_buffer.items.len = 0;
            return;
        }
        const remaining = self.raw_socket_buffer.items.len - count;
        std.mem.copyForwards(u8, self.raw_socket_buffer.items[0..remaining], self.raw_socket_buffer.items[count..]);
        self.raw_socket_buffer.items.len = remaining;
    }

    fn processRawSocketData(self: *Client, data: []const u8) !void {
        const handshake_frame_size = Protocol.RESPONSE_HEADER_SIZE + Protocol.HANDSHAKE_SIZE;

        if (self.options.proxy_mode) {
            _ = sys.write(STDOUT_FILENO, data) catch {};
        }

        try self.raw_socket_buffer.appendSlice(self.allocator, data);

        var i: usize = 0;
        while (i + handshake_frame_size <= self.raw_socket_buffer.items.len) {
            const buf = self.raw_socket_buffer.items;
            const type_byte = buf[i];
            const len = std.mem.readInt(u32, buf[i + 1 ..][0..4], .little);

            if (type_byte == @intFromEnum(Protocol.ResponseType.handshake) and len == Protocol.HANDSHAKE_SIZE) {
                const payload_start = i + Protocol.RESPONSE_HEADER_SIZE;
                const payload = buf[payload_start .. payload_start + Protocol.HANDSHAKE_SIZE];
                const handshake = Protocol.Handshake.parse(payload);
                if (handshake) |h| {
                    if (h.isValid()) {
                        if (!self.options.proxy_mode and i > 0) {
                            _ = sys.write(STDOUT_FILENO, buf[0..i]) catch {};
                        }

                        self.handshake_received = true;

                        if (self.options.proxy_mode) {
                            if (self.stdin_framed) {
                                self.sendPostUpgradeSetup() catch {};
                            } else {
                                self.pending_post_upgrade_setup = true;
                            }
                        } else {
                            const upgrade_pkt = Protocol.Packet.initUpgrade();
                            _ = sys.write(self.socket_fd, upgrade_pkt.serialize()) catch {};
                            self.sendPostUpgradeSetup() catch {};
                        }

                        if (!self.options.proxy_mode) {
                            const after = i + handshake_frame_size;
                            if (after < buf.len) {
                                self.processFramedSocket(buf[after..]);
                            }
                        }

                        self.raw_socket_buffer.items.len = 0;
                        return;
                    }
                }
            }
            i += 1;
        }

        const buf_len = self.raw_socket_buffer.items.len;
        if (self.options.proxy_mode) {
            if (buf_len > handshake_frame_size * 2) {
                const keep = handshake_frame_size - 1;
                if (buf_len > keep) {
                    self.dropRawPrefix(buf_len - keep);
                }
            }
        } else {
            if (buf_len > handshake_frame_size * 2) {
                const safe_len = buf_len - handshake_frame_size + 1;
                if (safe_len > 0) {
                    _ = sys.write(STDOUT_FILENO, self.raw_socket_buffer.items[0..safe_len]) catch {};
                    self.dropRawPrefix(safe_len);
                }
            }
        }
    }

    fn processFramedSocket(self: *Client, data: []const u8) void {
        const max_frame_len: u32 = 4 * 1024 * 1024;
        var offset: usize = 0;

        while (offset < data.len) {
            if (self.socket_payload_remaining == 0) {
                const needed = Protocol.RESPONSE_HEADER_SIZE - self.socket_header_read;
                const take = @min(needed, data.len - offset);
                std.mem.copyForwards(
                    u8,
                    self.socket_header_buf[self.socket_header_read..][0..take],
                    data[offset..][0..take],
                );
                self.socket_header_read += take;
                offset += take;

                if (self.socket_header_read < Protocol.RESPONSE_HEADER_SIZE) {
                    continue;
                }

                const type_byte = self.socket_header_buf[0];
                const payload_len = std.mem.readInt(u32, self.socket_header_buf[1..5], .little);
                const response_type = compression.getResponseType(type_byte);
                const is_valid = switch (response_type) {
                    @intFromEnum(Protocol.ResponseType.terminal_data),
                    @intFromEnum(Protocol.ResponseType.scrollback),
                    @intFromEnum(Protocol.ResponseType.command),
                    @intFromEnum(Protocol.ResponseType.scrollback_page),
                    @intFromEnum(Protocol.ResponseType.idle),
                    @intFromEnum(Protocol.ResponseType.handshake),
                    => true,
                    else => false,
                };

                if (!is_valid or payload_len > max_frame_len) {
                    _ = sys.write(STDOUT_FILENO, self.socket_header_buf[0..1]) catch {};
                    std.mem.copyForwards(
                        u8,
                        self.socket_header_buf[0..Protocol.RESPONSE_HEADER_SIZE - 1],
                        self.socket_header_buf[1..Protocol.RESPONSE_HEADER_SIZE],
                    );
                    self.socket_header_read = Protocol.RESPONSE_HEADER_SIZE - 1;
                    self.socket_payload_type = 0;
                    self.socket_payload_remaining = 0;
                    continue;
                }

                self.socket_payload_type = type_byte;
                self.socket_payload_remaining = @intCast(payload_len);
                self.socket_header_read = 0;

                if (self.socket_payload_remaining == 0) {
                    self.socket_payload_type = 0;
                }
                continue;
            }

            const take = @min(self.socket_payload_remaining, data.len - offset);
            const chunk = data[offset..][0..take];
            const response_type = compression.getResponseType(self.socket_payload_type);
            const is_compressed = compression.isCompressed(self.socket_payload_type);

            if (!is_compressed and
                (response_type == @intFromEnum(Protocol.ResponseType.terminal_data) or
                response_type == @intFromEnum(Protocol.ResponseType.scrollback)))
            {
                _ = sys.write(STDOUT_FILENO, chunk) catch {};
                self.reattach_tries = 0;
            } else if (response_type == @intFromEnum(Protocol.ResponseType.command)) {
                // Only `ended` matters: longer commands just count their length
                if (self.command_len + chunk.len <= self.command_buf.len) {
                    @memcpy(self.command_buf[self.command_len..][0..chunk.len], chunk);
                }
                self.command_len += chunk.len;
            }

            self.socket_payload_remaining -= take;
            offset += take;

            if (self.socket_payload_remaining == 0) {
                if (compression.getResponseType(self.socket_payload_type) == @intFromEnum(Protocol.ResponseType.command)) {
                    if (self.command_len == "ended".len and std.mem.eql(u8, self.command_buf[0..self.command_len], "ended")) {
                        self.ended = true;
                    }
                    self.command_len = 0;
                }
                self.socket_payload_type = 0;
            }
        }
    }
};

// Global for signal handler
var global_client: ?*Client = null;
var winch_pending: bool = false;

fn handleSigwinch(_: posix.SIG) callconv(.c) void {
    winch_pending = true;
}

/// Whether keyboard input has the detach key: the control character itself, or its
/// encoding while the program has turned on an extended keyboard mode, where the
/// terminal sends Ctrl+\ as `ESC [ 92 ; 5 u` (kitty's protocol, which Claude Code
/// turns on) or `ESC [ 27 ; 5 ; 92 ~` (xterm's modifyOtherKeys). Presses only, with
/// Ctrl and nothing else but Caps or Num Lock.
pub fn hasDetachKey(data: []const u8, detach_char: u8) bool {
    if (std.mem.indexOfScalar(u8, data, detach_char) != null) return true;
    // The key Ctrl turns into the character: Ctrl+\ is 0x1c, Ctrl+A 0x01 ('a')
    const key: u32 = switch (detach_char) {
        0x01...0x1a => detach_char + 0x60,
        0x00, 0x1b...0x1f => detach_char + 0x40,
        else => return false,
    };
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, data, i, "\x1b[")) |start| {
        i = start + 2;
        // Up to three ';' fields of ':' subfields, then the final byte
        var fields: [3][2]u32 = .{ .{ 0, 1 }, .{ 1, 1 }, .{ 0, 0 } };
        var field: usize = 0;
        var sub: usize = 0;
        var digits = false;
        const final: u8 = while (i < data.len) : (i += 1) {
            const c = data[i];
            switch (c) {
                '0'...'9' => {
                    if (field < 3 and sub < 2) {
                        if (!digits) fields[field][sub] = 0;
                        fields[field][sub] = fields[field][sub] *| 10 +| (c - '0');
                    }
                    digits = true;
                },
                ';' => {
                    field += 1;
                    sub = 0;
                    digits = false;
                },
                ':' => {
                    sub += 1;
                    digits = false;
                },
                0x40...0x7e => break c,
                else => break 0,
            }
        } else 0;
        const mods, const event, const code = switch (final) {
            'u' => .{ fields[1][0], fields[1][1], fields[0][0] },
            '~' => if (fields[0][0] == 27) .{ fields[1][0], 1, fields[2][0] } else continue,
            else => continue,
        };
        // Modifiers are 1 + bits: Ctrl 4, Caps Lock 64, Num Lock 128. Event 3 is a release.
        const ctrl_only = mods >= 1 and ((mods - 1) & ~@as(u32, 64 | 128)) == 4;
        if (code == key and ctrl_only and event != 3) return true;
    }
    return false;
}

test "hasDetachKey: the control character, and its extended keyboard encodings" {
    const t = std.testing;
    try t.expect(hasDetachKey("ab\x1ccd", 0x1c));
    try t.expect(!hasDetachKey("abcd", 0x1c));
    // kitty: plain, with a press event, with Caps Lock, with alternate keys
    try t.expect(hasDetachKey("\x1b[92;5u", 0x1c));
    try t.expect(hasDetachKey("x\x1b[92;5:1u", 0x1c));
    try t.expect(hasDetachKey("\x1b[92;69u", 0x1c));
    try t.expect(hasDetachKey("\x1b[92:124;5u", 0x1c));
    // Not a release, other modifiers, or another key
    try t.expect(!hasDetachKey("\x1b[92;5:3u", 0x1c));
    try t.expect(!hasDetachKey("\x1b[92;6u", 0x1c));
    try t.expect(!hasDetachKey("\x1b[92u", 0x1c));
    try t.expect(!hasDetachKey("\x1b[93;5u", 0x1c));
    // modifyOtherKeys
    try t.expect(hasDetachKey("\x1b[27;5;92~", 0x1c));
    try t.expect(!hasDetachKey("\x1b[27;3;92~", 0x1c));
    // Other detach characters (-e ^A)
    try t.expect(hasDetachKey("\x1b[97;5u", 0x01));
    // Other sequences around it
    try t.expect(hasDetachKey("\x1b[A\x1b[1;5C\x1b[92;5u", 0x1c));
    try t.expect(!hasDetachKey("\x1b[200~paste\x1b[201~", 0x1c));
}

