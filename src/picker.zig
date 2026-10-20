//! Interactive picker (`rtach` with no arguments, or `clauntty` in a terminal): the
//! workspaces, tabs and panes the Clauntty app shows, each pane with its status, so a
//! laptop terminal (Herdr, tmux, plain ssh) can open the same panes as the phone.
//! Enter attaches; detaching (Ctrl+\) or the pane ending comes back here. New panes and
//! closes go through `rtach ws`, so the phone shows them in the right place.

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");
const ws = @import("ws.zig");

const Status = enum { none, idle, working, blocked, done };

const Row = struct {
    kind: enum { workspace, tab, pane, heading },
    /// Workspace or tab name, pane label, heading
    text: []const u8,
    /// Workspace: its folder. Pane: how long ago it was used.
    detail: []const u8 = "",
    pane: ?[]const u8 = null,
    status: Status = .none,
    /// Sessions in no workspace can't be split or closed from here
    in_workspace: bool = false,
};

/// Puts the outer terminal back after a pane: programs leave their modes on when the
/// client detaches (alternate screen, mouse reporting, bracketed paste, keyboard modes)
const reset_modes = "\x1b[?1049l\x1b[?1l\x1b>\x1b[?1004l\x1b[?2004l\x1b[?2031l\x1b[?7h" ++
    "\x1b[?9l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l" ++
    "\x1b[<99u\x1b[>4m\x1b[0 q\x1b[0m\x1b[?25h";

