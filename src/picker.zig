const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.picker);

/// Session info gathered from socket files and metadata
pub const SessionInfo = struct {
    /// Socket filename (UUID format)
    id: []const u8,
    /// Display name from metadata or generated
    name: []const u8,
    /// Terminal title from .title file (if exists)
    title: ?[]const u8,
    /// Last accessed timestamp (Unix seconds), from metadata or mtime
    last_active: i64,
    /// Full socket path
    socket_path: []const u8,
};

/// Result of the picker UI
pub const PickerResult = union(enum) {
    /// User selected an existing session
    existing: []const u8, // session ID
    /// User wants to create a new session
    new_session,
    /// User quit without selecting
    quit,
};

/// Interactive session picker
pub const Picker = struct {
    allocator: std.mem.Allocator,
    sessions: []SessionInfo,
    selected_index: usize = 0,
    scroll_offset: usize = 0,
    term_rows: u16 = 24,
    term_cols: u16 = 80,
    running: bool = true,
    orig_termios: ?std.c.termios = null,

    const SESSIONS_DIR = ".clauntty/sessions";
    const METADATA_FILE = ".clauntty/sessions.json";

    pub fn init(allocator: std.mem.Allocator) !*Picker {
        const self = try allocator.create(Picker);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .sessions = &.{},
        };

        return self;
    }

    pub fn deinit(self: *Picker) void {
        self.restoreTerminal();
        for (self.sessions) |session| {
            self.allocator.free(session.id);
            self.allocator.free(session.name);
            if (session.title) |t| self.allocator.free(t);
            self.allocator.free(session.socket_path);
        }
        if (self.sessions.len > 0) {
            self.allocator.free(self.sessions);
        }
        self.allocator.destroy(self);
    }

    /// Discover all sessions and show picker UI
    pub fn run(self: *Picker) !PickerResult {
        // Discover sessions
        self.sessions = try discoverSessions(self.allocator);

        // If no sessions, go directly to new session
        if (self.sessions.len == 0) {
            return .new_session;
        }

        // Setup terminal and run UI
        try self.setupTerminal();
        defer self.restoreTerminal();

        self.getTerminalSize();

        // Main loop
        while (self.running) {
            self.render();
            if (try self.handleInput()) |result| {
                return result;
            }
        }

        return .quit;
    }

    fn setupTerminal(self: *Picker) !void {
        if (!posix.isatty(posix.STDIN_FILENO)) {
            return error.NotATty;
        }

        var termios = try posix.tcgetattr(posix.STDIN_FILENO);
        self.orig_termios = termios;

        // Raw mode - same pattern as client.zig
        termios.iflag.IGNBRK = false;
        termios.iflag.BRKINT = false;
        termios.iflag.PARMRK = false;
        termios.iflag.ISTRIP = false;
        termios.iflag.INLCR = false;
        termios.iflag.IGNCR = false;
        termios.iflag.ICRNL = false;
        termios.iflag.IXON = false;

        termios.oflag.OPOST = false;

        termios.lflag.ECHO = false;
        termios.lflag.ECHONL = false;
        termios.lflag.ICANON = false;
        termios.lflag.ISIG = false;
        termios.lflag.IEXTEN = false;

        termios.cflag.CSIZE = .CS8;
        termios.cflag.PARENB = false;

        termios.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        termios.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, termios);
    }

    fn restoreTerminal(self: *Picker) void {
        if (self.orig_termios) |termios| {
            // Show cursor, clear screen
            _ = posix.write(posix.STDOUT_FILENO, "\x1b[?25h\x1b[2J\x1b[H") catch {};
            posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, termios) catch {};
            self.orig_termios = null;
        }
    }

    fn getTerminalSize(self: *Picker) void {
        var ws: posix.winsize = undefined;
        if (std.c.ioctl(posix.STDOUT_FILENO, std.c.T.IOCGWINSZ, &ws) == 0) {
            self.term_rows = ws.row;
            self.term_cols = ws.col;
        }
    }

    fn render(self: *Picker) void {
        var buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const writer = stream.writer();

        // Hide cursor, clear screen, home
        writer.writeAll("\x1b[?25l\x1b[2J\x1b[H") catch return;

        // Header
        writer.writeAll("\x1b[1mrtach - Select Session\x1b[0m\r\n") catch return;
        writer.writeAll("────────────────────────────────\r\n\r\n") catch return;

        // Calculate visible area (leave room for header and footer)
        const header_lines: usize = 3;
        const footer_lines: usize = 2;
        const available_rows = if (self.term_rows > header_lines + footer_lines)
            self.term_rows - header_lines - footer_lines
        else
            5;

        // Adjust scroll to keep selection visible
        if (self.selected_index < self.scroll_offset) {
            self.scroll_offset = self.selected_index;
        } else if (self.selected_index >= self.scroll_offset + available_rows) {
            self.scroll_offset = self.selected_index - available_rows + 1;
        }

        // Render sessions
        const end_idx = @min(self.scroll_offset + available_rows, self.sessions.len);
        for (self.sessions[self.scroll_offset..end_idx], self.scroll_offset..) |session, i| {
            const is_selected = i == self.selected_index;

            if (is_selected) {
                writer.writeAll("\x1b[7m") catch return; // Reverse video
            }

            // Selection indicator
            writer.writeAll(if (is_selected) "> " else "  ") catch return;

            // Title (from .title file) - column 1
            if (session.title) |title| {
                const title_width: usize = 24;
                const title_len = @min(title.len, title_width);
                writer.writeAll(title[0..title_len]) catch return;
                for (title_len..title_width) |_| {
                    writer.writeByte(' ') catch return;
                }
            } else {
                writer.writeAll("(no title)              ") catch return;
            }

            // Session name (verb-noun from sessions.json) - column 2, dim
            if (!is_selected) writer.writeAll("\x1b[90m") catch return;
            const name_width: usize = 18;
            const name_len = @min(session.name.len, name_width);
            writer.writeAll(session.name[0..name_len]) catch return;
            for (name_len..name_width) |_| {
                writer.writeByte(' ') catch return;
            }

            // Time ago (dim)
            const time_str = formatTimeAgo(session.last_active);
            writer.writeAll(time_str) catch return;

            writer.writeAll("\x1b[0m\r\n") catch return;
        }

        // Scroll indicators
        if (self.scroll_offset > 0) {
            writer.print("\x1b[{d};1H\x1b[90m  ↑ more\x1b[0m", .{header_lines}) catch return;
        }
        if (end_idx < self.sessions.len) {
            writer.print("\x1b[{d};1H\x1b[90m  ↓ more\x1b[0m", .{header_lines + available_rows - 1}) catch return;
        }

        // Footer
        writer.print("\x1b[{d};1H", .{self.term_rows - 1}) catch return;
        writer.writeAll("\r\n\x1b[90m[Enter] Select  [n] New  [d] Delete  [q] Quit\x1b[0m") catch return;

        _ = posix.write(posix.STDOUT_FILENO, stream.getWritten()) catch {};
    }

    fn handleInput(self: *Picker) !?PickerResult {
        var buf: [8]u8 = undefined;
        const n = try posix.read(posix.STDIN_FILENO, &buf);
        if (n == 0) return null;

        const input = buf[0..n];

        // Arrow keys: ESC [ A/B
        if (n >= 3 and input[0] == 0x1b and input[1] == '[') {
            switch (input[2]) {
                'A' => self.moveUp(), // Up arrow
                'B' => self.moveDown(), // Down arrow
                else => {},
            }
            return null;
        }

        // Single character commands
        switch (input[0]) {
            'j', 'J' => self.moveDown(),
            'k', 'K' => self.moveUp(),
            'n', 'N' => {
                self.running = false;
                return .new_session;
            },
            'd', 'D' => {
                // Delete selected session - for now just skip
                // TODO: implement deletion with confirmation
            },
            'q', 'Q' => {
                self.running = false;
                return .quit;
            },
            0x1b => { // Escape alone
                self.running = false;
                return .quit;
            },
            '\r', '\n' => {
                if (self.sessions.len > 0) {
                    self.running = false;
                    return .{ .existing = self.sessions[self.selected_index].id };
                }
            },
            else => {},
        }
        return null;
    }

    fn moveUp(self: *Picker) void {
        if (self.selected_index > 0) {
            self.selected_index -= 1;
        }
    }

    fn moveDown(self: *Picker) void {
        if (self.selected_index + 1 < self.sessions.len) {
            self.selected_index += 1;
        }
    }
};

