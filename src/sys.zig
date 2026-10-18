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

pub fn read(fd: fd_t, buf: []u8) error{Unexpected}!usize {
    while (true) {
        const rc = system.read(fd, buf.ptr, buf.len);
        return switch (posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .INTR => continue,
            else => error.Unexpected,
        };
    }
}

/// A pipe whose ends close on exec
pub fn pipe() error{Unexpected}![2]fd_t {
    var fds: [2]fd_t = undefined;
    if (posix.errno(std.c.pipe(&fds)) != .SUCCESS) return error.Unexpected;
    for (fds) |fd| _ = system.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
    return fds;
}

/// Open a lock file, creating it if needed, and wait for an exclusive lock on it.
/// The lock lasts until every copy of the fd is closed. A forked child closes its
/// copy rather than unlocking, which would release the parent's lock too.
pub fn lockFile(path: []const u8) error{Unexpected}!fd_t {
    const path_z = posix.toPosixPath(path) catch return error.Unexpected;
    const fd = open(&path_z, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600) catch return error.Unexpected;
    while (true) {
        switch (posix.errno(std.c.flock(fd, posix.LOCK.EX))) {
            .SUCCESS => return fd,
            .INTR => continue,
            else => {
                close(fd);
                return error.Unexpected;
            },
        }
    }
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

/// Done sending: the peer's reads see EOF, and it can still reply
pub fn shutdownWrite(fd: fd_t) void {
    _ = system.shutdown(fd, posix.SHUT.WR);
}

pub fn accept(fd: fd_t) error{Unexpected}!fd_t {
    while (true) {
        const rc = system.accept(fd, null, null);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR, .CONNABORTED => continue,
            else => return error.Unexpected,
        }
    }
}

/// Wait up to `timeout_ms` (-1: forever) for `fd` to be readable. False on timeout.
pub fn waitReadable(fd: fd_t, timeout_ms: i32) bool {
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    while (true) {
        const rc = system.poll(&fds, 1, timeout_ms);
        switch (posix.errno(rc)) {
            .SUCCESS => return rc > 0,
            .INTR => continue,
            else => return false,
        }
    }
}

/// Reads on `fd` fail after `seconds` without data
pub fn setRecvTimeout(fd: fd_t, seconds: i64) void {
    const tv = posix.timeval{ .sec = @intCast(seconds), .usec = 0 };
    _ = system.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(posix.timeval));
}

pub fn setCloexec(fd: fd_t) void {
    _ = system.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
}

/// Keep `fd` open across exec
pub fn clearCloexec(fd: fd_t) void {
    _ = system.fcntl(fd, posix.F.SETFD, @as(c_int, 0));
}

pub fn isOpen(fd: fd_t) bool {
    return posix.errno(system.fcntl(fd, posix.F.GETFD, @as(c_int, 0))) == .SUCCESS;
}

/// The pid of the process on the other end of a Unix socket
pub fn peerPid(fd: fd_t) ?pid_t {
    switch (@import("builtin").os.tag) {
        .macos => {
            // SOL_LOCAL, LOCAL_PEERPID (sys/un.h)
            var pid: pid_t = 0;
            var len: posix.socklen_t = @sizeOf(pid_t);
            if (std.c.getsockopt(fd, 0, 0x002, @ptrCast(&pid), &len) != 0) return null;
            return pid;
        },
        .linux => {
            const Ucred = extern struct { pid: pid_t, uid: u32, gid: u32 };
            var cred: Ucred = undefined;
            var len: posix.socklen_t = @sizeOf(Ucred);
            if (std.c.getsockopt(fd, posix.SOL.SOCKET, posix.SO.PEERCRED, @ptrCast(&cred), &len) != 0) return null;
            return cred.pid;
        },
        else => return null,
    }
}

extern "c" fn getpeereid(fd: fd_t, uid: *posix.uid_t, gid: *posix.gid_t) c_int;

/// The uid of the process on the other end of a Unix socket (BSD and macOS)
pub fn peerUid(fd: fd_t) ?posix.uid_t {
    var uid: posix.uid_t = undefined;
    var gid: posix.gid_t = undefined;
    if (getpeereid(fd, &uid, &gid) != 0) return null;
    return uid;
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

/// Wait for a child; its exit code, or null if it was killed by a signal
pub fn waitExitCode(pid: pid_t) ?u8 {
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(pid, &status, 0);
        if (rc == -1 and posix.errno(rc) == .INTR) continue;
        if (rc == -1) return null;
        break;
    }
    const s: u32 = @bitCast(status);
    return if (posix.W.IFEXITED(s)) posix.W.EXITSTATUS(s) else null;
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

/// Replace the process image with exactly this environment. Only returns on failure.
pub fn execveZ(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) void {
    _ = std.c.execve(path, argv, envp);
}
