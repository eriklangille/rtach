//! Image inbox: ~/.clauntty/inbox/<id> holds the path of an image `clauntty show`
//! sent to the phone.
//!
//! The live `image;<id>;<path>` command can be lost while Clauntty is in the
//! background (no client attached, or a dead connection rtach hasn't noticed). The app
//! deletes an entry once it has shown the image and checks the inbox whenever it
//! connects, so an image waits on the machine until a phone picks it up.

const std = @import("std");

/// Entries older than this are dropped by the CLI and skipped by the app
pub const max_age_ms: i64 = 6 * std.time.ms_per_hour;

/// Inbox directory for a home directory
pub fn dirPath(home: []const u8, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/.clauntty/inbox", .{home}) catch null;
}

/// Entry ID: `<unix ms>-<pid>-<index>`. Sorts by time and has no `;` or `/`.
pub fn makeId(buf: []u8, now_ms: i64, pid: i32, index: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{d}-{d}-{d}", .{ now_ms, pid, index }) catch unreachable;
}

/// Creation time from an ID, or null if the name isn't one
pub fn idTime(id: []const u8) ?i64 {
    const end = std.mem.indexOfScalar(u8, id, '-') orelse return null;
    return std.fmt.parseInt(i64, id[0..end], 10) catch null;
}

/// Add an entry. Written to a hidden temp file and renamed so the app never reads a
/// partial path.
pub fn add(io: std.Io, dir: []const u8, id: []const u8, image_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir);

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}/.{s}.tmp", .{ dir, id });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const entry_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, id });

    try cwd.writeFile(io, .{ .sub_path = tmp_path, .data = image_path, .flags = .{ .permissions = .fromMode(0o600) } });
    cwd.rename(tmp_path, cwd, entry_path, io) catch |err| {
        cwd.deleteFile(io, tmp_path) catch {};
        return err;
    };
}

/// Delete entries older than `max_age_ms`
pub fn prune(io: std.Io, dir_path: []const u8, now_ms: i64) void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    // Collect first: deleting while iterating can skip entries
    var stale_buf: [64][64]u8 = undefined;
    var stale_lens: [64]usize = undefined;
    var stale_count: usize = 0;

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file or entry.name.len == 0 or entry.name[0] == '.') continue;
        const created = idTime(entry.name) orelse continue;
        if (now_ms - created <= max_age_ms) continue;
        if (entry.name.len > stale_buf[0].len or stale_count == stale_buf.len) continue;
        @memcpy(stale_buf[stale_count][0..entry.name.len], entry.name);
        stale_lens[stale_count] = entry.name.len;
        stale_count += 1;
    }

    for (0..stale_count) |i| dir.deleteFile(io, stale_buf[i][0..stale_lens[i]]) catch {};
}

const testing = std.testing;

test "makeId and idTime" {
    var buf: [64]u8 = undefined;
    const id = makeId(&buf, 1760000000123, 4242, 1);
    try testing.expectEqualStrings("1760000000123-4242-1", id);
    try testing.expectEqual(@as(?i64, 1760000000123), idTime(id));
    try testing.expectEqual(@as(?i64, null), idTime("notes.txt"));
    try testing.expectEqual(@as(?i64, null), idTime("abc-1"));
}

test "add writes the path; prune drops old entries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    var inbox_buf: [std.fs.max_path_bytes]u8 = undefined;
    const inbox = try std.fmt.bufPrint(&inbox_buf, "{s}/inbox", .{base});

    const now: i64 = 1760000000000;
    try add(io, inbox, "1760000000000-1-0", "/tmp/new.png");
    try add(io, inbox, "1750000000000-1-0", "/tmp/old.png");

    var buf: [64]u8 = undefined;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const fresh = try std.fmt.bufPrint(&path_buf, "{s}/1760000000000-1-0", .{inbox});
    try testing.expectEqualStrings("/tmp/new.png", try std.Io.Dir.cwd().readFile(io, fresh, &buf));

    prune(io, inbox, now);

    try testing.expectEqualStrings("/tmp/new.png", try std.Io.Dir.cwd().readFile(io, fresh, &buf));
    const old = try std.fmt.bufPrint(&path_buf, "{s}/1750000000000-1-0", .{inbox});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFile(io, old, &buf));
}