/// Discover all sessions from ~/.clauntty/sessions/
pub fn discoverSessions(allocator: std.mem.Allocator) ![]SessionInfo {
    const home = std.posix.getenv("HOME") orelse return &.{};

    // Build sessions directory path
    var sessions_dir_buf: [512]u8 = undefined;
    const sessions_dir = std.fmt.bufPrint(&sessions_dir_buf, "{s}/{s}", .{ home, Picker.SESSIONS_DIR }) catch return &.{};

    // Load metadata JSON
    var metadata_path_buf: [512]u8 = undefined;
    const metadata_path = std.fmt.bufPrint(&metadata_path_buf, "{s}/{s}", .{ home, Picker.METADATA_FILE }) catch return &.{};
    const metadata = loadMetadata(allocator, metadata_path) catch std.StringHashMap(SessionMetadata).init(allocator);
    defer {
        var it = metadata.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.name);
        }
        @constCast(&metadata).deinit();
    }

    // Open sessions directory
    var dir = std.fs.cwd().openDir(sessions_dir, .{ .iterate = true }) catch return &.{};
    defer dir.close();

    // Collect sessions
    var sessions: std.ArrayListUnmanaged(SessionInfo) = .{};
    errdefer {
        for (sessions.items) |s| {
            allocator.free(s.id);
            allocator.free(s.name);
            if (s.title) |t| allocator.free(t);
            allocator.free(s.socket_path);
        }
        sessions.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip non-sockets and special files
        if (entry.kind != .unix_domain_socket) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        // Skip .title, .log, .cmd files
        if (std.mem.endsWith(u8, entry.name, ".title")) continue;
        if (std.mem.endsWith(u8, entry.name, ".log")) continue;
        if (std.mem.endsWith(u8, entry.name, ".cmd")) continue;

        const id = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(id);

        // Build full socket path
        var socket_path_buf: [1024]u8 = undefined;
        const socket_path = try allocator.dupe(u8, std.fmt.bufPrint(&socket_path_buf, "{s}/{s}", .{ sessions_dir, entry.name }) catch continue);
        errdefer allocator.free(socket_path);

        // Get metadata or generate defaults
        const name = if (metadata.get(id)) |m|
            try allocator.dupe(u8, m.name)
        else
            try allocator.dupe(u8, "session");
        errdefer allocator.free(name);

        // Get last active time from metadata or file mtime
        const last_active: i64 = if (metadata.get(id)) |m|
            m.last_accessed orelse m.created
        else blk: {
            const stat = dir.statFile(entry.name) catch break :blk 0;
            break :blk @intCast(@divTrunc(stat.mtime, std.time.ns_per_s));
        };

        // Try to read title file
        var title_path_buf: [1024]u8 = undefined;
        const title_path = std.fmt.bufPrint(&title_path_buf, "{s}.title", .{socket_path}) catch null;
        const title: ?[]const u8 = if (title_path) |tp| blk: {
            const title_file = std.fs.cwd().openFile(tp, .{}) catch break :blk null;
            defer title_file.close();
            const content = title_file.readToEndAlloc(allocator, 1024) catch break :blk null;
            // Trim whitespace
            const trimmed = std.mem.trim(u8, content, " \t\n\r");
            if (trimmed.len == 0) {
                allocator.free(content);
                break :blk null;
            }
            if (trimmed.ptr != content.ptr or trimmed.len != content.len) {
                const result = allocator.dupe(u8, trimmed) catch {
                    allocator.free(content);
                    break :blk null;
                };
                allocator.free(content);
                break :blk result;
            }
            break :blk content;
        } else null;

        try sessions.append(allocator, .{
            .id = id,
            .name = name,
            .title = title,
            .last_active = last_active,
            .socket_path = socket_path,
        });
    }

    // Sort by last_active (most recent first)
    std.mem.sort(SessionInfo, sessions.items, {}, struct {
        fn lessThan(_: void, a: SessionInfo, b: SessionInfo) bool {
            return a.last_active > b.last_active;
        }
    }.lessThan);

    return sessions.toOwnedSlice(allocator);
}

