const std = @import("std");
const builtin = @import("builtin");
// Use Dynamic API on Linux for runtime io_uring -> epoll fallback
const xev = if (builtin.os.tag == .linux)
    @import("xev").Dynamic
else
    @import("xev");
const posix = std.posix;
const Protocol = @import("protocol.zig");
const RingBuffer = @import("ringbuffer.zig").DynamicRingBuffer;

const log = std.log.scoped(.master);

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

pub const MasterOptions = struct {
    socket_path: []const u8,
    command: []const u8,
    scrollback_size: usize = 1024 * 1024,
};

/// Client connection state
const ClientConn = struct {
    fd: posix.fd_t,
    stream: xev.Stream,
    reader: Protocol.PacketReader = .{},
    attached: bool = false,
    completion: xev.Completion = .{},
    read_buf: [512]u8 = undefined,
    master: *Master = undefined,
};

pub const Master = struct {
    allocator: std.mem.Allocator,
    options: MasterOptions,

    // PTY
    pty_master: posix.fd_t = -1,
    pty_stream: xev.Stream = undefined,
    pty_slave_path: [256]u8 = undefined,
    child_pid: posix.pid_t = 0,

    // Unix socket (using TCP abstraction which works for any socket)
    socket_fd: posix.fd_t = -1,
    socket: xev.TCP = undefined,

    // Scrollback buffer
    scrollback: RingBuffer,

    // Connected clients
    clients: std.ArrayListUnmanaged(*ClientConn) = .{},

    // Event loop
    loop: xev.Loop,

    // xev completions for PTY and socket
    pty_completion: xev.Completion = .{},
    socket_completion: xev.Completion = .{},
    pty_read_buf: [4096]u8 = undefined,

    // Window size
    winsize: Protocol.Winsize = .{ .rows = 24, .cols = 80 },

    pub fn init(allocator: std.mem.Allocator, options: MasterOptions) !*Master {
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
            .options = options,
            .scrollback = try RingBuffer.init(allocator, options.scrollback_size),
            .clients = .{},
            .loop = try xev.Loop.init(.{}),
        };

        try self.createSocket();
        errdefer self.closeSocket();

        try self.createPty();
        errdefer self.closePty();

        return self;
    }

    pub fn deinit(self: *Master) void {
        self.loop.deinit();
        self.closeSocket();
        self.closePty();
        self.scrollback.deinit();

        for (self.clients.items) |client| {
            posix.close(client.fd);
            self.allocator.destroy(client);
        }
        self.clients.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    fn createSocket(self: *Master) !void {
        posix.unlink(self.options.socket_path) catch {};

        self.socket_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(self.socket_fd);

        var addr = std.posix.sockaddr.un{ .path = undefined, .family = posix.AF.UNIX };
        const path_len = @min(self.options.socket_path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], self.options.socket_path[0..path_len]);
        addr.path[path_len] = 0;

        try posix.bind(self.socket_fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        try posix.listen(self.socket_fd, 5);

        // Wrap in TCP abstraction (works for Unix sockets too)
        self.socket = xev.TCP.initFd(self.socket_fd);

        _ = std.c.chmod(@ptrCast(self.options.socket_path.ptr), 0o600);

        log.info("listening on {s}", .{self.options.socket_path});
    }

    fn closeSocket(self: *Master) void {
        if (self.socket_fd >= 0) {
            posix.close(self.socket_fd);
            posix.unlink(self.options.socket_path) catch {};
            self.socket_fd = -1;
        }
    }

    fn createPty(self: *Master) !void {
        const master_fd = posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .NONBLOCK = true }, 0) catch |err| {
            log.err("failed to open /dev/ptmx: {}", .{err});
            return err;
        };
        errdefer posix.close(master_fd);

        if (grantpt(master_fd) != 0) return error.GrantPtyFailed;
        if (unlockpt(master_fd) != 0) return error.UnlockPtyFailed;

        const slave_path = ptsname(master_fd) orelse return error.PtsnameFailed;
        const slave_len = std.mem.len(slave_path);
        @memcpy(self.pty_slave_path[0..slave_len], slave_path[0..slave_len]);
        self.pty_slave_path[slave_len] = 0;

        self.pty_master = master_fd;
        self.pty_stream = xev.Stream.initFd(master_fd);

        const pid = try posix.fork();
        if (pid == 0) {
            // Child process
            posix.close(master_fd);
            _ = posix.setsid() catch {};

            const slave_fd = posix.openZ(
                @ptrCast(&self.pty_slave_path),
                .{ .ACCMODE = .RDWR },
                0,
            ) catch {
                posix.exit(1);
            };

            // NOTE: Do NOT set PTY to raw mode here!
            // The shell should inherit default (cooked mode) PTY settings.
            // The shell will configure the terminal as needed (bash uses cooked mode,
            // vim/nano switch to raw mode when they start, etc.)

            posix.dup2(slave_fd, 0) catch {};
            posix.dup2(slave_fd, 1) catch {};
            posix.dup2(slave_fd, 2) catch {};
            if (slave_fd > 2) posix.close(slave_fd);

            const argv = [_:null]?[*:0]const u8{
                @ptrCast(self.options.command.ptr),
                null,
            };

            // Inherit parent's environment (critical for shell startup)
            _ = posix.execvpeZ(@ptrCast(self.options.command.ptr), &argv, std.c.environ) catch {};
            posix.exit(127);
        }

        self.child_pid = pid;
        log.info("started child pid={} command={s}", .{ pid, self.options.command });
    }

    fn closePty(self: *Master) void {
        if (self.pty_master >= 0) {
            posix.close(self.pty_master);
            self.pty_master = -1;
        }
        if (self.child_pid > 0) {
            _ = posix.kill(self.child_pid, posix.SIG.TERM) catch {};
            self.child_pid = 0;
        }
    }

    pub fn run(self: *Master) !void {
        log.info("master running with xev, scrollback={}KB", .{self.options.scrollback_size / 1024});

        // Set up PTY read using Stream abstraction
        self.pty_stream.read(
            &self.loop,
            &self.pty_completion,
            .{ .slice = &self.pty_read_buf },
            Master,
            self,
            ptyReadCallback,
        );

        // Set up socket accept using TCP abstraction
        self.socket.accept(
            &self.loop,
            &self.socket_completion,
            Master,
            self,
            acceptCallback,
        );

        // Run the event loop
        try self.loop.run(.until_done);

        log.info("master shutting down", .{});
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

        // Store in scrollback
        self.scrollback.write(data);

        // Forward to all attached clients
        for (self.clients.items) |client| {
            if (client.attached) {
                _ = posix.write(client.fd, data) catch {};
            }
        }

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

        // Get the fd from the TCP wrapper
        const client_fd = client_tcp.fd();

        // Create client state
        const client = self.allocator.create(ClientConn) catch {
            posix.close(client_fd);
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
            self.allocator.destroy(client);
            posix.close(client_fd);
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

        // Process packets
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

            if (feed_result.consumed == 0) break;
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
                log.info("client {} attached", .{idx});
                self.clients.items[idx].attached = true;

                const slices = self.scrollback.slices();
                if (slices.first.len > 0) {
                    _ = posix.write(self.clients.items[idx].fd, slices.first) catch {};
                }
                if (slices.second.len > 0) {
                    _ = posix.write(self.clients.items[idx].fd, slices.second) catch {};
                }
            },
            .detach => {
                log.info("client {} detached", .{idx});
                self.clients.items[idx].attached = false;
            },
            .push => {
                const payload = pkt.getPayload();
                if (payload.len > 0) {
                    _ = try posix.write(self.pty_master, payload);
                }
            },
            .winch => {
                if (pkt.getWinsize()) |ws| {
                    self.winsize = ws;
                    const c_ws = posix.winsize{
                        .row = ws.rows,
                        .col = ws.cols,
                        .xpixel = ws.xpixel,
                        .ypixel = ws.ypixel,
                    };
                    _ = std.c.ioctl(self.pty_master, getTIOCSWINSZ(), &c_ws);
                    log.debug("winsize {}x{}", .{ ws.cols, ws.rows });
                }
            },
            .redraw => {
                const slices = self.scrollback.slices();
                if (slices.first.len > 0) {
                    _ = posix.write(self.clients.items[idx].fd, slices.first) catch {};
                }
                if (slices.second.len > 0) {
                    _ = posix.write(self.clients.items[idx].fd, slices.second) catch {};
                }
            },
        }
    }

    fn removeClient(self: *Master, idx: usize) void {
        const client = self.clients.items[idx];
        log.info("client {} disconnected", .{client.fd});
        posix.close(client.fd);
        self.allocator.destroy(client);
        _ = self.clients.swapRemove(idx);
    }
};
