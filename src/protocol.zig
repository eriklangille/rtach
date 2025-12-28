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
    /// Request old scrollback (everything before the initial 16KB) - LEGACY
    request_scrollback = 5,
    /// Request a page of scrollback (paginated, with offset and limit)
    request_scrollback_page = 6,
    /// Upgrade to framed protocol mode (client signals it will frame all input)
    upgrade = 7,
    /// Pause terminal output streaming (client will buffer locally)
    pause = 8,
    /// Resume terminal output streaming (flush buffer and continue)
    @"resume" = 9,
};

/// Response types for master → client protocol.
/// ALL data from rtach to client is framed: [type: 1][len: 4][payload]
pub const ResponseType = enum(u8) {
    /// Terminal data (PTY output) - forward to terminal display
    terminal_data = 0,
    /// Old scrollback data (prepend to current screen) - LEGACY
    scrollback = 1,
    /// Command from server-side scripts (e.g., "open;3000" to open web tab)
    command = 2,
    /// Paginated scrollback data with metadata (total size, offset)
    scrollback_page = 3,
    /// Shell is idle/waiting for input (sent after 2s of no PTY output)
    idle = 4,
    /// Protocol handshake (sent immediately after attach)
    handshake = 255,
};

/// Response header size (type: 1 byte + len: 4 bytes)
pub const RESPONSE_HEADER_SIZE: usize = 5;

/// Handshake payload size (magic: 4 + version_major: 1 + version_minor: 1 + flags: 2)
pub const HANDSHAKE_SIZE: usize = 8;

/// Request payload for request_scrollback_page
/// Wire format: exactly 8 bytes
pub const ScrollbackPageRequest = packed struct {
    /// Byte offset from START of scrollback (0 = oldest data)
    offset: u32,
    /// Maximum bytes to return in this page
    limit: u32,

    pub const WIRE_SIZE = 8;

    pub fn fromBytes(bytes: *const [WIRE_SIZE]u8) ScrollbackPageRequest {
        return @bitCast(bytes.*);
    }
};

/// Response metadata for scrollback_page (sent after header, before data)
/// Wire format: exactly 8 bytes
pub const ScrollbackPageMeta = packed struct {
    /// Total scrollback size available
    total_len: u32,
    /// Byte offset this chunk starts at
    offset: u32,

    pub const WIRE_SIZE = 8;

    pub fn toBytes(self: *const ScrollbackPageMeta) *const [WIRE_SIZE]u8 {
        return @ptrCast(self);
    }
};

/// Handshake sent immediately after client attaches
/// Identifies rtach protocol and version for compatibility checking
/// Wire format: exactly 8 bytes
pub const Handshake = packed struct {
    /// Magic bytes "RTCH" (0x48435452 in little-endian)
    magic: u32 = 0x48435452,
    /// Protocol version major (2 for framed protocol)
    version_major: u8 = 2,
    /// Protocol version minor
    version_minor: u8 = 0,
    /// Reserved for future flags
    flags: u16 = 0,

    pub const WIRE_SIZE = 8;
    pub const MAGIC: u32 = 0x48435452; // "RTCH"

    pub fn toBytes(self: *const Handshake) *const [WIRE_SIZE]u8 {
        return @ptrCast(self);
    }

    /// Parse handshake from wire bytes
    pub fn parse(bytes: []const u8) ?Handshake {
        if (bytes.len < WIRE_SIZE) return null;
        const ptr: *const [WIRE_SIZE]u8 = @ptrCast(bytes.ptr);
        return std.mem.bytesAsValue(Handshake, ptr).*;
    }

    /// Check if handshake has valid magic
    pub fn isValid(self: *const Handshake) bool {
        return self.magic == MAGIC;
    }
};

