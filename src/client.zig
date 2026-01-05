const std = @import("std");
const xev = @import("xev");
const posix = std.posix;
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
    // Buffer for incomplete framed packets (when packet spans multiple reads)
    // 4KB buffer handles packets up to ~16 max-size push packets
    stdin_buffer: [4096]u8 = undefined,
    stdin_buffered: usize = 0,

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
        // Note: Don't log here - stderr goes to SSH channel and corrupts the framed protocol
    }

    fn setupRawTerminal(self: *Client) !void {
        self.stdin_is_tty = posix.isatty(STDIN_FILENO);
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
            _ = try posix.write(self.socket_fd, pkt.serialize());
        }
    }

    /// Wait for handshake from server and send upgrade packet
    fn handleProtocolUpgrade(self: *Client) !void {
        // Handshake frame: [type=255][len=8 LE][payload=8 bytes] = 13 bytes total
        const handshake_frame_size = Protocol.RESPONSE_HEADER_SIZE + Protocol.HANDSHAKE_SIZE;
        var buf: [handshake_frame_size]u8 = undefined;
        var received: usize = 0;

        // Read handshake frame with timeout (using poll)
        var poll_fds = [_]posix.pollfd{
            .{ .fd = self.socket_fd, .events = posix.POLL.IN, .revents = 0 },
        };

        while (received < handshake_frame_size) {
            // Poll with 5 second timeout
            const ready = posix.poll(&poll_fds, 5000) catch |err| {
                if (err == error.Interrupted) continue;
                return err;
            };

            if (ready == 0) {
                // Timeout - no handshake received, maybe old server version
                log.warn("No handshake received, proceeding without upgrade", .{});
                return;
            }

            if (poll_fds[0].revents & posix.POLL.IN != 0) {
                const n = try posix.read(self.socket_fd, buf[received..]);
                if (n == 0) return error.ConnectionClosed;
                received += n;
            }

            if (poll_fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR) != 0) {
                return error.ConnectionClosed;
            }
        }

        // Validate handshake frame
        const resp_type = buf[0];
        const resp_len = std.mem.readInt(u32, buf[1..5], .little);

        if (resp_type != @intFromEnum(Protocol.ResponseType.handshake) or resp_len != Protocol.HANDSHAKE_SIZE) {
            log.warn("Invalid handshake frame: type={}, len={}", .{ resp_type, resp_len });
            return;
        }

        // Parse handshake payload
        const handshake = Protocol.Handshake.parse(buf[Protocol.RESPONSE_HEADER_SIZE..]);
        if (handshake) |h| {
            if (h.isValid()) {
                self.handshake_received = true;

                if (self.options.proxy_mode) {
                    // Proxy mode: wait for iOS upgrade, only forward handshake to stdout
                    _ = try posix.write(STDOUT_FILENO, buf[0..handshake_frame_size]);
                } else {
                    // CLI mode: upgrade master immediately, no handshake forwarded to stdout
                    const upgrade_pkt = Protocol.Packet.initUpgrade();
                    _ = try posix.write(self.socket_fd, upgrade_pkt.serialize());
                }
            }
        }
    }

    fn sendPostUpgradeSetup(self: *Client) !void {
        const client_id_ptr: ?*const [Protocol.CLIENT_ID_SIZE]u8 = if (self.options.client_id) |*id| id else null;
        const attach_pkt = Protocol.Packet.initAttach(client_id_ptr);
        _ = try posix.write(self.socket_fd, attach_pkt.serialize());

        try self.sendWindowSize();

        // Handle redraw request if specified
        switch (self.options.redraw_method) {
            .ctrl_l => {
                const pkt = Protocol.Packet.init(.push, "\x0c");
                _ = try posix.write(self.socket_fd, pkt.serialize());
            },
            .winch => {
                const pkt = Protocol.Packet.initRedraw();
                _ = try posix.write(self.socket_fd, pkt.serialize());
            },
            .none => {},
        }
    }

    pub fn run(self: *Client) !void {
        // Setup raw terminal
        try self.setupRawTerminal();
        errdefer self.restoreTerminal();

        // Wait for handshake from server and send upgrade
        try self.handleProtocolUpgrade();

        const defer_setup = self.options.proxy_mode and self.handshake_received;
        if (defer_setup) {
            self.pending_post_upgrade_setup = true;
        } else {
            try self.sendPostUpgradeSetup();
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
                    _ = posix.write(self.socket_fd, data[0..upgrade_packet_size]) catch {};
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
                if (pkt_type == @intFromEnum(Protocol.MessageType.push)) {
                    // Forward the raw packet (header + payload) to master
                    const packet_size: usize = 2 + pkt_len_usize;
                    const raw_packet = data[offset..][0..packet_size];
                    _ = posix.write(self.socket_fd, raw_packet) catch return error.BrokenPipe;
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
                        _ = try posix.write(self.socket_fd, pkt.serialize());
                    }
                } else if (pkt_type == @intFromEnum(Protocol.MessageType.detach)) {
                    self.stdin_buffered = 0;
                    return true; // Detach
                } else if (pkt_type == @intFromEnum(Protocol.MessageType.pause)) {
                    // Forward pause to master
                    const pkt = Protocol.Packet.initPause();
                    _ = try posix.write(self.socket_fd, pkt.serialize());
                } else if (pkt_type == @intFromEnum(Protocol.MessageType.@"resume")) {
                    // Forward resume to master
                    const pkt = Protocol.Packet.initResume();
                    _ = try posix.write(self.socket_fd, pkt.serialize());
                } else if (pkt_type == @intFromEnum(Protocol.MessageType.claim_active)) {
                    // Forward active claim to master
                    const pkt = Protocol.Packet.initClaimActive();
                    _ = try posix.write(self.socket_fd, pkt.serialize());
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
                for (data) |c| {
                    if (c == detach_char) {
                        self.stdin_buffered = 0;
                        return true; // Detach
                    }
                }
            }

            // Send to master as push packets
            var offset: usize = 0;
            while (offset < data.len) {
                const chunk_size = @min(data.len - offset, Protocol.MAX_PAYLOAD_SIZE);
                const pkt = Protocol.Packet.init(.push, data[offset..][0..chunk_size]);
                _ = try posix.write(self.socket_fd, pkt.serialize());
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

        // Proxy mode or legacy server without handshake: forward raw bytes.
        if (self.options.proxy_mode or !self.handshake_received) {
            _ = try posix.write(STDOUT_FILENO, buf[0..n]);
            return;
        }

        self.processFramedSocket(buf[0..n]);
    }

    fn processFramedSocket(self: *Client, data: []const u8) void {
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

            if (response_type == @intFromEnum(Protocol.ResponseType.terminal_data) and !is_compressed) {
                _ = posix.write(STDOUT_FILENO, chunk) catch {};
            }

            self.socket_payload_remaining -= take;
            offset += take;

            if (self.socket_payload_remaining == 0) {
                self.socket_payload_type = 0;
            }
        }
    }
};

// Global for signal handler
var global_client: ?*Client = null;
var winch_pending: bool = false;

fn handleSigwinch(_: c_int) callconv(.c) void {
    winch_pending = true;
}
