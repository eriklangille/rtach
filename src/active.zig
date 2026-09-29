//! Active session pointer: ~/.clauntty/active holds the command FIFO path of the
//! session whose Clauntty client most recently claimed active on this machine.
//!
//! The `clauntty` command uses it to reach the phone from shells that rtach didn't
//! start (Herdr, tmux, plain ssh), where $RTACH_CMD_PIPE isn't set.

const std = @import("std");

/// Pointer path for a session socket: sessions live in ~/.clauntty/sessions/<id>, the
/// pointer next to that directory at ~/.clauntty/active. Null for bare socket names.
pub fn pointerPath(socket_path: []const u8, buf: []u8) ?[]const u8 {
    const sessions_dir = std.fs.path.dirname(socket_path) orelse return null;
    const base_dir = std.fs.path.dirname(sessions_dir) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/active", .{base_dir}) catch null;
}

/// Point at `fifo_path`. Written to a temp file and renamed so readers never see
/// a partial path.
pub fn write(io: std.Io, pointer_path: []const u8, fifo_path: []const u8) !void {
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.{d}.tmp", .{ pointer_path, std.c.getpid() });

    var line_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "{s}\n", .{fifo_path});

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp_path, .data = line, .flags = .{ .permissions = .fromMode(0o600) } });
    cwd.rename(tmp_path, cwd, pointer_path, io) catch |err| {
        cwd.deleteFile(io, tmp_path) catch {};
        return err;
    };
}

/// The FIFO path the pointer holds, or null if there is none
pub fn read(io: std.Io, pointer_path: []const u8, buf: []u8) ?[]const u8 {
    const contents = std.Io.Dir.cwd().readFile(io, pointer_path, buf) catch return null;
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

/// Remove the pointer if it still points at `fifo_path` (another session may have
/// claimed it since)
pub fn clearIf(io: std.Io, pointer_path: []const u8, fifo_path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const current = read(io, pointer_path, &buf) orelse return;
    if (!std.mem.eql(u8, current, fifo_path)) return;
    std.Io.Dir.cwd().deleteFile(io, pointer_path) catch {};
}

const testing = std.testing;

test "pointerPath is next to the sessions directory" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/home/u/.clauntty/active", pointerPath("/home/u/.clauntty/sessions/ABC", &buf).?);
    try testing.expectEqualStrings("./active", pointerPath("./sessions/ABC", &buf).?);
    try testing.expect(pointerPath("ABC", &buf) == null);
}

test "write, read and clearIf" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pointer = try std.fmt.bufPrint(&path_buf, "{s}/active", .{dir});

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(read(io, pointer, &buf) == null);

    try write(io, pointer, "/s/A.cmd");
    try testing.expectEqualStrings("/s/A.cmd", read(io, pointer, &buf).?);

    // Another session claimed it: A leaving doesn't clear B's pointer
    try write(io, pointer, "/s/B.cmd");
    clearIf(io, pointer, "/s/A.cmd");
    try testing.expectEqualStrings("/s/B.cmd", read(io, pointer, &buf).?);

    clearIf(io, pointer, "/s/B.cmd");
    try testing.expect(read(io, pointer, &buf) == null);
}