pub const Picker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    /// Rows, reloaded every second
    arena_state: std.heap.ArenaAllocator,
    rows: []const Row = &.{},
    /// The selected pane, kept across reloads by id
    selected: usize = 0,
    selected_id: [64]u8 = undefined,
    selected_id_len: usize = 0,
    scroll: usize = 0,
    term_rows: u16 = 24,
    term_cols: u16 = 80,
    orig_termios: ?std.c.termios = null,
    /// A line above the keys: an error, or the close confirmation
    message: [256]u8 = undefined,
    message_len: usize = 0,
    confirm_close: bool = false,
    /// Whether a pane was attached from here: switching panes clears the outer
    /// terminal's scrollback, so one pane's history doesn't run into the next's
    attached_before: bool = false,
    first: bool = true,
    socket_path: [std.fs.max_path_bytes]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !*Picker {
        const self = try allocator.create(Picker);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .home = sys.getenv("HOME") orelse return error.NoHomeDir,
            .arena_state = .init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Picker) void {
        self.restoreTerminal(false);
        self.arena_state.deinit();
        self.allocator.destroy(self);
    }

    /// Show the picker until a pane is chosen: its socket path, valid until the next
    /// call. Null when the user quits.
    pub fn choose(self: *Picker) !?[]const u8 {
        self.reload();
        // Nothing here yet: start a workspace, as `rtach -c` would a session
        if (self.first and self.rows.len == 0) {
            self.first = false;
            return self.runWs(&.{"new"});
        }
        self.first = false;

        try self.setupTerminal();
        while (true) {
            self.render();
            var fds = [_]posix.pollfd{.{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 }};
            // Statuses and the phone's changes show up within a second
            const ready = posix.poll(&fds, 1000) catch 0;
            if (ready == 0) {
                self.reload();
                continue;
            }
            switch (try self.handleInput()) {
                .none => {},
                .quit => {
                    self.restoreTerminal(false);
                    return null;
                },
                .attach => |path| {
                    self.restoreTerminal(true);
                    return path;
                },
            }
        }
    }

    /// Back from a pane: undo the modes it left on
    pub fn detached(self: *Picker) void {
        _ = sys.write(posix.STDOUT_FILENO, reset_modes) catch {};
        self.attached_before = true;
    }

    // MARK: Terminal

    fn setupTerminal(self: *Picker) !void {
        if (!sys.isatty(posix.STDIN_FILENO)) return error.NotATty;

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
        // The alternate screen, so quitting leaves the terminal as it was
        _ = sys.write(posix.STDOUT_FILENO, "\x1b[?1049h\x1b[?25l") catch {};
    }

    /// `clear`: a pane is next, on a clean screen
    fn restoreTerminal(self: *Picker, clear: bool) void {
        const termios = self.orig_termios orelse return;
        _ = sys.write(posix.STDOUT_FILENO, "\x1b[?1049l\x1b[?25h") catch {};
        if (clear) {
            _ = sys.write(posix.STDOUT_FILENO, if (self.attached_before) "\x1b[H\x1b[2J\x1b[3J" else "\x1b[H\x1b[2J") catch {};
        }
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, termios) catch {};
        self.orig_termios = null;
    }

    fn getTerminalSize(self: *Picker) void {
        var size: posix.winsize = undefined;
        if (std.c.ioctl(posix.STDOUT_FILENO, std.c.T.IOCGWINSZ, &size) == 0 and size.row > 0 and size.col > 0) {
            self.term_rows = size.row;
            self.term_cols = size.col;
        }
    }

    // MARK: Rows

    fn reload(self: *Picker) void {
        _ = self.arena_state.reset(.retain_capacity);
        self.rows = buildRows(self.arena_state.allocator(), self.io, self.home) catch &.{};
        // Stay on the same pane, else the nearest one
        const id = self.selected_id[0..self.selected_id_len];
        for (self.rows, 0..) |row, i| {
            if (row.pane) |pane| if (std.mem.eql(u8, pane, id)) {
                self.selected = i;
                return;
            };
        }
        if (self.selected >= self.rows.len) self.selected = self.rows.len -| 1;
        if (!self.isPane(self.selected)) self.move(.down);
        if (!self.isPane(self.selected)) self.move(.up);
        self.rememberSelection();
    }

    fn isPane(self: *Picker, index: usize) bool {
        return index < self.rows.len and self.rows[index].kind == .pane;
    }

    fn selectedRow(self: *Picker) ?Row {
        return if (self.isPane(self.selected)) self.rows[self.selected] else null;
    }

    fn move(self: *Picker, direction: enum { up, down }) void {
        var i = self.selected;
        while (true) {
            if (direction == .up) {
                if (i == 0) return;
                i -= 1;
            } else {
                if (i + 1 >= self.rows.len) return;
                i += 1;
            }
            if (self.isPane(i)) break;
        }
        self.selected = i;
        self.rememberSelection();
    }

    fn rememberSelection(self: *Picker) void {
        const pane = (self.selectedRow() orelse return).pane.?;
        const n = @min(pane.len, self.selected_id.len);
        @memcpy(self.selected_id[0..n], pane[0..n]);
        self.selected_id_len = n;
    }

    fn setMessage(self: *Picker, comptime format: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.message, format, args) catch self.message[0..0];
        self.message_len = text.len;
    }

    // MARK: Input

    const Action = union(enum) { none, quit, attach: []const u8 };

    fn handleInput(self: *Picker) !Action {
        var buf: [16]u8 = undefined;
        const n = try posix.read(posix.STDIN_FILENO, &buf);
        if (n == 0) return .quit;
        const input = buf[0..n];

        if (self.confirm_close) {
            self.confirm_close = false;
            self.message_len = 0;
            if (input[0] == 'y' or input[0] == 'Y') {
                const row = self.selectedRow() orelse return .none;
                _ = self.runWs(&.{ "close", row.pane.? }) catch {};
                self.reload();
            }
            return .none;
        }
        self.message_len = 0;

        // Arrow keys: ESC [ A/B (or ESC O A/B in application cursor mode)
        if (n >= 3 and input[0] == 0x1b and (input[1] == '[' or input[1] == 'O')) {
            switch (input[2]) {
                'A' => self.move(.up),
                'B' => self.move(.down),
                else => {},
            }
            return .none;
        }

        switch (input[0]) {
            'j' => self.move(.down),
            'k' => self.move(.up),
            '\r', '\n' => {
                const row = self.selectedRow() orelse return .none;
                // Attached to itself, its output would feed back in forever
                if (std.mem.eql(u8, row.pane.?, sys.getenv("RTACH_SESSION_ID") orelse "")) {
                    self.setMessage("That's the pane you're in", .{});
                    return .none;
                }
                return .{ .attach = self.paneSocket(row.pane.?) orelse return .none };
            },
            // A new pane next to the selected one, else a new workspace
            'n' => {
                const row = self.selectedRow();
                const args: []const []const u8 = if (row != null and row.?.in_workspace) &.{ "split", row.?.pane.? } else &.{"new"};
                const path = (self.runWs(args) catch return .none) orelse return .none;
                return .{ .attach = path };
            },
            // A new workspace here (the git root above this folder)
            'N' => {
                const path = (self.runWs(&.{"new"}) catch return .none) orelse return .none;
                return .{ .attach = path };
            },
            'x' => {
                const row = self.selectedRow() orelse return .none;
                if (!row.in_workspace) {
                    self.setMessage("Not in a workspace: end it from inside (exit)", .{});
                    return .none;
                }
                self.confirm_close = true;
                self.setMessage("Close \"{s}\"? It ends what's running there. y/n", .{clip(row.text, 60)});
            },
            'q', 0x03, 0x04 => return .quit,
            // Escape alone
            0x1b => if (n == 1) return .quit,
            else => {},
        }
        return .none;
    }

    /// Run a `ws` command; a new pane's socket path, if it made one
    fn runWs(self: *Picker, args: []const []const u8) !?[]const u8 {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const out = ws.call(arena, self.io, args) catch |err| {
            self.setMessage("{s}", .{ws.errorText(err)});
            return err;
        };
        const parsed = std.json.parseFromSliceLeaky(struct { pane: ?[]const u8 = null }, arena, out, .{ .ignore_unknown_fields = true }) catch return null;
        const pane = parsed.pane orelse return null;
        const n = @min(pane.len, self.selected_id.len);
        @memcpy(self.selected_id[0..n], pane[0..n]);
        self.selected_id_len = n;
        return self.paneSocket(pane);
    }

    fn paneSocket(self: *Picker, pane: []const u8) ?[]const u8 {
        return std.fmt.bufPrint(&self.socket_path, "{s}/.clauntty/sessions/{s}", .{ self.home, pane }) catch null;
    }

    // MARK: Drawing

    fn render(self: *Picker) void {
        self.getTerminalSize();
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        self.draw(&out.writer) catch return;
        _ = sys.write(posix.STDOUT_FILENO, out.written()) catch {};
    }

    fn draw(self: *Picker, w: *std.Io.Writer) !void {
        const cols: usize = self.term_cols;
        // Synchronized output, so the redraw doesn't flicker
        try w.writeAll("\x1b[?2026h\x1b[H\x1b[2J");

        var host_buf: [256]u8 = undefined;
        try w.print(" \x1b[1mrtach\x1b[0m\x1b[90m  {s}\x1b[0m\r\n\r\n", .{hostName(&host_buf)});

        const header_lines: usize = 2;
        const footer_lines: usize = 3;
        const available: usize = if (self.term_rows > header_lines + footer_lines + 1) self.term_rows - header_lines - footer_lines else 1;

        // Keep the selection in view, with its workspace's name when it fits
        if (self.selected < self.scroll) {
            self.scroll = self.selected;
            while (self.scroll > 0 and self.rows[self.scroll - 1].kind != .pane and self.selected - (self.scroll - 1) < available) self.scroll -= 1;
        } else if (self.selected >= self.scroll + available) {
            self.scroll = self.selected + 1 - available;
        }

        if (self.rows.len == 0) {
            try w.writeAll("   \x1b[90mNo sessions. n starts a workspace in this folder.\x1b[0m\r\n");
        }
        const end = @min(self.scroll + available, self.rows.len);
        for (self.rows[self.scroll..end], self.scroll..) |row, i| {
            try drawRow(w, row, i == self.selected, cols);
            try w.writeAll("\r\n");
        }

        // Footer: a message line, then the keys
        try w.print("\x1b[{d};1H", .{self.term_rows - 1});
        if (self.message_len > 0) {
            try w.writeAll(" \x1b[33m");
            _ = try writeClipped(w, self.message[0..self.message_len], cols -| 2);
            try w.writeAll("\x1b[0m");
        }
        try w.print("\x1b[{d};1H\x1b[90m ", .{self.term_rows});
        _ = try writeClipped(w, "enter attach · n new pane · N new workspace · x close · q quit · ctrl+\\ detaches back here", cols -| 2);
        try w.writeAll("\x1b[0m\x1b[?2026l");
    }

    fn drawRow(w: *std.Io.Writer, row: Row, selected: bool, cols: usize) !void {
        switch (row.kind) {
            .workspace => {
                try w.writeAll(" \x1b[1m");
                const used = try writeClipped(w, row.text, cols -| 4);
                try w.writeAll("\x1b[0m");
                // "~" in the home folder says it once
                if (!std.mem.eql(u8, row.detail, row.text)) {
                    try w.writeAll("\x1b[90m  ");
                    _ = try writeClipped(w, row.detail, cols -| (used + 4));
                    try w.writeAll("\x1b[0m");
                }
            },
            .heading => {
                try w.writeAll(" \x1b[1;90m");
                _ = try writeClipped(w, row.text, cols -| 2);
                try w.writeAll("\x1b[0m");
            },
            .tab => {
                try w.writeAll("   \x1b[90mtab ");
                _ = try writeClipped(w, row.text, cols -| 8);
                try w.writeAll("\x1b[0m");
            },
            .pane => {
                const glyph, const color = switch (row.status) {
                    .none => .{ "·", "\x1b[90m" },
                    .idle => .{ "○", "\x1b[90m" },
                    .working => .{ "◐", "\x1b[36m" },
                    .blocked => .{ "●", "\x1b[33m" },
                    .done => .{ "✓", "\x1b[32m" },
                };
                if (selected) try w.writeAll("\x1b[7m");
                try w.writeAll(if (selected) " > " else "   ");
                try w.print("{s}{s}{s} ", .{ color, glyph, if (selected) "\x1b[39m" else "\x1b[0m" });
                const label_width = cols -| (5 + row.detail.len + 2);
                const used = try writeClipped(w, row.text, label_width);
                // The time, right-aligned
                try w.splatByteAll(' ', label_width - used + 1);
                if (!selected) try w.writeAll("\x1b[90m");
                try w.print("{s} ", .{row.detail});
                try w.writeAll("\x1b[0m");
            },
        }
    }
};

