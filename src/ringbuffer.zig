const std = @import("std");
const testing = std.testing;

/// A ring buffer for storing terminal scrollback data.
/// Efficiently stores the last N bytes of output with O(1) write
/// and supports replaying the entire buffer to new clients.
pub fn RingBuffer(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        data: [capacity]u8 = undefined,
        head: usize = 0, // Next write position
        len: usize = 0, // Total bytes stored (up to capacity)

        /// Write data to the ring buffer.
        /// If data exceeds capacity, only the last `capacity` bytes are kept.
        pub fn write(self: *Self, bytes: []const u8) void {
            if (bytes.len == 0) return;

            if (bytes.len >= capacity) {
                // Data larger than buffer - just keep the last `capacity` bytes
                const start = bytes.len - capacity;
                @memcpy(&self.data, bytes[start..]);
                self.head = 0;
                self.len = capacity;
                return;
            }

            // Write bytes, wrapping around if needed
            const first_chunk = @min(bytes.len, capacity - self.head);
            @memcpy(self.data[self.head..][0..first_chunk], bytes[0..first_chunk]);

            if (first_chunk < bytes.len) {
                // Wrap around
                const second_chunk = bytes.len - first_chunk;
                @memcpy(self.data[0..second_chunk], bytes[first_chunk..]);
                self.head = second_chunk;
            } else {
                self.head = (self.head + bytes.len) % capacity;
            }

            self.len = @min(self.len + bytes.len, capacity);
        }

        /// Get a slice iterator for reading the buffer contents in order.
        /// Returns up to two slices (due to wrap-around).
        pub fn slices(self: *const Self) struct { first: []const u8, second: []const u8 } {
            if (self.len == 0) {
                return .{ .first = &.{}, .second = &.{} };
            }

            if (self.len < capacity) {
                // Buffer not full, data is contiguous from 0 to len
                const start = if (self.head >= self.len) self.head - self.len else capacity - (self.len - self.head);
                if (start + self.len <= capacity) {
                    return .{ .first = self.data[start..][0..self.len], .second = &.{} };
                } else {
                    const first_len = capacity - start;
                    return .{
                        .first = self.data[start..],
                        .second = self.data[0 .. self.len - first_len],
                    };
                }
            }

            // Buffer is full
            // Data starts at head (oldest) and wraps around
            if (self.head == 0) {
                return .{ .first = &self.data, .second = &.{} };
            }
            return .{
                .first = self.data[self.head..],
                .second = self.data[0..self.head],
            };
        }

        /// Get total bytes stored
        pub fn size(self: *const Self) usize {
            return self.len;
        }

        /// Clear the buffer
        pub fn clear(self: *Self) void {
            self.head = 0;
            self.len = 0;
        }

        /// Copy all contents to a writer (for replay)
        pub fn replay(self: *const Self, writer: anytype) !void {
            const s = self.slices();
            if (s.first.len > 0) {
                try writer.writeAll(s.first);
            }
            if (s.second.len > 0) {
                try writer.writeAll(s.second);
            }
        }
    };
}

/// Dynamic ring buffer that can be initialized at runtime with any size
pub const DynamicRingBuffer = struct {
    data: []u8,
    head: usize = 0,
    len: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, cap: usize) !DynamicRingBuffer {
        const data = try allocator.alloc(u8, cap);
        return .{
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DynamicRingBuffer) void {
        self.allocator.free(self.data);
    }

    pub fn capacity(self: *const DynamicRingBuffer) usize {
        return self.data.len;
    }

    pub fn write(self: *DynamicRingBuffer, bytes: []const u8) void {
        if (bytes.len == 0) return;

        const cap = self.data.len;

        if (bytes.len >= cap) {
            // Data larger than buffer - just keep the last `capacity` bytes
            const start = bytes.len - cap;
            @memcpy(self.data, bytes[start..][0..cap]);
            self.head = 0;
            self.len = cap;
            return;
        }

        // Write bytes, wrapping around if needed
        const first_chunk = @min(bytes.len, cap - self.head);
        @memcpy(self.data[self.head..][0..first_chunk], bytes[0..first_chunk]);

        if (first_chunk < bytes.len) {
            // Wrap around
            const second_chunk = bytes.len - first_chunk;
            @memcpy(self.data[0..second_chunk], bytes[first_chunk..]);
            self.head = second_chunk;
        } else {
            self.head = (self.head + bytes.len) % cap;
        }

        self.len = @min(self.len + bytes.len, cap);
    }

    pub fn slices(self: *const DynamicRingBuffer) struct { first: []const u8, second: []const u8 } {
        const cap = self.data.len;

        if (self.len == 0) {
            return .{ .first = &.{}, .second = &.{} };
        }

        if (self.len < cap) {
            const start = if (self.head >= self.len) self.head - self.len else cap - (self.len - self.head);
            if (start + self.len <= cap) {
                return .{ .first = self.data[start..][0..self.len], .second = &.{} };
            } else {
                const first_len = cap - start;
                return .{
                    .first = self.data[start..],
                    .second = self.data[0 .. self.len - first_len],
                };
            }
        }

        // Buffer is full
        if (self.head == 0) {
            return .{ .first = self.data, .second = &.{} };
        }
        return .{
            .first = self.data[self.head..],
            .second = self.data[0..self.head],
        };
    }

    pub fn size(self: *const DynamicRingBuffer) usize {
        return self.len;
    }

    pub fn clear(self: *DynamicRingBuffer) void {
        self.head = 0;
        self.len = 0;
    }

    pub fn replay(self: *const DynamicRingBuffer, writer: anytype) !void {
        const s = self.slices();
        if (s.first.len > 0) {
            try writer.writeAll(s.first);
        }
        if (s.second.len > 0) {
            try writer.writeAll(s.second);
        }
    }
};

