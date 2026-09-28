const std = @import("std");
const testing = std.testing;

/// Pages of stored output for a client's scrollback history (request_history).
///
/// Positions are absolute stream positions: bytes written since the session started,
/// the same counter as scrollback_total_written. Unlike offsets into the ring buffer,
/// they don't shift when old output is evicted.
///
/// Pages end where the previous one (or the attach replay) started and begin at a line
/// start, so a page never cuts a line in two. Output written while a full-screen app was
/// on the alternate screen (Claude Code, vim) is left out: replayed as history it's
/// just a pile of redraws.

/// Stored output: the ring buffer's two slices, oldest first, and the absolute
/// position of their first byte.
pub const Stored = struct {
    first: []const u8,
    second: []const u8,
    oldest: u64,

    pub fn len(self: Stored) usize {
        return self.first.len + self.second.len;
    }

    pub fn end(self: Stored) u64 {
        return self.oldest + self.len();
    }

    fn at(self: Stored, pos: u64) u8 {
        const i: usize = @intCast(pos - self.oldest);
        return if (i < self.first.len) self.first[i] else self.second[i - self.first.len];
    }
};

pub const Range = struct { start: u64, end: u64 };

/// How far back to look for the start of the line a page would begin in
const max_line_search = 4096;

/// The page of at most about `limit` bytes that ends at `before`, extended back to the
/// start of its first line. Empty (start == end) only when nothing is stored before it.
pub fn selectPage(stored: Stored, before: u64, limit: u32) Range {
    const end = @min(before, stored.end());
    if (end <= stored.oldest) return .{ .start = stored.oldest, .end = stored.oldest };

    var start = if (end - stored.oldest > limit) end - limit else stored.oldest;
    start = lineStart(stored, start);
    return .{ .start = start, .end = end };
}

/// Position just after the last newline before `pos` (at most max_line_search back),
/// or `pos` itself if that's already a line start or no newline is near enough
pub fn lineStart(stored: Stored, pos: u64) u64 {
    if (pos <= stored.oldest) return stored.oldest;
    if (stored.at(pos - 1) == '\n') return pos;
    const floor = if (pos - stored.oldest > max_line_search) pos - max_line_search else stored.oldest;
    var p = pos - 1;
    while (p > floor) : (p -= 1) {
        if (stored.at(p - 1) == '\n') return p;
    }
    return if (floor == stored.oldest) stored.oldest else pos;
}

/// Position just after the first newline at or after `pos` (at most max_line_search
/// ahead), or `pos` if none. Used to start the attach replay at a line start.
pub fn nextLineStart(stored: Stored, pos: u64) u64 {
    const limit = @min(stored.end(), pos + max_line_search);
    var p = pos;
    while (p < limit) : (p += 1) {
        if (stored.at(p) == '\n') return p + 1;
    }
    return pos;
}

/// Append the bytes of `range` to `out`, leaving out alternate-screen output. The
/// screen mode at range.start is found by scanning from the oldest stored byte, which is
/// assumed to be on the normal screen.
pub fn appendWithoutAltScreen(
    alloc: std.mem.Allocator,
    stored: Stored,
    range: Range,
    out: *std.ArrayList(u8),
) !void {
    var tracker: AltTracker = .{};
    var pos = stored.oldest;
    while (pos < range.start) : (pos += 1) _ = tracker.feed(stored.at(pos));

    // A sequence split across range.start belongs to the previous page
    tracker.pending_len = 0;
    tracker.state = .ground;

    while (pos < range.end) : (pos += 1) {
        const r = tracker.feed(stored.at(pos));
        if (r.flushed.len > 0) try out.appendSlice(alloc, r.flushed);
        if (r.byte) |b| try out.append(alloc, b);
    }
    // Keep an unfinished trailing sequence (normal screen) as it was
    if (!tracker.alt and tracker.pending_len > 0) {
        try out.appendSlice(alloc, tracker.pending[0..tracker.pending_len]);
    }
}