// MARK: Rows from workspaces

fn buildRows(arena: std.mem.Allocator, io: std.Io, home: []const u8) ![]const Row {
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    var rows: std.ArrayList(Row) = .empty;
    var listed: std.StringHashMapUnmanaged(void) = .empty;

    const workspaces = try ws.list(arena, io, home);
    for (workspaces) |workspace| {
        try rows.append(arena, .{ .kind = .workspace, .text = workspace.name, .detail = tildePath(arena, home, workspace.cwd) });
        for (workspace.tabs) |tab| {
            if (workspace.tabs.len > 1) try rows.append(arena, .{ .kind = .tab, .text = tab.name });
            for (tab.panes) |pane| {
                try listed.put(arena, pane.id, {});
                try rows.append(arena, try paneRow(arena, io, home, now, pane.id, pane.title, pane.state, true));
            }
        }
    }

    // Sessions in no workspace (the app adopts them when it connects)
    var loose: std.ArrayList(Row) = .empty;
    const sessions = try std.fmt.allocPrint(arena, "{s}/.clauntty/sessions", .{home});
    if (std.Io.Dir.cwd().openDir(io, sessions, .{ .iterate = true })) |dir_value| {
        var dir = dir_value;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .unix_domain_socket or listed.contains(entry.name)) continue;
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ sessions, entry.name });
            if (!alive(path)) continue;
            const id = try arena.dupe(u8, entry.name);
            const title = readFile(arena, io, try std.fmt.allocPrint(arena, "{s}.title", .{path}));
            const state = parseState(arena, io, path);
            try loose.append(arena, try paneRow(arena, io, home, now, id, title, state, false));
        }
    } else |_| {}
    if (loose.items.len > 0) {
        try rows.append(arena, .{ .kind = .heading, .text = "Other sessions" });
        try rows.appendSlice(arena, loose.items);
    }
    return rows.items;
}