/// Response header for framed master → client messages
/// Use packed to ensure no padding between type (1 byte) and len (4 bytes)
/// Wire format: exactly 5 bytes
pub const ResponseHeader = packed struct {
    type: ResponseType,
    len: u32, // Length of following data (up to 4GB)

    /// Wire format size (use this instead of @sizeOf which includes alignment padding)
    pub const WIRE_SIZE = 5;

    /// Get bytes for wire transmission (exactly 5 bytes)
    pub fn toBytes(self: *const ResponseHeader) *const [WIRE_SIZE]u8 {
        return @ptrCast(self);
    }
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

/// Client ID size (UUID = 16 bytes)
pub const CLIENT_ID_SIZE = 16;

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

    pub fn initAttach(client_id: ?*const [CLIENT_ID_SIZE]u8) Packet {
        var pkt = Packet{
            .header = .{
                .type = .attach,
                .len = if (client_id != null) CLIENT_ID_SIZE else 0,
            },
        };
        if (client_id) |id| {
            @memcpy(pkt.payload[0..CLIENT_ID_SIZE], id);
        }
        return pkt;
    }

    /// Get client ID from attach packet payload (returns null if no client ID)
    pub fn getClientId(self: *const Packet) ?[CLIENT_ID_SIZE]u8 {
        if (self.header.type != .attach or self.header.len < CLIENT_ID_SIZE) {
            return null;
        }
        return self.payload[0..CLIENT_ID_SIZE].*;
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

    pub fn initUpgrade() Packet {
        return .{
            .header = .{
                .type = .upgrade,
                .len = 0,
            },
        };
    }

    pub fn initPause() Packet {
        return .{
            .header = .{
                .type = .pause,
                .len = 0,
            },
        };
    }

    pub fn initResume() Packet {
        return .{
            .header = .{
                .type = .@"resume",
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

// Edge case tests for OOB safety
test "packet with max payload size" {
    var data: [MAX_PAYLOAD_SIZE]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i % 256);

    const pkt = Packet.init(.push, &data);
    try testing.expectEqual(@as(u8, MAX_PAYLOAD_SIZE), pkt.header.len);
    try testing.expectEqual(@as(usize, MAX_PAYLOAD_SIZE), pkt.getPayload().len);
}

test "packet with data larger than max truncates" {
    var data: [MAX_PAYLOAD_SIZE + 100]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i % 256);

    const pkt = Packet.init(.push, &data);
    // Should truncate to MAX_PAYLOAD_SIZE
    try testing.expectEqual(@as(u8, MAX_PAYLOAD_SIZE), pkt.header.len);
}

test "packet reader partial header" {
    var reader = PacketReader{};

    // Feed only 1 byte of header (need 2)
    const partial: [1]u8 = .{@intFromEnum(MessageType.push)};
    const result = reader.feed(&partial);
    try testing.expectEqual(@as(usize, 0), result.consumed);
    try testing.expect(result.packet == null);
}

test "packet reader partial payload" {
    var reader = PacketReader{};

    // Create packet with 10 byte payload
    const pkt = Packet.init(.push, "0123456789");
    const full_data = pkt.serialize();

    // Feed header + partial payload (only 5 of 10 bytes)
    const partial = full_data[0..7]; // 2 header + 5 payload
    const result1 = reader.feed(partial);
    try testing.expectEqual(@as(usize, 7), result1.consumed);
    try testing.expect(result1.packet == null);

    // Feed remaining
    const result2 = reader.feed(full_data[7..]);
    try testing.expectEqual(@as(usize, 5), result2.consumed);
    try testing.expect(result2.packet != null);
    try testing.expectEqualStrings("0123456789", result2.packet.?.getPayload());
}

test "packet reader multiple packets in one feed" {
    var reader = PacketReader{};

    const pkt1 = Packet.init(.push, "abc");
    const pkt2 = Packet.init(.push, "xyz");

    // Concatenate two packets
    var combined: [20]u8 = undefined;
    const data1 = pkt1.serialize();
    const data2 = pkt2.serialize();
    @memcpy(combined[0..data1.len], data1);
    @memcpy(combined[data1.len..][0..data2.len], data2);

    // First feed should get first packet
    const result1 = reader.feed(combined[0 .. data1.len + data2.len]);
    try testing.expect(result1.packet != null);
    try testing.expectEqualStrings("abc", result1.packet.?.getPayload());

    // Feed remaining should get second packet
    const result2 = reader.feed(combined[result1.consumed .. data1.len + data2.len]);
    try testing.expect(result2.packet != null);
    try testing.expectEqualStrings("xyz", result2.packet.?.getPayload());
}

test "getClientId with short payload" {
    var pkt = Packet{
        .header = .{ .type = .attach, .len = 5 }, // Too short for client ID
    };
    try testing.expect(pkt.getClientId() == null);
}

test "getWinsize with short payload" {
    var pkt = Packet{
        .header = .{ .type = .winch, .len = 2 }, // Too short for Winsize
    };
    try testing.expect(pkt.getWinsize() == null);
}

test "ResponseType command value" {
    try testing.expectEqual(@as(u8, 2), @intFromEnum(ResponseType.command));
}

test "ResponseType scrollback value" {
    try testing.expectEqual(@as(u8, 1), @intFromEnum(ResponseType.scrollback));
}

test "ResponseHeader wire size is 5 bytes" {
    try testing.expectEqual(@as(usize, 5), ResponseHeader.WIRE_SIZE);
}

test "ResponseHeader toBytes returns correct wire format" {
    const header = ResponseHeader{
        .type = .command,
        .len = 12,
    };
    const bytes = header.toBytes();
    try testing.expectEqual(@as(usize, 5), bytes.len);
    try testing.expectEqual(@as(u8, 2), bytes[0]); // type = command
    // Length is little-endian: 12 = 0x0C
    try testing.expectEqual(@as(u8, 12), bytes[1]);
    try testing.expectEqual(@as(u8, 0), bytes[2]);
    try testing.expectEqual(@as(u8, 0), bytes[3]);
    try testing.expectEqual(@as(u8, 0), bytes[4]);
}

test "ResponseHeader scrollback toBytes" {
    const header = ResponseHeader{
        .type = .scrollback,
        .len = 0x12345678,
    };
    const bytes = header.toBytes();
    try testing.expectEqual(@as(u8, 1), bytes[0]); // type = scrollback
    // Length is little-endian: 0x12345678
    try testing.expectEqual(@as(u8, 0x78), bytes[1]);
    try testing.expectEqual(@as(u8, 0x56), bytes[2]);
    try testing.expectEqual(@as(u8, 0x34), bytes[3]);
    try testing.expectEqual(@as(u8, 0x12), bytes[4]);
}

test "ScrollbackPageRequest wire size and parsing" {
    try testing.expectEqual(@as(usize, 8), ScrollbackPageRequest.WIRE_SIZE);

    // Test parsing from bytes (little-endian)
    const bytes = [8]u8{
        0x00, 0x40, 0x00, 0x00, // offset = 16384 (0x4000)
        0x00, 0x40, 0x00, 0x00, // limit = 16384 (0x4000)
    };
    const req = ScrollbackPageRequest.fromBytes(&bytes);
    try testing.expectEqual(@as(u32, 16384), req.offset);
    try testing.expectEqual(@as(u32, 16384), req.limit);
}

test "ScrollbackPageMeta wire size and serialization" {
    try testing.expectEqual(@as(usize, 8), ScrollbackPageMeta.WIRE_SIZE);

    const meta = ScrollbackPageMeta{
        .total_len = 1048576, // 1MB = 0x100000
        .offset = 16384, // 16KB = 0x4000
    };
    const bytes = meta.toBytes();
    try testing.expectEqual(@as(usize, 8), bytes.len);
    // total_len little-endian: 0x00100000
    try testing.expectEqual(@as(u8, 0x00), bytes[0]);
    try testing.expectEqual(@as(u8, 0x00), bytes[1]);
    try testing.expectEqual(@as(u8, 0x10), bytes[2]);
    try testing.expectEqual(@as(u8, 0x00), bytes[3]);
    // offset little-endian: 0x00004000
    try testing.expectEqual(@as(u8, 0x00), bytes[4]);
    try testing.expectEqual(@as(u8, 0x40), bytes[5]);
    try testing.expectEqual(@as(u8, 0x00), bytes[6]);
    try testing.expectEqual(@as(u8, 0x00), bytes[7]);
}

test "ResponseType scrollback_page value" {
    try testing.expectEqual(@as(u8, 3), @intFromEnum(ResponseType.scrollback_page));
}

test "MessageType request_scrollback_page value" {
    try testing.expectEqual(@as(u8, 6), @intFromEnum(MessageType.request_scrollback_page));
}

test "ResponseType terminal_data value" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(ResponseType.terminal_data));
}

test "ResponseType handshake value" {
    try testing.expectEqual(@as(u8, 255), @intFromEnum(ResponseType.handshake));
}

test "Handshake wire size and serialization" {
    try testing.expectEqual(@as(usize, 8), Handshake.WIRE_SIZE);

    const handshake = Handshake{};
    const bytes = handshake.toBytes();
    try testing.expectEqual(@as(usize, 8), bytes.len);
    // Magic "RTCH" in little-endian: 0x48435452
    try testing.expectEqual(@as(u8, 0x52), bytes[0]); // 'R'
    try testing.expectEqual(@as(u8, 0x54), bytes[1]); // 'T'
    try testing.expectEqual(@as(u8, 0x43), bytes[2]); // 'C'
    try testing.expectEqual(@as(u8, 0x48), bytes[3]); // 'H'
    // version_major = 2, version_minor = 0
    try testing.expectEqual(@as(u8, 2), bytes[4]);
    try testing.expectEqual(@as(u8, 0), bytes[5]);
    // flags = 0
    try testing.expectEqual(@as(u8, 0), bytes[6]);
    try testing.expectEqual(@as(u8, 0), bytes[7]);
}

test "Handshake magic constant" {
    try testing.expectEqual(@as(u32, 0x48435452), Handshake.MAGIC);
}

test "MessageType upgrade value" {
    try testing.expectEqual(@as(u8, 7), @intFromEnum(MessageType.upgrade));
}

test "upgrade packet format" {
    // Upgrade packet is [type=7, len=0]
    const pkt = Packet{
        .header = .{ .type = .upgrade, .len = 0 },
    };
    try testing.expectEqual(MessageType.upgrade, pkt.header.type);
    try testing.expectEqual(@as(u8, 0), pkt.header.len);

    const data = pkt.serialize();
    try testing.expectEqual(@as(usize, 2), data.len);
    try testing.expectEqual(@as(u8, 7), data[0]); // type
    try testing.expectEqual(@as(u8, 0), data[1]); // len
}

test "MessageType pause value" {
    try testing.expectEqual(@as(u8, 8), @intFromEnum(MessageType.pause));
}

test "MessageType resume value" {
    try testing.expectEqual(@as(u8, 9), @intFromEnum(MessageType.@"resume"));
}

test "ResponseType idle value" {
    try testing.expectEqual(@as(u8, 4), @intFromEnum(ResponseType.idle));
}

test "pause packet format" {
    const pkt = Packet.initPause();
    try testing.expectEqual(MessageType.pause, pkt.header.type);
    try testing.expectEqual(@as(u8, 0), pkt.header.len);

    const data = pkt.serialize();
    try testing.expectEqual(@as(usize, 2), data.len);
    try testing.expectEqual(@as(u8, 8), data[0]); // type
    try testing.expectEqual(@as(u8, 0), data[1]); // len
}

test "resume packet format" {
    const pkt = Packet.initResume();
    try testing.expectEqual(MessageType.@"resume", pkt.header.type);
    try testing.expectEqual(@as(u8, 0), pkt.header.len);

    const data = pkt.serialize();
    try testing.expectEqual(@as(usize, 2), data.len);
    try testing.expectEqual(@as(u8, 9), data[0]); // type
    try testing.expectEqual(@as(u8, 0), data[1]); // len
}