/// Metadata from sessions.json
const SessionMetadata = struct {
    name: []const u8,
    created: i64,
    last_accessed: ?i64,
};

/// Load session metadata from JSON file
fn loadMetadata(allocator: std.mem.Allocator, path: []const u8) !std.StringHashMap(SessionMetadata) {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var result = std.StringHashMap(SessionMetadata).init(allocator);
    errdefer {
        var it = result.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.name);
        }
        result.deinit();
    }

    // Parse JSON
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return result;
    defer parsed.deinit();

    if (parsed.value != .object) return result;

    var obj_iter = parsed.value.object.iterator();
    while (obj_iter.next()) |entry| {
        const session_id = entry.key_ptr.*;
        const session_obj = entry.value_ptr.*;

        if (session_obj != .object) continue;

        const name_val = session_obj.object.get("name") orelse continue;
        if (name_val != .string) continue;

        const created_val = session_obj.object.get("created") orelse continue;
        const created: i64 = switch (created_val) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f),
            else => continue,
        };

        var last_accessed: ?i64 = null;
        if (session_obj.object.get("lastAccessed")) |la| {
            last_accessed = switch (la) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => null,
            };
        }

        const id_copy = try allocator.dupe(u8, session_id);
        errdefer allocator.free(id_copy);
        const name_copy = try allocator.dupe(u8, name_val.string);

        try result.put(id_copy, .{
            .name = name_copy,
            .created = created,
            .last_accessed = last_accessed,
        });
    }

    return result;
}

