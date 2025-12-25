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
const ShellIntegration = @import("shell_integration.zig");

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
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

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
    client_id: ?[Protocol.CLIENT_ID_SIZE]u8 = null, // Unique client identifier
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

    // Alternate screen state tracking
    // When true, the terminal is in alternate screen mode (vim, less, Claude Code, etc.)
    // We skip sending scrollback on attach when in this mode since the TUI will redraw itself
    in_alternate_screen: bool = false,

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

            // Deploy shell integration files
            ShellIntegration.deployIntegrationFiles() catch |err| {
                log.warn("failed to deploy shell integration: {}", .{err});
            };

            // Detect shell type and prepare args with integration
            const shell_type = ShellIntegration.detectShellType(self.options.command);
            log.info("detected shell type: {s}", .{@tagName(shell_type)});

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
                _ = posix.execvpeZ(@ptrCast(self.options.command.ptr), &argv, std.c.environ) catch {};
                posix.exit(127);
            };

            // Set extra environment variable if needed (e.g., ZDOTDIR for zsh)
            if (shell_setup.env_name) |name| {
                if (shell_setup.env_value) |value| {
                    _ = setenv(name, value, 1);
                }
            }

            // Log the command being executed
            log.info("executing shell: {s}", .{shell_setup.argv[0].?});
            if (shell_setup.argc > 1) {
                if (shell_setup.argv[1]) |arg1| {
                    log.info("  arg1: {s}", .{arg1});
                }
            }
            if (shell_setup.argc > 2) {
                if (shell_setup.argv[2]) |arg2| {
                    log.info("  arg2: {s}", .{arg2});
                }
            }

            // Execute shell with integration
            _ = posix.execvpeZ(shell_setup.argv[0].?, &shell_setup.argv, std.c.environ) catch {};
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

        // Track alternate screen state by scanning for escape sequences
        // ESC[?1049h = enter alternate screen, ESC[?1049l = exit
        // ESC[?47h / ESC[?47l = older variant
        self.updateAlternateScreenState(data);

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
                // Get client ID from attach packet (if provided)
                const client_id = pkt.getClientId();

                // If client ID provided, kick any existing connection with same ID
                if (client_id) |id| {
                    var i: usize = 0;
                    while (i < self.clients.items.len) {
                        const other = self.clients.items[i];
                        if (i != idx and other.client_id != null and std.mem.eql(u8, &other.client_id.?, &id)) {
                            log.info("kicking duplicate client {} (same client_id as {})", .{ i, idx });
                            posix.close(other.fd);
                            self.allocator.destroy(other);
                            _ = self.clients.swapRemove(i);
                            // Adjust idx if needed (swapRemove may have moved our client)
                            if (idx == self.clients.items.len) {
                                // Our client was swapped, now at position i
                                return self.handleClientPacket(i, pkt);
                            }
                            // Don't increment i - check the swapped element
                        } else {
                            i += 1;
                        }
                    }
                    self.clients.items[idx].client_id = id;
                }

                log.info("client {} attached (client_id: {}, alt_screen: {})", .{ idx, if (client_id != null) @as(u64, @bitCast(client_id.?[0..8].*)) else 0, self.in_alternate_screen });
                self.clients.items[idx].attached = true;

                // Skip sending scrollback if in alternate screen mode (vim, less, Claude Code, etc.)
                // The TUI app will redraw itself when it receives SIGWINCH
                // Sending old scrollback would corrupt the display
                if (self.in_alternate_screen) {
                    log.info("skipping scrollback (alternate screen active)", .{});
                } else {
                    // Only send last 16KB of scrollback on attach (a few screens worth)
                    // This prevents UI freezes when reconnecting to sessions with large history
                    // Full scrollback is still stored and could be requested on-demand later
                    const max_initial_scrollback: usize = 16 * 1024;
                    const slices = self.scrollback.slices();
                    const total_len = slices.first.len + slices.second.len;

                    if (total_len <= max_initial_scrollback) {
                        // Small buffer - send all
                        if (slices.first.len > 0) {
                            _ = posix.write(self.clients.items[idx].fd, slices.first) catch {};
                        }
                        if (slices.second.len > 0) {
                            _ = posix.write(self.clients.items[idx].fd, slices.second) catch {};
                        }
                    } else {
                        // Large buffer - only send the tail
                        const skip = total_len - max_initial_scrollback;
                        if (skip < slices.first.len) {
                            // Skip part of first slice, send rest of first + all of second
                            _ = posix.write(self.clients.items[idx].fd, slices.first[skip..]) catch {};
                            if (slices.second.len > 0) {
                                _ = posix.write(self.clients.items[idx].fd, slices.second) catch {};
                            }
                        } else {
                            // Skip all of first slice, skip part of second
                            const skip_second = skip - slices.first.len;
                            _ = posix.write(self.clients.items[idx].fd, slices.second[skip_second..]) catch {};
                        }
                        log.info("sent last {}KB of {}KB scrollback", .{ max_initial_scrollback / 1024, total_len / 1024 });
                    }
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
            .request_scrollback => {
                // Client requests old scrollback (everything before the 16KB initial send)
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
                    _ = posix.write(self.clients.items[idx].fd, std.mem.asBytes(&header)) catch {};
                    log.info("scrollback request: no additional data (all sent on attach)", .{});
                } else {
                    // Send the OLD scrollback (everything before the last 16KB)
                    const old_len = total_len - max_initial;
                    const header = Protocol.ResponseHeader{
                        .type = .scrollback,
                        .len = @intCast(old_len),
                    };
                    _ = posix.write(self.clients.items[idx].fd, std.mem.asBytes(&header)) catch {};

                    // Send old scrollback data
                    if (old_len <= slices.first.len) {
                        // Old scrollback is entirely in first slice
                        _ = posix.write(self.clients.items[idx].fd, slices.first[0..old_len]) catch {};
                    } else {
                        // Old scrollback spans first slice + part of second
                        if (slices.first.len > 0) {
                            _ = posix.write(self.clients.items[idx].fd, slices.first) catch {};
                        }
                        const second_len = old_len - slices.first.len;
                        _ = posix.write(self.clients.items[idx].fd, slices.second[0..second_len]) catch {};
                    }
                    log.info("scrollback request: sent {}KB of old scrollback", .{old_len / 1024});
                }
            },
        }
    }

    /// Scan data for alternate screen escape sequences and update state
    /// Looks for: ESC[?1049h (enter), ESC[?1049l (exit), ESC[?47h/l (older variant)
    fn updateAlternateScreenState(self: *Master, data: []const u8) void {
        // Look for escape sequences in the data
        // We need to find ESC [ ? followed by 1049 or 47, then h or l
        var i: usize = 0;
        while (i < data.len) {
            // Look for ESC (0x1B)
            if (data[i] == 0x1B) {
                // Check for CSI: ESC [
                if (i + 1 < data.len and data[i + 1] == '[') {
                    // Check for private mode: ?
                    if (i + 2 < data.len and data[i + 2] == '?') {
                        // Parse the number
                        var num: u32 = 0;
                        var j = i + 3;
                        while (j < data.len and data[j] >= '0' and data[j] <= '9') {
                            num = num * 10 + (data[j] - '0');
                            j += 1;
                        }
                        // Check for h (set) or l (reset) and matching number
                        if (j < data.len) {
                            if ((num == 1049 or num == 47)) {
                                if (data[j] == 'h') {
                                    self.in_alternate_screen = true;
                                    log.info("entered alternate screen (mode {})", .{num});
                                } else if (data[j] == 'l') {
                                    self.in_alternate_screen = false;
                                    log.info("exited alternate screen (mode {})", .{num});
                                }
                            }
                        }
                    }
                }
            }
            i += 1;
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