fn paneRow(arena: std.mem.Allocator, io: std.Io, home: []const u8, now: i64, id: []const u8, title: ?[]const u8, state: ?std.json.Value, in_workspace: bool) !Row {
    const path = try std.fmt.allocPrint(arena, "{s}/.clauntty/sessions/{s}", .{ home, id });
    const obj: ?std.json.ObjectMap = if (state) |s| switch (s) {
        .object => |o| o,
        else => null,
    } else null;
    const has_agent = if (obj) |o| blk: {
        const agent = field(o, "agent") orelse break :blk false;
        break :blk agent.len > 0 and !std.mem.eql(u8, agent, "none");
    } else false;
    const status: Status = if (!has_agent) .none else std.meta.stringToEnum(Status, field(obj.?, "state") orelse "") orelse .idle;
    return .{
        .kind = .pane,
        .text = paneLabel(arena, home, title, obj, has_agent),
        .detail = timeAgo(arena, now, lastUsed(io, path)),
        .pane = id,
        .status = if (status == .none and has_agent) .idle else status,
        .in_workspace = in_workspace,
    };
}

/// A pane's name, as the app titles it: an agent's conversation name (from Claude
/// Code's title, after its spinner or "✳") or task, else the program in front and its
/// folder
fn paneLabel(arena: std.mem.Allocator, home: []const u8, title: ?[]const u8, obj: ?std.json.ObjectMap, has_agent: bool) []const u8 {
    const fallback = if (title) |t| (if (t.len > 0) t else "shell") else "shell";
    const o = obj orelse return fallback;
    if (has_agent) {
        const task = field(o, "task") orelse "";
        const agent_fallback = if (task.len > 0) task else "Claude";
        const agent_title = field(o, "title") orelse return agent_fallback;
        const view = std.unicode.Utf8View.init(agent_title) catch return agent_fallback;
        var it = view.iterator();
        const first = it.nextCodepoint() orelse return agent_fallback;
        if (first < 0x2000) return agent_fallback;
        const topic = std.mem.trim(u8, agent_title[it.i..], " ");
        if (topic.len == 0 or std.mem.eql(u8, topic, "Claude Code")) return agent_fallback;
        return topic;
    }
    const dir = directoryName(home, field(o, "cwd") orelse "");
    const fg = field(o, "fg") orelse "";
    const shells = [_][]const u8{ "zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "login", "-zsh", "-bash" };
    const is_shell = for (shells) |shell| {
        if (std.mem.eql(u8, fg, shell)) break true;
    } else false;
    if (fg.len > 0 and !is_shell) {
        if (dir.len == 0) return fg;
        return std.fmt.allocPrint(arena, "{s} · {s}", .{ fg, dir }) catch fg;
    }
    return if (dir.len > 0) dir else fallback;
}

fn field(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// The last folder in `path`, "~" for the home folder
fn directoryName(home: []const u8, path: []const u8) []const u8 {
    if (path.len == 0) return "";
    if (std.mem.eql(u8, std.mem.trimEnd(u8, path, "/"), std.mem.trimEnd(u8, home, "/"))) return "~";
    const name = std.fs.path.basename(path);
    return if (name.len > 0) name else "/";
}

fn tildePath(arena: std.mem.Allocator, home: []const u8, path: []const u8) []const u8 {
    if (home.len == 0 or !std.mem.startsWith(u8, path, home)) return path;
    const rest = path[home.len..];
    if (rest.len > 0 and rest[0] != '/') return path;
    return std.fmt.allocPrint(arena, "~{s}", .{rest}) catch path;
}

fn readFile(arena: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch return null;
    return std.mem.trim(u8, data, " \t\r\n");
}

fn parseState(arena: std.mem.Allocator, io: std.Io, socket_path: []const u8) ?std.json.Value {
    const path = std.fmt.allocPrint(arena, "{s}.state", .{socket_path}) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024)) catch return null;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch null;
}