/// Format a timestamp as relative time (e.g., "3h ago", "2d ago")
fn formatTimeAgo(timestamp: i64) []const u8 {
    const now = std.time.timestamp();
    const diff = now - timestamp;

    if (diff < 0) return "future";
    if (diff < 60) return "now";
    if (diff < 3600) {
        const mins = @divTrunc(diff, 60);
        return if (mins == 1) "1m ago" else switch (mins) {
            2 => "2m ago",
            3 => "3m ago",
            4 => "4m ago",
            5 => "5m ago",
            10...14 => "10m ago",
            15...29 => "15m ago",
            30...44 => "30m ago",
            45...59 => "45m ago",
            else => "<1h ago",
        };
    }
    if (diff < 86400) {
        const hours = @divTrunc(diff, 3600);
        return switch (hours) {
            1 => "1h ago",
            2 => "2h ago",
            3 => "3h ago",
            4 => "4h ago",
            5 => "5h ago",
            6 => "6h ago",
            12 => "12h ago",
            else => "<1d ago",
        };
    }
    const days = @divTrunc(diff, 86400);
    return switch (days) {
        1 => "1d ago",
        2 => "2d ago",
        3 => "3d ago",
        4 => "4d ago",
        5 => "5d ago",
        6 => "6d ago",
        7 => "1w ago",
        else => ">1w ago",
    };
}

/// Show the picker and return the result
/// Note: The caller owns the returned session ID string (if .existing)
pub fn showPicker(allocator: std.mem.Allocator) !PickerResult {
    var picker = try Picker.init(allocator);
    defer picker.deinit();
    const result = try picker.run();
    // Dupe the session ID before deinit frees it
    return switch (result) {
        .existing => |id| .{ .existing = try allocator.dupe(u8, id) },
        .new_session => .new_session,
        .quit => .quit,
    };
}
