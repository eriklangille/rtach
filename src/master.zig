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
const Protocol = @import("protocol.zig");
const RingBuffer = @import("ringbuffer.zig").DynamicRingBuffer;
const ShellIntegration = @import("shell_integration.zig");

const log = std.log.scoped(.master);

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
        _ = posix.writev(fd, iov[0..iov_len]) catch {};
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

    _ = posix.writev(fd, &iov) catch {};
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

    _ = posix.writev(fd, iov[0..iov_len]) catch {};
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
    framed_mode: bool = false, // After upgrade, client input is parsed as packets
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

    // Command pipe - for scripts to send commands to Clauntty
    // Write end passed to child as RTACH_CMD_FD, read end monitored by master
    cmd_pipe_read: posix.fd_t = -1,
    cmd_pipe_write: posix.fd_t = -1,
    cmd_pipe_stream: xev.Stream = undefined,
    cmd_pipe_completion: xev.Completion = .{},
    cmd_pipe_buf: [512]u8 = undefined,
    cmd_line_buf: [512]u8 = undefined, // Buffer for accumulating partial lines
    cmd_line_len: usize = 0,

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

    // Cursor visibility state (DECTCEM mode)
    // When false, cursor should be hidden (TUI apps like Claude Code hide the cursor)
    cursor_visible: bool = true,

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
            .cmd_line_len = 0,
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

        // Create command pipe for scripts to send commands to Clauntty
        // Use pipe2 with O_NONBLOCK - both ends non-blocking is fine
        // (parent reads async via xev, child writes small commands that fit in pipe buffer)
        const cmd_pipe = try posix.pipe2(.{ .NONBLOCK = true });
        self.cmd_pipe_read = cmd_pipe[0];
        self.cmd_pipe_write = cmd_pipe[1];

        self.cmd_pipe_stream = xev.Stream.initFd(self.cmd_pipe_read);

        const pid = try posix.fork();
        if (pid == 0) {
            // Child process
            posix.close(master_fd);
            posix.close(self.cmd_pipe_read); // Close read end in child
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

            // Set RTACH_CMD_FD environment variable for scripts to send commands
            var fd_buf: [16]u8 = undefined;
            const fd_str = std.fmt.bufPrintZ(&fd_buf, "{}", .{self.cmd_pipe_write}) catch "3";
            _ = setenv("RTACH_CMD_FD", fd_str, 1);

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

        // Close write end in parent - only child writes to command pipe
        posix.close(self.cmd_pipe_write);
        self.cmd_pipe_write = -1;

        log.info("started child pid={} command={s}, cmd_fd={}", .{ pid, self.options.command, self.cmd_pipe_read });
    }

    fn closePty(self: *Master) void {
        if (self.pty_master >= 0) {
            posix.close(self.pty_master);
            self.pty_master = -1;
        }
        if (self.cmd_pipe_read >= 0) {
            posix.close(self.cmd_pipe_read);
            self.cmd_pipe_read = -1;
        }
        if (self.cmd_pipe_write >= 0) {
            posix.close(self.cmd_pipe_write);
            self.cmd_pipe_write = -1;
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

        // Set up command pipe read (for scripts to send commands to clients)
        if (self.cmd_pipe_read >= 0) {
            self.cmd_pipe_stream.read(
                &self.loop,
                &self.cmd_pipe_completion,
                .{ .slice = &self.cmd_pipe_buf },
                Master,
                self,
                cmdPipeReadCallback,
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

        // Track terminal mode state by scanning for escape sequences
        // Alternate screen: ESC[?1049h/l, ESC[?47h/l
        // Cursor visibility: ESC[?25h/l
        self.updateTerminalModeState(data);

        // Store in scrollback
        self.scrollback.write(data);

        // Forward to all attached clients (framed)
        for (self.clients.items) |client| {
            if (client.attached) {
                writeFramed(client.fd, .terminal_data, data);
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

    fn cmdPipeReadCallback(
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
                // Re-arm command pipe read
                self.cmd_pipe_stream.read(
                    loop,
                    &self.cmd_pipe_completion,
                    .{ .slice = &self.cmd_pipe_buf },
                    Master,
                    self,
                    cmdPipeReadCallback,
                );
                return .disarm;
            }
            log.warn("command pipe read error: {}", .{err});
            return .disarm;
        };

        if (n == 0) {
            // Pipe closed (child exited) - this is normal
            log.debug("command pipe closed", .{});
            return .disarm;
        }

        // Process incoming bytes, looking for newline-delimited commands
        const data = self.cmd_pipe_buf[0..n];
        for (data) |byte| {
            if (byte == '\n') {
                // Complete command - send to clients
                if (self.cmd_line_len > 0) {
                    self.sendCommandToClients(self.cmd_line_buf[0..self.cmd_line_len]);
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

        // Re-arm command pipe read
        self.cmd_pipe_stream.read(
            loop,
            &self.cmd_pipe_completion,
            .{ .slice = &self.cmd_pipe_buf },
            Master,
            self,
            cmdPipeReadCallback,
        );
        return .disarm;
    }

    /// Send a command to all attached clients via protocol message
    fn sendCommandToClients(self: *Master, cmd: []const u8) void {
        log.info("sending command to clients: {s}", .{cmd});

        // Send to all attached clients (framed)
        for (self.clients.items) |client| {
            if (client.attached) {
                writeFramed(client.fd, .command, cmd);
            }
        }
    }

    /// Send handshake to client after attach
    fn sendHandshake(client_fd: posix.fd_t) void {
        const handshake = Protocol.Handshake{};
        const header = Protocol.ResponseHeader{
            .type = .handshake,
            .len = Protocol.Handshake.WIRE_SIZE,
        };

        var iov = [2]posix.iovec_const{
            .{ .base = header.toBytes().ptr, .len = Protocol.ResponseHeader.WIRE_SIZE },
            .{ .base = handshake.toBytes().ptr, .len = Protocol.Handshake.WIRE_SIZE },
        };

        _ = posix.writev(client_fd, &iov) catch {};
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

                if (feed_result.consumed == 0) break;
            }
        } else {
            // Raw mode: forward input to PTY, but watch for upgrade packet
            // Upgrade packet is [type=7, len=0] = 2 bytes
            var data = client.read_buf[0..n];

            // Check if data starts with upgrade packet [7, 0]
            if (data.len >= 2 and data[0] == @intFromEnum(Protocol.MessageType.upgrade) and data[1] == 0) {
                // Upgrade detected! Switch to framed mode
                client.framed_mode = true;
                log.info("client {} upgraded to framed mode (detected in raw stream)", .{idx});

                // Process remaining data (if any) as framed packets
                if (data.len > 2) {
                    var offset: usize = 0;
                    const remaining = data[2..];
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
            } else {
                // Not upgrade - forward to PTY as raw input
                _ = posix.write(self.pty_master, data) catch |err| {
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

                // Handshake already sent on connect, now send scrollback

                // Skip sending scrollback if in alternate screen mode (vim, less, Claude Code, etc.)
                // The TUI app will redraw itself when it receives SIGWINCH
                // Sending old scrollback would corrupt the display
                if (self.in_alternate_screen) {
                    log.info("skipping scrollback (alternate screen active)", .{});
                    // Switch client to alternate screen mode so it knows to interpret
                    // the following TUI content correctly. Without this, the client's
                    // terminal emulator thinks it's on the normal screen and scrolling
                    // behaves incorrectly (e.g., shows "@" artifacts in Claude Code).
                    writeFramed(self.clients.items[idx].fd, .terminal_data, "\x1b[?1049h");
                    log.debug("sent alternate screen switch", .{});
                    // Restore cursor visibility state - TUI apps typically hide the cursor
                    if (!self.cursor_visible) {
                        writeFramed(self.clients.items[idx].fd, .terminal_data, "\x1b[?25l");
                        log.debug("restored hidden cursor state", .{});
                    }
                } else {
                    // Only send last 16KB of scrollback on attach (a few screens worth)
                    // This prevents UI freezes when reconnecting to sessions with large history
                    // Full scrollback is still stored and could be requested on-demand later
                    const max_initial_scrollback: usize = 16 * 1024;
                    const slices = self.scrollback.slices();
                    const total_len = slices.first.len + slices.second.len;

                    if (total_len <= max_initial_scrollback) {
                        // Small buffer - send all in one syscall (framed)
                        writeFramedSlices(self.clients.items[idx].fd, .terminal_data, slices.first, slices.second);
                    } else {
                        // Large buffer - only send the tail (framed)
                        const skip = total_len - max_initial_scrollback;
                        if (skip < slices.first.len) {
                            // Skip part of first slice, send rest of first + all of second
                            writeFramedSlices(self.clients.items[idx].fd, .terminal_data, slices.first[skip..], slices.second);
                        } else {
                            // Skip all of first slice, skip part of second
                            const skip_second = skip - slices.first.len;
                            writeFramed(self.clients.items[idx].fd, .terminal_data, slices.second[skip_second..]);
                        }
                        log.debug("sent last {}KB of {}KB scrollback", .{ max_initial_scrollback / 1024, total_len / 1024 });
                    }

                    // Restore cursor visibility state after scrollback
                    if (!self.cursor_visible) {
                        writeFramed(self.clients.items[idx].fd, .terminal_data, "\x1b[?25l");
                        log.debug("restored hidden cursor state", .{});
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
                    const size_changed = ws.cols != self.winsize.cols or ws.rows != self.winsize.rows;
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
                        // Send to process group (shell + all children including Claude Code)
                        _ = std.c.kill(-self.child_pid, posix.SIG.WINCH);
                        log.info("winsize {}x{} -> sent SIGWINCH to pgrp {}", .{ ws.cols, ws.rows, self.child_pid });
                    } else {
                        log.debug("winsize {}x{}", .{ ws.cols, ws.rows });
                    }
                }
            },
            .redraw => {
                const slices = self.scrollback.slices();
                writeFramedSlices(self.clients.items[idx].fd, .terminal_data, slices.first, slices.second);
            },
            .request_scrollback => {
                // Client requests old scrollback (everything before the 16KB initial send)
                // LEGACY: sends all old scrollback at once - use request_scrollback_page instead

                // Skip if alternate screen is active
                if (self.in_alternate_screen) {
                    log.info("scrollback request: skipping (alternate screen active)", .{});
                    const header = Protocol.ResponseHeader{
                        .type = .scrollback,
                        .len = 0,
                    };
                    _ = posix.write(self.clients.items[idx].fd, header.toBytes()) catch {};
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
                    _ = posix.write(self.clients.items[idx].fd, header.toBytes()) catch {};
                    log.info("scrollback request: no additional data (all sent on attach)", .{});
                } else {
                    // Send the OLD scrollback (everything before the last 16KB)
                    const old_len = total_len - max_initial;
                    const header = Protocol.ResponseHeader{
                        .type = .scrollback,
                        .len = @intCast(old_len),
                    };
                    _ = posix.write(self.clients.items[idx].fd, header.toBytes()) catch {};

                    // Send old scrollback data
                    if (old_len <= slices.first.len) {
                        // Old scrollback is entirely in first slice
                        _ = posix.write(self.clients.items[idx].fd, slices.first[0..old_len]) catch {};
                    } else {
                        // Old scrollback spans first slice + part of second
                        const second_len = old_len - slices.first.len;
                        writeSlices(self.clients.items[idx].fd, slices.first, slices.second[0..second_len]);
                    }
                    log.debug("scrollback request: sent {}KB of old scrollback", .{old_len / 1024});
                }
            },
            .request_scrollback_page => {
                // Paginated scrollback request - returns a chunk with metadata
                // Skip if alternate screen is active (vim, less, Claude Code, etc.)
                // These apps manage their own display and scrollback is irrelevant
                if (self.in_alternate_screen) {
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
                    _ = posix.write(client_fd, header.toBytes()) catch {};
                    _ = posix.write(client_fd, meta.toBytes()) catch {};
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
                _ = posix.write(client_fd, header.toBytes()) catch {};
                _ = posix.write(client_fd, meta.toBytes()) catch {};

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
                self.clients.items[idx].framed_mode = true;
                log.info("client {} upgraded to framed mode", .{idx});
            },
        }
    }

    /// Scan data for terminal mode escape sequences and update state
    /// Tracks:
    /// - Alternate screen: ESC[?1049h/l, ESC[?47h/l
    /// - Cursor visibility (DECTCEM): ESC[?25h/l
    fn updateTerminalModeState(self: *Master, data: []const u8) void {
        // Look for escape sequences in the data
        // We need to find ESC [ ? followed by a number, then h or l
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
                            const is_set = data[j] == 'h';
                            const is_reset = data[j] == 'l';

                            if (is_set or is_reset) {
                                switch (num) {
                                    // Alternate screen modes
                                    1049, 47 => {
                                        self.in_alternate_screen = is_set;
                                        log.debug("{s} alternate screen (mode {})", .{ if (is_set) "entered" else "exited", num });
                                    },
                                    // Cursor visibility (DECTCEM)
                                    25 => {
                                        self.cursor_visible = is_set;
                                        log.debug("cursor {s} (DECTCEM)", .{if (is_set) "shown" else "hidden"});
                                    },
                                    else => {},
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