/// When the pane last changed: its title, its state (program, folder, agent), or its
/// start
fn lastUsed(io: std.Io, socket_path: []const u8) i64 {
    var latest: i64 = 0;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "", ".title", ".state" }) |suffix| {
        const path = std.fmt.bufPrint(&buf, "{s}{s}", .{ socket_path, suffix }) catch continue;
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        latest = @max(latest, stat.mtime.toSeconds());
    }
    return latest;
}

fn timeAgo(arena: std.mem.Allocator, now: i64, then: i64) []const u8 {
    if (then == 0) return "";
    const diff = @max(now - then, 0);
    if (diff < 60) return "now";
    if (diff < 3600) return std.fmt.allocPrint(arena, "{d}m", .{@divTrunc(diff, 60)}) catch "";
    if (diff < 86400) return std.fmt.allocPrint(arena, "{d}h", .{@divTrunc(diff, 3600)}) catch "";
    return std.fmt.allocPrint(arena, "{d}d", .{@divTrunc(diff, 86400)}) catch "";
}

fn alive(path: []const u8) bool {
    const fd = sys.unixSocket(false) catch return false;
    defer sys.close(fd);
    sys.connect(fd, path) catch return false;
    return true;
}

fn hostName(buf: []u8) []const u8 {
    if (std.c.gethostname(buf.ptr, buf.len) != 0) return "";
    const name = std.mem.sliceTo(buf, 0);
    // "studio.lan" is "studio"
    return name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
}

