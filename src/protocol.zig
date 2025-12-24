const std = @import("std");
const testing = std.testing;

/// Message types for client-master protocol.
/// Compatible with dtach's protocol.
pub const MessageType = enum(u8) {
    /// Data from client to PTY
    push = 0,
    /// Client attach request
    attach = 1,
    /// Client detach notification
    detach = 2,
    /// Window size change
    winch = 3,
    /// Request screen redraw
    redraw = 4,
};

/// Packet header - compatible with dtach
pub const PacketHeader = extern struct {
    type: MessageType,
    len: u8,
};

/// Window size packet payload
pub const Winsize = extern struct {
    rows: u16,
    cols: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

/// Maximum payload size (fits in u8 len field)
pub const MAX_PAYLOAD_SIZE = 255;

/// Full packet structure
pub const Packet = struct {
    header: PacketHeader,
    payload: [MAX_PAYLOAD_SIZE]u8 = undefined,

    pub fn init(msg_type: MessageType, data: []const u8) Packet {
        var pkt = Packet{
            .header = .{
                .type = msg_type,
                .len = @intCast(@min(data.len, MAX_PAYLOAD_SIZE)),
            },
        };
        if (data.len > 0) {
            @memcpy(pkt.payload[0..pkt.header.len], data[0..pkt.header.len]);
        }
        return pkt;
    }

    pub fn initWinch(ws: Winsize) Packet {
        var pkt = Packet{
            .header = .{
                .type = .winch,
                .len = @sizeOf(Winsize),
            },
        };
        const ws_bytes = std.mem.asBytes(&ws);
        @memcpy(pkt.payload[0..@sizeOf(Winsize)], ws_bytes);
        return pkt;
    }

    pub fn initAttach() Packet {
        return .{
            .header = .{
                .type = .attach,
                .len = 0,
            },
        };
    }

    pub fn initDetach() Packet {
        return .{
            .header = .{
                .type = .detach,
                .len = 0,
            },
        };
    }

    pub fn initRedraw() Packet {
        return .{
            .header = .{
                .type = .redraw,
                .len = 0,
            },
        };
    }

    pub fn getPayload(self: *const Packet) []const u8 {
        return self.payload[0..self.header.len];
    }

    pub fn getWinsize(self: *const Packet) ?Winsize {
        if (self.header.type != .winch or self.header.len < @sizeOf(Winsize)) {
            return null;
        }
        return std.mem.bytesAsValue(Winsize, self.payload[0..@sizeOf(Winsize)]).*;
    }

    /// Serialize packet for transmission
    pub fn serialize(self: *const Packet) []const u8 {
        const total_len = @sizeOf(PacketHeader) + self.header.len;
        const self_bytes: [*]const u8 = @ptrCast(self);
        return self_bytes[0..total_len];
    }

    /// Get bytes needed to read based on header
    pub fn payloadSize(header: PacketHeader) usize {
        return header.len;
    }
};

/// Packet reader state machine for reading from stream
pub const PacketReader = struct {
    state: State = .read_header,
    header: PacketHeader = undefined,
    payload: [MAX_PAYLOAD_SIZE]u8 = undefined,
    payload_read: usize = 0,

    const State = enum {
        read_header,
        read_payload,
        complete,
    };

    /// Feed bytes to the reader. Returns number of bytes consumed and parsed packet if complete.
    pub fn feed(self: *PacketReader, data: []const u8) struct { consumed: usize, packet: ?Packet } {
        var total_consumed: usize = 0;
        var remaining_data = data;

        // Process as much as possible in one call
        while (remaining_data.len > 0) {
            switch (self.state) {
                .read_header => {
                    if (remaining_data.len < @sizeOf(PacketHeader)) {
                        break; // Need more data
                    }
                    self.header = std.mem.bytesAsValue(PacketHeader, remaining_data[0..@sizeOf(PacketHeader)]).*;
                    total_consumed += @sizeOf(PacketHeader);
                    remaining_data = remaining_data[@sizeOf(PacketHeader)..];

                    if (self.header.len == 0) {
                        self.state = .complete;
                    } else {
                        self.state = .read_payload;
                        self.payload_read = 0;
                    }
                },
                .read_payload => {
                    const remaining = self.header.len - self.payload_read;
                    const to_read = @min(remaining, remaining_data.len);
                    @memcpy(self.payload[self.payload_read..][0..to_read], remaining_data[0..to_read]);
                    self.payload_read += to_read;
                    total_consumed += to_read;
                    remaining_data = remaining_data[to_read..];

                    if (self.payload_read >= self.header.len) {
                        self.state = .complete;
                    }
                },
                .complete => break,
            }
        }

        if (self.state == .complete) {
            var pkt = Packet{
                .header = self.header,
            };
            @memcpy(pkt.payload[0..self.header.len], self.payload[0..self.header.len]);
            self.reset();
            return .{ .consumed = total_consumed, .packet = pkt };
        }

        return .{ .consumed = total_consumed, .packet = null };
    }

    pub fn reset(self: *PacketReader) void {
        self.state = .read_header;
        self.payload_read = 0;
    }
};

// Tests
test "packet creation and serialization" {
    const pkt = Packet.init(.push, "hello");
    try testing.expectEqual(MessageType.push, pkt.header.type);
    try testing.expectEqual(@as(u8, 5), pkt.header.len);
    try testing.expectEqualStrings("hello", pkt.getPayload());
}

test "winch packet" {
    const ws = Winsize{ .rows = 24, .cols = 80 };
    const pkt = Packet.initWinch(ws);
    try testing.expectEqual(MessageType.winch, pkt.header.type);

    const got_ws = pkt.getWinsize().?;
    try testing.expectEqual(@as(u16, 24), got_ws.rows);
    try testing.expectEqual(@as(u16, 80), got_ws.cols);
}

test "packet reader" {
    var reader = PacketReader{};

    // Simulate receiving header + payload
    const pkt = Packet.init(.push, "test");
    const data = pkt.serialize();

    const result = reader.feed(data);
    try testing.expect(result.packet != null);
    try testing.expectEqualStrings("test", result.packet.?.getPayload());
}
