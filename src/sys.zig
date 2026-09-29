//! Thin wrappers over the POSIX calls rtach makes on raw file descriptors.
//!
//! Zig 0.16 removed most std.posix wrappers and says to either go up to std.Io or down
//! to std.posix.system. Files go through std.Io. What's here stays low: the PTY and
//! child setup (fork, setsid, exec: std.process.spawn can't give the child a
//! controlling terminal) and the non-blocking fds the libxev loop owns, which std.Io
//! would put under a second event model.
//!
//! rtach always links libc, so std.posix.system is libc. Unknown errnos become
//! error.Unexpected without a stack trace: stderr can be the SSH channel.

const std = @import("std");
const posix = std.posix;
const system = posix.system;

pub const fd_t = posix.fd_t;
pub const pid_t = posix.pid_t;

pub const WriteError = error{
    WouldBlock,
    BrokenPipe,
    ConnectionResetByPeer,
    InputOutput,
    NoSpaceLeft,
    Unexpected,
};

pub fn write(fd: fd_t, bytes: []const u8) WriteError!usize {
    while (true) {
        const rc = system.write(fd, bytes.ptr, bytes.len);
        return switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR => continue,
            else => |e| writeError(e),
        };
    }
}

pub fn writev(fd: fd_t, iovs: []const posix.iovec_const) WriteError!usize {
    while (true) {
        const rc = system.writev(fd, iovs.ptr, @intCast(iovs.len));
        return switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR => continue,
            else => |e| writeError(e),
        };
    }
}

fn writeError(e: posix.E) WriteError {
    return switch (e) {
        .AGAIN => error.WouldBlock,
        .PIPE => error.BrokenPipe,
        .CONNRESET => error.ConnectionResetByPeer,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        else => error.Unexpected,
    };
}

pub fn close(fd: fd_t) void {
    _ = system.close(fd);
}

pub const OpenError = error{ FileNotFound, AccessDenied, NoReader, Unexpected };

pub fn open(path: [*:0]const u8, flags: posix.O, mode: posix.mode_t) OpenError!fd_t {
    while (true) {
        const rc = system.open(path, flags, mode);
        return switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR => continue,
            .NOENT => error.FileNotFound,
            .ACCES, .PERM => error.AccessDenied,
            // FIFO opened O_WRONLY|O_NONBLOCK with nobody reading
            .NXIO => error.NoReader,
            else => error.Unexpected,
        };
    }
}

pub fn dup2(old_fd: fd_t, new_fd: fd_t) void {
    while (posix.errno(system.dup2(old_fd, new_fd)) == .INTR) {}
}

pub fn unlink(path: []const u8) void {
    const path_z = posix.toPosixPath(path) catch return;
    _ = system.unlink(&path_z);
}

pub fn isatty(fd: fd_t) bool {
    return std.c.isatty(fd) == 1;
}

/// Environment variable from libc's environment. The PTY child edits that
/// environment with setenv before exec, so rtach reads it from the same place.
pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

/// Wall-clock nanoseconds, for log timestamps (no Io there)
pub fn realtimeNs() i128 {
    var ts: posix.timespec = undefined;
    if (posix.errno(system.clock_gettime(.REALTIME, &ts)) != .SUCCESS) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

// MARK: Unix sockets

pub const SocketError = error{Unexpected};

/// Unix stream socket, optionally non-blocking (the master's listening socket)
pub fn unixSocket(nonblock: bool) SocketError!fd_t {
    const rc = system.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (posix.errno(rc) != .SUCCESS) return error.Unexpected;
    const fd: fd_t = @intCast(rc);
    errdefer close(fd);
    // Via fcntl rather than SOCK_NONBLOCK, which Darwin doesn't have (Zig's
    // SOCK.NONBLOCK there is a shim value the kernel doesn't understand)
    if (nonblock) try setNonblocking(fd);
    return fd;
}

fn setNonblocking(fd: fd_t) SocketError!void {
    const O_int = std.meta.Int(.unsigned, @bitSizeOf(posix.O));
    const nonblock: O_int = @bitCast(posix.O{ .NONBLOCK = true });
    const flags = system.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.Unexpected;
    const new_flags: c_int = flags | @as(c_int, @intCast(nonblock));
    if (posix.errno(system.fcntl(fd, posix.F.SETFL, new_flags)) != .SUCCESS) return error.Unexpected;
}

fn unixAddress(path: []const u8) posix.sockaddr.un {
    var addr = posix.sockaddr.un{ .path = undefined, .family = posix.AF.UNIX };
    const len = @min(path.len, addr.path.len - 1);
    @memcpy(addr.path[0..len], path[0..len]);
    addr.path[len] = 0;
    return addr;
}

pub fn bindAndListen(fd: fd_t, path: []const u8, backlog: u31) error{ AddressInUse, AccessDenied, Unexpected }!void {
    const addr = unixAddress(path);
    switch (posix.errno(system.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        .ACCES, .PERM => return error.AccessDenied,
        else => return error.Unexpected,
    }
    if (posix.errno(system.listen(fd, backlog)) != .SUCCESS) return error.Unexpected;
}

pub fn connect(fd: fd_t, path: []const u8) error{ FileNotFound, ConnectionRefused, AccessDenied, Unexpected }!void {
    const addr = unixAddress(path);
    while (true) {
        return switch (posix.errno(system.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))))) {
            .SUCCESS => {},
            .INTR => continue,
            .NOENT => error.FileNotFound,
            .CONNREFUSED => error.ConnectionRefused,
            .ACCES, .PERM => error.AccessDenied,
            else => error.Unexpected,
        };
    }
}

/// Shut down both directions (a stalled client; its read side then sees EOF)
pub fn shutdown(fd: fd_t) void {
    _ = system.shutdown(fd, posix.SHUT.RDWR);
}

// MARK: Processes

pub fn fork() error{ SystemResources, Unexpected }!pid_t {
    const rc = system.fork();
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .AGAIN, .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

pub fn setsid() void {
    _ = system.setsid();
}

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// Replace the process image, searching PATH, with libc's environment (including
/// anything set with setenv). Only returns on failure.
pub fn execvpZ(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) void {
    _ = execvp(file, argv);
}