/// Write `text` in at most `width` columns, with "…" when it's cut. Returns the
/// columns used. Counts a codepoint as one column.
fn writeClipped(w: *std.Io.Writer, text: []const u8, width: usize) !usize {
    if (width == 0) return 0;
    const view = std.unicode.Utf8View.init(text) catch return writeClipped(w, "?", width);
    var it = view.iterator();
    var used: usize = 0;
    var start: usize = 0;
    while (it.nextCodepointSlice()) |slice| {
        const offset = @intFromPtr(slice.ptr) - @intFromPtr(text.ptr);
        if (used + 1 == width and offset + slice.len < text.len) {
            try w.writeAll(text[start..offset]);
            try w.writeAll("…");
            return width;
        }
        // Control characters would move the cursor
        if (slice.len == 1 and slice[0] < 0x20) {
            try w.writeAll(text[start..offset]);
            try w.writeByte(' ');
            start = offset + 1;
        }
        used += 1;
    }
    try w.writeAll(text[start..]);
    return used;
}

/// The first `max` bytes of `text`, cut at a codepoint
fn clip(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

test "writeClipped cuts with an ellipsis" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectEqual(@as(usize, 5), try writeClipped(&w, "hello world", 5));
    try std.testing.expectEqualStrings("hell…", w.buffered());

    w = .fixed(&buf);
    try std.testing.expectEqual(@as(usize, 5), try writeClipped(&w, "hello", 5));
    try std.testing.expectEqualStrings("hello", w.buffered());

    w = .fixed(&buf);
    try std.testing.expectEqual(@as(usize, 3), try writeClipped(&w, "a·b·c", 3));
    try std.testing.expectEqualStrings("a·…", w.buffered());
}

test "paneLabel names panes as the app does" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "agent", .{ .string = "claude" });
    try obj.put(std.testing.allocator, "title", .{ .string = "✳ Fix the picker" });
    try std.testing.expectEqualStrings("Fix the picker", paneLabel(arena, "/home/u", null, obj, true));
    try obj.put(std.testing.allocator, "title", .{ .string = "✳ Claude Code" });
    try obj.put(std.testing.allocator, "task", .{ .string = "make it faster" });
    try std.testing.expectEqualStrings("make it faster", paneLabel(arena, "/home/u", null, obj, true));

    var shell: std.json.ObjectMap = .empty;
    defer shell.deinit(std.testing.allocator);
    try shell.put(std.testing.allocator, "fg", .{ .string = "zsh" });
    try shell.put(std.testing.allocator, "cwd", .{ .string = "/home/u" });
    try std.testing.expectEqualStrings("~", paneLabel(arena, "/home/u", "title", shell, false));
}