/// Follows ESC [ ? Pm h/l for modes 1049, 1047 and 47. On the normal screen, bytes pass
/// through; a private-mode CSI is held until complete so the switches themselves can be
/// dropped.
const AltTracker = struct {
    alt: bool = false,
    state: enum { ground, esc, csi, csi_private } = .ground,
    pending: [32]u8 = undefined,
    pending_len: usize = 0,
    flush_buf: [33]u8 = undefined,

    const Result = struct { flushed: []const u8 = &.{}, byte: ?u8 = null };

    fn feed(self: *AltTracker, b: u8) Result {
        switch (self.state) {
            .ground => {
                if (b == 0x1b) {
                    self.hold(b);
                    self.state = .esc;
                    return .{};
                }
                return .{ .byte = self.pass(b) };
            },
            .esc => {
                if (b == '[') {
                    self.hold(b);
                    self.state = .csi;
                    return .{};
                }
                return self.release(b);
            },
            .csi => {
                if (b == '?') {
                    self.hold(b);
                    self.state = .csi_private;
                    return .{};
                }
                return self.release(b);
            },
            .csi_private => {
                if ((b >= '0' and b <= '9') or b == ';') {
                    if (self.pending_len < self.pending.len) {
                        self.hold(b);
                        return .{};
                    }
                    return self.release(b);
                }
                if (b == 'h' or b == 'l') {
                    if (self.switchesAltScreen()) {
                        self.alt = b == 'h';
                        self.pending_len = 0;
                        self.state = .ground;
                        return .{};
                    }
                }
                return self.release(b);
            },
        }
    }

    fn hold(self: *AltTracker, b: u8) void {
        self.pending[self.pending_len] = b;
        self.pending_len += 1;
    }

    fn pass(self: *AltTracker, b: u8) ?u8 {
        return if (self.alt) null else b;
    }

    /// Not an alt-screen switch: emit what was held plus `b` (normal screen only)
    fn release(self: *AltTracker, b: u8) Result {
        const n = self.pending_len;
        self.pending_len = 0;
        self.state = .ground;
        if (self.alt) return .{};
        @memcpy(self.flush_buf[0..n], self.pending[0..n]);
        self.flush_buf[n] = b;
        return .{ .flushed = self.flush_buf[0 .. n + 1] };
    }

    fn switchesAltScreen(self: *const AltTracker) bool {
        // pending: ESC [ ? params
        var it = std.mem.splitScalar(u8, self.pending[3..self.pending_len], ';');
        while (it.next()) |p| {
            if (std.mem.eql(u8, p, "1049") or std.mem.eql(u8, p, "1047") or std.mem.eql(u8, p, "47")) return true;
        }
        return false;
    }
};

fn storedOf(data: []const u8, split: usize, oldest: u64) Stored {
    return .{ .first = data[0..split], .second = data[split..], .oldest = oldest };
}

fn pageText(alloc: std.mem.Allocator, stored: Stored, range: Range) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendWithoutAltScreen(alloc, stored, range, &out);
    return out.toOwnedSlice(alloc);
}

test "pages walk backwards and start at line starts" {
    const data = "one\ntwo\nthree\nfour\nfive\n";
    const s = storedOf(data, 7, 100); // ring wrapped mid-buffer, oldest at 100
    // Page before the end, limit cuts into "three"
    var r = selectPage(s, s.end(), 12);
    try testing.expectEqual(@as(u64, 108), r.start); // "three\n..." starts at 100+8
    try testing.expectEqual(s.end(), r.end);
    // Next page ends where that one started
    r = selectPage(s, r.start, 4);
    try testing.expectEqual(@as(u64, 104), r.start); // "two\n"
    try testing.expectEqual(@as(u64, 108), r.end);
    // A limit that starts mid-line takes the whole line: 2 bytes back from 104 is
    // inside "one\n", which starts at the oldest byte
    r = selectPage(s, r.start, 2);
    try testing.expectEqual(@as(u64, 100), r.start);
    // Nothing before the oldest byte
    r = selectPage(s, r.start, 5);
    try testing.expectEqual(r.start, r.end);
}

test "a page is never empty while there is older output" {
    // One long line: no newline to align to within the page
    const data = "x" ** 50 ++ "\n";
    const s = storedOf(data, data.len, 0);
    const r = selectPage(s, 40, 10);
    try testing.expect(r.end > r.start);
}

test "attach replay starts at the next line" {
    const data = "aaaa\nbbbb\ncccc\n";
    const s = storedOf(data, 3, 0);
    try testing.expectEqual(@as(u64, 5), nextLineStart(s, 2));
    try testing.expectEqual(@as(u64, 5), nextLineStart(s, 5 - 1));
}

test "alternate screen output is left out" {
    const alloc = testing.allocator;
    const data = "before\n\x1b[?1049hTUI FRAME\x1b[2J\x1b[?1049lafter\n";
    const s = storedOf(data, 10, 0);
    const text = try pageText(alloc, s, .{ .start = 0, .end = s.end() });
    defer alloc.free(text);
    try testing.expectEqualStrings("before\nafter\n", text);
}

test "a page starting inside alternate screen output skips to its end" {
    const alloc = testing.allocator;
    const data = "shell\n\x1b[?1049hframe 1\nframe 2\n\x1b[?1049lprompt\n";
    const s = storedOf(data, data.len, 0);
    const start = 6 + 8 + 8; // inside the TUI output, after "frame 1\n"
    const text = try pageText(alloc, s, .{ .start = start, .end = s.end() });
    defer alloc.free(text);
    try testing.expectEqualStrings("prompt\n", text);
}

test "other private modes and CSI sequences pass through" {
    const alloc = testing.allocator;
    const data = "\x1b[?25l\x1b[?2004hhi\x1b[1;31mred\x1b[0m\x1b[?1049;25h";
    const s = storedOf(data, data.len, 0);
    const text = try pageText(alloc, s, .{ .start = 0, .end = s.end() });
    defer alloc.free(text);
    try testing.expectEqualStrings("\x1b[?25l\x1b[?2004hhi\x1b[1;31mred\x1b[0m", text);
}