// Tests
test "ring buffer basic write and read" {
    var buf = RingBuffer(10){};

    buf.write("hello");
    try testing.expectEqual(@as(usize, 5), buf.size());

    const s = buf.slices();
    try testing.expectEqualStrings("hello", s.first);
    try testing.expectEqualStrings("", s.second);
}

test "ring buffer wrap around" {
    var buf = RingBuffer(10){};

    buf.write("hello"); // 5 bytes
    buf.write("world!"); // 6 bytes, total 11, wraps

    try testing.expectEqual(@as(usize, 10), buf.size());

    const s = buf.slices();
    // Should contain "elloworld!" (last 10 bytes)
    var result: [10]u8 = undefined;
    @memcpy(result[0..s.first.len], s.first);
    @memcpy(result[s.first.len..][0..s.second.len], s.second);
    try testing.expectEqualStrings("elloworld!", &result);
}

test "ring buffer overflow" {
    var buf = RingBuffer(5){};

    buf.write("1234567890"); // 10 bytes into 5 byte buffer

    try testing.expectEqual(@as(usize, 5), buf.size());

    const s = buf.slices();
    try testing.expectEqualStrings("67890", s.first);
}

test "dynamic ring buffer" {
    var buf = try DynamicRingBuffer.init(testing.allocator, 10);
    defer buf.deinit();

    buf.write("hello");
    try testing.expectEqual(@as(usize, 5), buf.size());

    buf.write("world!");
    try testing.expectEqual(@as(usize, 10), buf.size());
}

test "ring buffer replay" {
    var buf = RingBuffer(10){};
    buf.write("test data!");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(testing.allocator);

    try buf.replay(output.writer(testing.allocator));
    try testing.expectEqualStrings("test data!", output.items);
}

// Edge case tests for OOB safety
test "ring buffer empty" {
    const buf = RingBuffer(10){};
    try testing.expectEqual(@as(usize, 0), buf.size());
    const s = buf.slices();
    try testing.expectEqual(@as(usize, 0), s.first.len);
    try testing.expectEqual(@as(usize, 0), s.second.len);
}

test "ring buffer exact capacity" {
    var buf = RingBuffer(10){};
    buf.write("1234567890"); // Exactly 10 bytes
    try testing.expectEqual(@as(usize, 10), buf.size());

    const s = buf.slices();
    var result: [10]u8 = undefined;
    @memcpy(result[0..s.first.len], s.first);
    @memcpy(result[s.first.len..][0..s.second.len], s.second);
    try testing.expectEqualStrings("1234567890", &result);
}

test "ring buffer single byte writes" {
    var buf = RingBuffer(5){};
    buf.write("a");
    buf.write("b");
    buf.write("c");
    buf.write("d");
    buf.write("e");
    buf.write("f"); // Should wrap, push out 'a'

    try testing.expectEqual(@as(usize, 5), buf.size());

    const s = buf.slices();
    var result: [5]u8 = undefined;
    @memcpy(result[0..s.first.len], s.first);
    @memcpy(result[s.first.len..][0..s.second.len], s.second);
    try testing.expectEqualStrings("bcdef", &result);
}

test "ring buffer massive overflow" {
    var buf = RingBuffer(5){};
    // Write way more than capacity
    buf.write("this is a very long string that exceeds capacity by a lot");

    try testing.expectEqual(@as(usize, 5), buf.size());

    const s = buf.slices();
    // Should contain last 5 bytes: "a lot"
    var result: [5]u8 = undefined;
    @memcpy(result[0..s.first.len], s.first);
    @memcpy(result[s.first.len..][0..s.second.len], s.second);
    try testing.expectEqualStrings("a lot", &result);
}

test "ring buffer clear and reuse" {
    var buf = RingBuffer(10){};
    buf.write("hello");
    buf.clear();
    try testing.expectEqual(@as(usize, 0), buf.size());

    buf.write("world");
    try testing.expectEqual(@as(usize, 5), buf.size());
    const s = buf.slices();
    try testing.expectEqualStrings("world", s.first);
}

test "dynamic ring buffer edge cases" {
    var buf = try DynamicRingBuffer.init(testing.allocator, 8);
    defer buf.deinit();

    // Empty state
    try testing.expectEqual(@as(usize, 0), buf.size());

    // Fill exactly
    buf.write("12345678");
    try testing.expectEqual(@as(usize, 8), buf.size());

    // Overflow by 1
    buf.write("9");
    try testing.expectEqual(@as(usize, 8), buf.size());

    const s = buf.slices();
    var result: [8]u8 = undefined;
    @memcpy(result[0..s.first.len], s.first);
    @memcpy(result[s.first.len..][0..s.second.len], s.second);
    try testing.expectEqualStrings("23456789", &result);
}

test "dynamic ring buffer zero-length write" {
    var buf = try DynamicRingBuffer.init(testing.allocator, 8);
    defer buf.deinit();

    buf.write("");
    try testing.expectEqual(@as(usize, 0), buf.size());

    buf.write("test");
    buf.write("");
    try testing.expectEqual(@as(usize, 4), buf.size());
}
