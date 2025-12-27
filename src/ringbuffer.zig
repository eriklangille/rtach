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

    /// Get a range of data starting at `offset` with length up to `len`.
    /// Offset 0 is the oldest data in the buffer.
    /// Returns up to two slices due to ring buffer wrap-around.
    pub fn sliceRange(
        self: *const DynamicRingBuffer,
        offset: usize,
        len: usize,
    ) struct { first: []const u8, second: []const u8 } {
        if (len == 0 or offset >= self.len) {
            return .{ .first = &.{}, .second = &.{} };
        }

        const actual_len = @min(len, self.len - offset);
        const s = self.slices();

        if (offset < s.first.len) {
            // Start is in first slice
            const first_avail = s.first.len - offset;
            if (actual_len <= first_avail) {
                // Entirely within first slice
                return .{ .first = s.first[offset..][0..actual_len], .second = &.{} };
            } else {
                // Spans both slices
                const second_len = actual_len - first_avail;
                return .{
                    .first = s.first[offset..],
                    .second = s.second[0..second_len],
                };
            }
        } else {
            // Start is in second slice
            const second_offset = offset - s.first.len;
            return .{
                .first = s.second[second_offset..][0..actual_len],
                .second = &.{},
            };
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

test "sliceRange basic" {
    var buf = try DynamicRingBuffer.init(testing.allocator, 100);
    defer buf.deinit();

    buf.write("0123456789"); // 10 bytes

    // Get first 5 bytes
    const r1 = buf.sliceRange(0, 5);
    try testing.expectEqualStrings("01234", r1.first);
    try testing.expectEqual(@as(usize, 0), r1.second.len);

    // Get middle 5 bytes
    const r2 = buf.sliceRange(3, 5);
    try testing.expectEqualStrings("34567", r2.first);
    try testing.expectEqual(@as(usize, 0), r2.second.len);

    // Get last 5 bytes
    const r3 = buf.sliceRange(5, 5);
    try testing.expectEqualStrings("56789", r3.first);
    try testing.expectEqual(@as(usize, 0), r3.second.len);
}

test "sliceRange with wrap-around" {
    var buf = try DynamicRingBuffer.init(testing.allocator, 10);
    defer buf.deinit();

    // Fill buffer and wrap around
    buf.write("ABCDEFGHIJ"); // 10 bytes, fills buffer
    buf.write("12345"); // 5 more bytes, wraps around

    // Buffer now contains: "12345FGHIJ" (oldest) -> "12345" at end
    // Actually: oldest is FGHIJ, newest is 12345
    // Total content in order: FGHIJ12345

    try testing.expectEqual(@as(usize, 10), buf.size());

    // Get first 5 bytes (oldest: FGHIJ)
    const r1 = buf.sliceRange(0, 5);
    var result1: [5]u8 = undefined;
    @memcpy(result1[0..r1.first.len], r1.first);
    @memcpy(result1[r1.first.len..][0..r1.second.len], r1.second);
    try testing.expectEqualStrings("FGHIJ", &result1);

    // Get last 5 bytes (newest: 12345)
    const r2 = buf.sliceRange(5, 5);
    var result2: [5]u8 = undefined;
    @memcpy(result2[0..r2.first.len], r2.first);
    @memcpy(result2[r2.first.len..][0..r2.second.len], r2.second);
    try testing.expectEqualStrings("12345", &result2);

    // Get range spanning wrap point
    const r3 = buf.sliceRange(3, 4);
    var result3: [4]u8 = undefined;
    @memcpy(result3[0..r3.first.len], r3.first);
    @memcpy(result3[r3.first.len..][0..r3.second.len], r3.second);
    try testing.expectEqualStrings("IJ12", &result3);
}

test "sliceRange edge cases" {
    var buf = try DynamicRingBuffer.init(testing.allocator, 10);
    defer buf.deinit();

    buf.write("hello");

    // Empty range
    const r1 = buf.sliceRange(0, 0);
    try testing.expectEqual(@as(usize, 0), r1.first.len);
    try testing.expectEqual(@as(usize, 0), r1.second.len);

    // Offset beyond buffer
    const r2 = buf.sliceRange(100, 5);
    try testing.expectEqual(@as(usize, 0), r2.first.len);
    try testing.expectEqual(@as(usize, 0), r2.second.len);

    // Request more than available (should clamp)
    const r3 = buf.sliceRange(3, 100);
    try testing.expectEqualStrings("lo", r3.first);
    try testing.expectEqual(@as(usize, 0), r3.second.len);

    // Empty buffer
    buf.clear();
    const r4 = buf.sliceRange(0, 5);
    try testing.expectEqual(@as(usize, 0), r4.first.len);
    try testing.expectEqual(@as(usize, 0), r4.second.len);
}
