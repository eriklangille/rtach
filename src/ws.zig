//! `rtach ws`: workspaces, tabs and split layouts over rtach sessions.
//!
//! A pane is an ordinary rtach session (~/.clauntty/sessions/<id>, one master
//! each). Workspaces only group panes: ~/.clauntty/workspaces/<id>.json holds the
//! name, the directory new panes start in, and the tabs, each a split tree whose
//! leaves are pane ids:
//!
//!   {"id":"3f9a1c2e","name":"clauntty","cwd":"/src/clauntty","tabs":[
//!     {"id":"9b2c41d0","name":"1","layout":{"split":"h","ratio":0.5,"a":"<pane>","b":"<pane>"}}]}
//!
//! workspaces/order lists the ids in the order the user put them (`reorder`); ones
//! it doesn't have follow, oldest first.
//!
//! Every change happens under one flock on workspaces/.lock and replaces files by
//! rename, so the app and the desktop can both edit. A session in no workspace is a
//! plain tab. Removing a tab's last pane removes the tab, and a workspace's last tab
//! removes the workspace. A master that exits takes its pane out (`paneEnded`), and
//! `list` drops panes whose master doesn't answer.

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");
const cli = @import("cli.zig");
const ShellIntegration = @import("shell_integration.zig");

const Allocator = std.mem.Allocator;

// MARK: Model

pub const Dir = enum { h, v };

pub const Layout = union(enum) {
    pane: []const u8,
    split: *Split,

    pub fn jsonStringify(self: Layout, jw: anytype) !void {
        switch (self) {
            .pane => |id| try jw.write(id),
            .split => |s| {
                try jw.beginObject();
                try jw.objectField("split");
                try jw.write(@tagName(s.dir));
                try jw.objectField("ratio");
                try jw.write(s.ratio);
                try jw.objectField("a");
                try jw.write(s.a);
                try jw.objectField("b");
                try jw.write(s.b);
                try jw.endObject();
            },
        }
    }

    /// Pane ids in layout order (left to right, top to bottom)
    fn panes(self: Layout, arena: Allocator, out: *std.ArrayList([]const u8)) !void {
        switch (self) {
            .pane => |id| try out.append(arena, id),
            .split => |s| {
                try s.a.panes(arena, out);
                try s.b.panes(arena, out);
            },
        }
    }

    fn contains(self: Layout, pane: []const u8) bool {
        return switch (self) {
            .pane => |id| std.mem.eql(u8, id, pane),
            .split => |s| s.a.contains(pane) or s.b.contains(pane),
        };
    }

    /// The layout with `pane` split: `pane` keeps the first half, `new_pane` gets the second
    fn splitPane(self: Layout, arena: Allocator, pane: []const u8, dir: Dir, new_pane: []const u8) !Layout {
        switch (self) {
            .pane => |id| {
                if (!std.mem.eql(u8, id, pane)) return self;
                const s = try arena.create(Split);
                s.* = .{ .dir = dir, .ratio = 0.5, .a = self, .b = .{ .pane = new_pane } };
                return .{ .split = s };
            },
            .split => |s| {
                s.a = try s.a.splitPane(arena, pane, dir, new_pane);
                s.b = try s.b.splitPane(arena, pane, dir, new_pane);
                return self;
            },
        }
    }

    /// The split between `pane` and `other` (the smallest holding both) gives `pane`'s
    /// side `ratio` of the space, kept between 0.1 and 0.9. False if there's no such split.
    fn resize(self: Layout, pane: []const u8, other: []const u8, ratio: f64) bool {
        const s = switch (self) {
            .pane => return false,
            .split => |s| s,
        };
        const pane_first = s.a.contains(pane);
        const other_first = s.a.contains(other);
        if (pane_first == other_first) return (if (pane_first) s.a else s.b).resize(pane, other, ratio);
        if (!(if (pane_first) s.b.contains(other) else s.b.contains(pane))) return false;
        s.ratio = std.math.clamp(if (pane_first) ratio else 1 - ratio, 0.1, 0.9);
        return true;
    }

    /// The layout without `pane`, its sibling taking its place. Null if nothing's left.
    fn without(self: Layout, pane: []const u8) ?Layout {
        switch (self) {
            .pane => |id| return if (std.mem.eql(u8, id, pane)) null else self,
            .split => |s| {
                const a = s.a.without(pane) orelse return s.b.without(pane);
                const b = s.b.without(pane) orelse return a;
                s.a = a;
                s.b = b;
                return self;
            },
        }
    }

    fn fromJson(arena: Allocator, value: std.json.Value) !Layout {
        switch (value) {
            .string => |id| return .{ .pane = id },
            .object => |o| {
                const dir_name = stringField(o, "split") orelse return error.BadLayout;
                const s = try arena.create(Split);
                s.* = .{
                    .dir = std.meta.stringToEnum(Dir, dir_name) orelse return error.BadLayout,
                    .ratio = switch (o.get("ratio") orelse .null) {
                        .float => |f| f,
                        .integer => |i| @floatFromInt(i),
                        else => 0.5,
                    },
                    .a = try fromJson(arena, o.get("a") orelse return error.BadLayout),
                    .b = try fromJson(arena, o.get("b") orelse return error.BadLayout),
                };
                return .{ .split = s };
            },
            else => return error.BadLayout,
        }
    }
};

pub const Split = struct {
    dir: Dir,
    /// The first child's share
    ratio: f64,
    a: Layout,
    b: Layout,
};

pub const Tab = struct {
    id: []const u8,
    name: []const u8,
    layout: Layout,
};

pub const Workspace = struct {
    id: []const u8,
    name: []const u8,
    /// Where new panes start
    cwd: []const u8,
    tabs: std.ArrayList(Tab),

    pub fn jsonStringify(self: Workspace, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("name");
        try jw.write(self.name);
        try jw.objectField("cwd");
        try jw.write(self.cwd);
        try jw.objectField("tabs");
        try jw.write(self.tabs.items);
        try jw.endObject();
    }

    fn fromJson(arena: Allocator, value: std.json.Value) !Workspace {
        const o = switch (value) {
            .object => |o| o,
            else => return error.BadWorkspace,
        };
        var ws: Workspace = .{
            .id = stringField(o, "id") orelse return error.BadWorkspace,
            .name = stringField(o, "name") orelse "",
            .cwd = stringField(o, "cwd") orelse "",
            .tabs = .empty,
        };
        const tabs = switch (o.get("tabs") orelse .null) {
            .array => |a| a.items,
            else => &.{},
        };
        for (tabs) |tab_value| {
            const t = switch (tab_value) {
                .object => |t| t,
                else => return error.BadWorkspace,
            };
            try ws.tabs.append(arena, .{
                .id = stringField(t, "id") orelse return error.BadWorkspace,
                .name = stringField(t, "name") orelse "",
                .layout = try Layout.fromJson(arena, t.get("layout") orelse return error.BadWorkspace),
            });
        }
        return ws;
    }

    /// The tab holding `pane`
    fn tabOf(self: *Workspace, pane: []const u8) ?*Tab {
        for (self.tabs.items) |*tab| {
            if (tab.layout.contains(pane)) return tab;
        }
        return null;
    }

    /// Take `pane` out. Empty tabs go too.
    fn removePane(self: *Workspace, pane: []const u8) void {
        var i: usize = 0;
        while (i < self.tabs.items.len) {
            const tab = &self.tabs.items[i];
            if (tab.layout.without(pane)) |rest| {
                tab.layout = rest;
                i += 1;
            } else {
                _ = self.tabs.orderedRemove(i);
            }
        }
    }
};

fn stringField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

// MARK: Store

/// In `order`'s order; ones it doesn't have after, oldest first (ids sort by
/// creation, see newId)
fn sortWorkspaces(workspaces: []Workspace, order: []const []const u8) void {
    std.mem.sort(Workspace, workspaces, order, struct {
        fn rank(ids: []const []const u8, id: []const u8) usize {
            for (ids, 0..) |other, i| {
                if (std.mem.eql(u8, other, id)) return i;
            }
            return ids.len;
        }

        fn lessThan(ids: []const []const u8, a: Workspace, b: Workspace) bool {
            const ra = rank(ids, a.id);
            const rb = rank(ids, b.id);
            if (ra != rb) return ra < rb;
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);
}

/// All workspaces, loaded and saved under the lock
const Store = struct {
    arena: Allocator,
    io: std.Io,
    dir: []const u8,
    lock: sys.fd_t,
    workspaces: std.ArrayList(Workspace) = .empty,
    /// Ids loaded from disk, to delete the files of workspaces that are gone
    loaded_ids: std.ArrayList([]const u8) = .empty,

    fn open(arena: Allocator, io: std.Io, home: []const u8) !Store {
        const dir = try std.fmt.allocPrint(arena, "{s}/.clauntty/workspaces", .{home});
        try std.Io.Dir.cwd().createDirPath(io, dir);
        const lock_path = try std.fmt.allocPrint(arena, "{s}/.lock", .{dir});
        var store: Store = .{ .arena = arena, .io = io, .dir = dir, .lock = try sys.lockFile(lock_path) };
        errdefer sys.close(store.lock);
        try store.load();
        return store;
    }

    fn close(self: *Store) void {
        sys.close(self.lock);
    }

    fn load(self: *Store) !void {
        var dir = try std.Io.Dir.cwd().openDir(self.io, self.dir, .{ .iterate = true });
        defer dir.close(self.io);
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
            const data = dir.readFileAlloc(self.io, entry.name, self.arena, .limited(1024 * 1024)) catch continue;
            const value = std.json.parseFromSliceLeaky(std.json.Value, self.arena, data, .{}) catch continue;
            const ws = Workspace.fromJson(self.arena, value) catch continue;
            try self.workspaces.append(self.arena, ws);
            try self.loaded_ids.append(self.arena, ws.id);
        }
        sortWorkspaces(self.workspaces.items, self.readOrder());
    }

    /// The order file's ids; none if it's missing or unreadable
    fn readOrder(self: *Store) []const []const u8 {
        const path = std.fmt.allocPrint(self.arena, "{s}/order", .{self.dir}) catch return &.{};
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.arena, .limited(1024 * 1024)) catch return &.{};
        return std.json.parseFromSliceLeaky([]const []const u8, self.arena, data, .{}) catch &.{};
    }

    /// Write every workspace and the order, and delete the files of removed ones
    fn save(self: *Store) !void {
        for (self.workspaces.items) |ws| {
            const path = try std.fmt.allocPrint(self.arena, "{s}/{s}.json", .{ self.dir, ws.id });
            try self.replace(path, try std.json.Stringify.valueAlloc(self.arena, ws, .{ .whitespace = .indent_2 }));
        }
        var ids: std.ArrayList([]const u8) = .empty;
        for (self.workspaces.items) |ws| try ids.append(self.arena, ws.id);
        const order = try std.fmt.allocPrint(self.arena, "{s}/order", .{self.dir});
        try self.replace(order, try std.json.Stringify.valueAlloc(self.arena, ids.items, .{}));

        const cwd = std.Io.Dir.cwd();
        for (self.loaded_ids.items) |id| {
            if (self.find(id) != null) continue;
            const path = try std.fmt.allocPrint(self.arena, "{s}/{s}.json", .{ self.dir, id });
            cwd.deleteFile(self.io, path) catch {};
        }
    }

    /// Write `path` through a temp file and a rename
    fn replace(self: *Store, path: []const u8, data: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        const tmp = try std.fmt.allocPrint(self.arena, "{s}.{d}.tmp", .{ path, std.c.getpid() });
        try cwd.writeFile(self.io, .{ .sub_path = tmp, .data = data, .flags = .{ .permissions = .fromMode(0o600) } });
        cwd.rename(tmp, cwd, path, self.io) catch |err| {
            cwd.deleteFile(self.io, tmp) catch {};
            return err;
        };
    }

    fn find(self: *Store, id: []const u8) ?*Workspace {
        const i = self.indexOf(id) orelse return null;
        return &self.workspaces.items[i];
    }

    fn indexOf(self: *Store, id: []const u8) ?usize {
        for (self.workspaces.items, 0..) |ws, i| {
            if (std.mem.eql(u8, ws.id, id)) return i;
        }
        return null;
    }

    /// The workspace holding `pane`
    fn workspaceOf(self: *Store, pane: []const u8) ?*Workspace {
        for (self.workspaces.items) |*ws| {
            if (ws.tabOf(pane) != null) return ws;
        }
        return null;
    }

    /// Take `pane` out of every workspace. Empty workspaces go too.
    fn removePane(self: *Store, pane: []const u8) void {
        var i: usize = 0;
        while (i < self.workspaces.items.len) {
            self.workspaces.items[i].removePane(pane);
            if (self.workspaces.items[i].tabs.items.len == 0) {
                _ = self.workspaces.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

/// A master's pane ended: take it out of its workspace
pub fn paneEnded(allocator: Allocator, io: std.Io, socket_path: []const u8) void {
    const home = sys.getenv("HOME") orelse return;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Workspaces only hold sessions in ~/.clauntty/sessions
    const sessions = std.fmt.allocPrint(arena, "{s}/.clauntty/sessions/", .{home}) catch return;
    if (!std.mem.startsWith(u8, socket_path, sessions)) return;

    var store = Store.open(arena, io, home) catch return;
    defer store.close();
    const pane = std.fs.path.basename(socket_path);
    if (store.workspaceOf(pane) == null) return;
    store.removePane(pane);
    store.save() catch {};
}

/// The name of the workspace holding `pane`, copied into `buf`
pub fn workspaceName(allocator: Allocator, io: std.Io, pane: []const u8, buf: []u8) ?[]const u8 {
    const home = sys.getenv("HOME") orelse return null;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var store = Store.open(arena_state.allocator(), io, home) catch return null;
    defer store.close();
    const name = (store.workspaceOf(pane) orelse return null).name;
    if (name.len > buf.len) return null;
    @memcpy(buf[0..name.len], name);
    return buf[0..name.len];
}

// MARK: Panes

/// Ids sort by creation: seconds since the epoch, then random bits
fn newId(io: std.Io, arena: Allocator) ![]const u8 {
    var random: [2]u8 = undefined;
    io.random(&random);
    const secs: u64 = @intCast(@divFloor(sys.realtimeNs(), std.time.ns_per_s));
    return std.fmt.allocPrint(arena, "{x:0>9}{x:0>4}", .{ secs, std.mem.readInt(u16, &random, .big) });
}

fn newPaneId(io: std.Io, arena: Allocator) ![]const u8 {
    var b: [16]u8 = undefined;
    io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    // Uppercase like the app's session ids
    return std.fmt.allocPrint(arena, "{X:0>8}-{X:0>4}-{X:0>4}-{X:0>4}-{X:0>12}", .{
        std.mem.readInt(u32, b[0..4], .big),
        std.mem.readInt(u16, b[4..6], .big),
        std.mem.readInt(u16, b[6..8], .big),
        std.mem.readInt(u16, b[8..10], .big),
        std.mem.readInt(u48, b[10..16], .big),
    });
}

fn socketPath(arena: Allocator, home: []const u8, pane: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/.clauntty/sessions/{s}", .{ home, pane });
}

/// What a new pane keeps from whoever ran `ws`: who the user is, the terminal and
/// locale, and rtach's own setting. The rest comes from the shell's startup files, as
/// in a session the app opens over SSH. The caller's whole environment made a pane an
/// agent opened (`clauntty ws new -- claude`) part of that agent's session: a Claude
/// there inherited CLAUDECODE, CLAUDE_CODE_SESSION_ID and the rest, and took itself for
/// the agent's child (no transcript, the parent's messaging socket).
const pane_env = [_][]const u8{
    "HOME",          "USER",            "LOGNAME", "SHELL", "TERM", "LANG", "TMPDIR", "SSH_AUTH_SOCK",
    "XDG_RUNTIME_DIR", "RTACH_SPAWND_SOCKET",
};

/// PATH before the shell's startup files: what sshd gives a session the app opens
const default_path = if (@import("builtin").os.tag == .macos)
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
else
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

/// A new pane's environment (`pane_env` and the locale from ours, then `extra`)
fn paneEnvironment(arena: Allocator, extra: ?[:0]const u8) ![:null]?[*:0]const u8 {
    var env: std.ArrayList(?[*:0]const u8) = .empty;
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const line = std.mem.span(entry);
        const name = line[0 .. std.mem.indexOfScalar(u8, line, '=') orelse continue];
        const keep = std.mem.startsWith(u8, name, "LC_") or for (pane_env) |kept| {
            if (std.mem.eql(u8, name, kept)) break true;
        } else false;
        if (keep) try env.append(arena, entry);
    }
    try env.append(arena, default_path);
    if (extra) |line| try env.append(arena, line);
    return env.toOwnedSliceSentinel(arena, null);
}

/// Start a pane's master in `cwd`: this binary's `-n`, which goes through spawnd
/// where it runs. `typed` goes to the shell's first prompt (shell integration
/// reads it from CLAUNTTY_RUN), so the shell stays when it ends.
fn startPane(arena: Allocator, io: std.Io, home: []const u8, cwd: []const u8, typed: ?[]const u8) ![]const u8 {
    const pane = try newPaneId(io, arena);
    const sessions = try std.fmt.allocPrint(arena, "{s}/.clauntty/sessions", .{home});
    try std.Io.Dir.cwd().createDirPath(io, sessions);

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = try arena.dupeZ(u8, exe_buf[0..try std.process.executablePath(io, &exe_buf)]);
    const start_in = try arena.dupeZ(u8, if (isDirectory(io, cwd)) cwd else home);
    const argv = [_:null]?[*:0]const u8{ exe, "-n", try arena.dupeZ(u8, try socketPath(arena, home, pane)) };
    const run_line = if (typed) |command| try std.fmt.allocPrintSentinel(arena, "CLAUNTTY_RUN={s}", .{command}, 0) else null;
    const env = try paneEnvironment(arena, run_line);

    // Not std.process.run: its children get the Io's environment, which is empty
    const pid = try sys.fork();
    if (pid == 0) {
        _ = std.c.chdir(start_in);
        sys.execveZ(exe, &argv, env.ptr);
        std.process.exit(127);
    }
    if (sys.waitExitCode(pid) != 0) return error.PaneDidntStart;
    return pane;
}

/// Stop a pane's master, which then ends its program
fn stopPane(arena: Allocator, home: []const u8, pane: []const u8) void {
    const path = socketPath(arena, home, pane) catch return;
    const fd = sys.unixSocket(false) catch return;
    defer sys.close(fd);
    sys.connect(fd, path) catch return;
    const pid = sys.peerPid(fd) orelse return;
    posix.kill(pid, posix.SIG.TERM) catch {};
}

fn paneAlive(arena: Allocator, home: []const u8, pane: []const u8) bool {
    const path = socketPath(arena, home, pane) catch return false;
    const fd = sys.unixSocket(false) catch return false;
    defer sys.close(fd);
    sys.connect(fd, path) catch return false;
    return true;
}

fn paneTitle(arena: Allocator, io: std.Io, home: []const u8, pane: []const u8) ?[]const u8 {
    const path = std.fmt.allocPrint(arena, "{s}/.clauntty/sessions/{s}.title", .{ home, pane }) catch return null;
    const title = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch return null;
    // An older master wrote it as it came; JSON needs text
    return std.mem.trim(u8, @import("pane_state.zig").fixUtf8(title), " \n");
}

/// A pane's `<socket>.state` (see pane_state.zig), as JSON
fn paneState(arena: Allocator, io: std.Io, home: []const u8, pane: []const u8) ?std.json.Value {
    const path = std.fmt.allocPrint(arena, "{s}/.clauntty/sessions/{s}.state", .{ home, pane }) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024)) catch return null;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch null;
}

/// The directory a pane's program is in, if its master has said
fn paneCwd(arena: Allocator, io: std.Io, home: []const u8, pane: []const u8) ?[]const u8 {
    const state = paneState(arena, io, home, pane) orelse return null;
    const obj = switch (state) {
        .object => |o| o,
        else => return null,
    };
    const cwd = stringField(obj, "cwd") orelse return null;
    return if (cwd.len > 0) cwd else null;
}

fn isDirectory(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

/// The git root above `dir`, or `dir` itself
fn projectRoot(arena: Allocator, io: std.Io, dir: []const u8) []const u8 {
    var current: ?[]const u8 = dir;
    while (current) |d| : (current = std.fs.path.dirname(d)) {
        const git = std.fmt.allocPrint(arena, "{s}/.git", .{d}) catch return dir;
        if (std.Io.Dir.cwd().statFile(io, git, .{})) |_| return d else |_| {}
    }
    return dir;
}

// MARK: Commands

const usage =
    \\Usage: rtach ws <command> [args]  (or clauntty ws)
    \\
    \\Workspaces group rtach sessions (panes) into tabs with split layouts.
    \\PANE defaults to the current session ($RTACH_SESSION_ID), else the one the
    \\Clauntty app shows on this machine.
    \\
    \\Commands:
    \\  new [NAME] [--cwd DIR] [--after WS]
    \\                              New workspace with one tab and pane. DIR defaults
    \\                              to the git root above the current directory. It
    \\                              goes after WS, else after the current pane's
    \\                              workspace, else last.
    \\  tab [WS] [--name NAME]      New tab with one pane (WS: the current one)
    \\  split [PANE] [-h|-v]        New pane next to PANE (-h side by side, default;
    \\                              -v stacked)
    \\  new, tab, split ... -- CMD  Also type CMD at the new pane's prompt (bash,
    \\                              zsh, fish); the shell stays when it ends
    \\  close [PANE]                End PANE and take it out of its tab
    \\  end WS                      End a workspace and all its panes
    \\  add SESSION...              Make each existing session a one-pane workspace
    \\  move PANE TAB               Move PANE into TAB, next to its last pane
    \\  rename ID NAME              Rename a workspace or tab
    \\  reorder WS [--before OTHER] Move a workspace before OTHER, or last
    \\  resize PANE OTHER RATIO     The split between two panes of a tab gives PANE's
    \\                              side RATIO of the space (0.1 to 0.9)
    \\  list [--json]               Workspaces, tabs and panes
    \\
    \\Changes print the new or affected ids as JSON, and tell the Clauntty app,
    \\which shows a new pane right away (--quiet: it only refreshes).
    \\
;

const Context = struct {
    arena: Allocator,
    io: std.Io,
    home: []const u8,
    out: std.ArrayList(u8) = .empty,
    /// --quiet: the app refreshes, but doesn't show the new pane (the app's own commands,
    /// an agent that shouldn't move the user's screen). It used to tell the app nothing:
    /// a workspace an agent made with --quiet didn't appear until something else
    /// refreshed, and one the phone made didn't reach the laptop.
    quiet: bool = false,
    /// Tell the app to refresh, not to show the new pane (the picker: each device
    /// keeps its own place)
    refresh_only: bool = false,

    fn print(self: *Context, comptime format: []const u8, args: anytype) void {
        self.out.print(self.arena, format, args) catch {};
    }

    fn json(self: *Context, value: anytype) void {
        const text = std.json.Stringify.valueAlloc(self.arena, value, .{}) catch return;
        self.print("{s}\n", .{text});
    }

    /// Tell the app the workspaces changed: `workspace;<ws>/<pane>` to show a new pane,
    /// `workspace;` to refresh
    fn notify(self: *Context, workspace: ?[]const u8, pane: ?[]const u8) void {
        const value = if (workspace != null and pane != null and !self.refresh_only and !self.quiet)
            std.fmt.allocPrint(self.arena, "{s}/{s}", .{ workspace.?, pane.? }) catch return
        else
            "";
        cli.notify(self.io, "workspace", value);
    }
};

/// `rtach ws <command>`
pub fn main(allocator: Allocator, io: std.Io, process_args: std.process.Args) u8 {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    var it = process_args.iterate();
    _ = it.skip(); // rtach
    _ = it.skip(); // ws
    while (it.next()) |arg| args.append(allocator, arg) catch return 1;
    return run(allocator, io, args.items);
}

/// `rtach ws` or `clauntty ws`, with the arguments after `ws`
pub fn run(allocator: Allocator, io: std.Io, raw_args: []const []const u8) u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args: std.ArrayList([]const u8) = .empty;
    var quiet = false;
    for (raw_args, 0..) |arg, i| {
        // The rest is a command for the new pane, --quiet included
        if (std.mem.eql(u8, arg, "--")) {
            args.appendSlice(arena, raw_args[i..]) catch return 1;
            break;
        }
        if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
            continue;
        }
        args.append(arena, arg) catch return 1;
    }

    const home = sys.getenv("HOME") orelse {
        fail("HOME isn't set\n", .{});
        return 1;
    };
    var ctx: Context = .{ .arena = arena, .io = io, .home = home, .quiet = quiet };
    const command = if (args.items.len > 0) args.items[0] else {
        fail(usage, .{});
        return 2;
    };
    dispatch(&ctx, command, args.items[1..]) catch |err| {
        if (err == error.UnknownCommand) {
            fail(usage, .{});
            return 2;
        }
        fail("rtach ws {s}: {s}\n", .{ command, errorText(err) });
        return 1;
    };
    _ = sys.write(posix.STDOUT_FILENO, ctx.out.items) catch {};
    return 0;
}

/// A `ws` command from the picker: its JSON output, in `arena`. The app refreshes
/// but stays on its own pane.
pub fn call(arena: Allocator, io: std.Io, args: []const []const u8) ![]const u8 {
    const home = sys.getenv("HOME") orelse return error.NoHomeDir;
    var ctx: Context = .{ .arena = arena, .io = io, .home = home, .refresh_only = true };
    try dispatch(&ctx, args[0], args[1..]);
    return ctx.out.items;
}

fn dispatch(ctx: *Context, command: []const u8, rest: []const []const u8) !void {
    const eql = std.mem.eql;
    return if (eql(u8, command, "new"))
        cmdNew(ctx, rest)
    else if (eql(u8, command, "tab"))
        cmdTab(ctx, rest)
    else if (eql(u8, command, "split"))
        cmdSplit(ctx, rest)
    else if (eql(u8, command, "close"))
        cmdClose(ctx, rest)
    else if (eql(u8, command, "end"))
        cmdEnd(ctx, rest)
    else if (eql(u8, command, "add"))
        cmdAdd(ctx, rest)
    else if (eql(u8, command, "move"))
        cmdMove(ctx, rest)
    else if (eql(u8, command, "rename"))
        cmdRename(ctx, rest)
    else if (eql(u8, command, "reorder"))
        cmdReorder(ctx, rest)
    else if (eql(u8, command, "resize"))
        cmdResize(ctx, rest)
    else if (eql(u8, command, "list") or eql(u8, command, "ls"))
        cmdList(ctx, rest)
    else
        error.UnknownCommand;
}

pub fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.NoPane => "no pane given, not inside an rtach session, and Clauntty shows none",
        error.NotInWorkspace => "that pane isn't in a workspace",
        error.NoSuchWorkspace => "no such workspace",
        error.NoSuchTab => "no such tab",
        error.NoSuchId => "no workspace or tab with that id",
        error.NotASession => "no session answers with that id",
        error.AlreadyInWorkspace => "that session is already in a workspace",
        error.NotSplit => "no split between those panes",
        error.PaneDidntStart => "the new pane's session didn't start",
        error.NoShellIntegration => "-- CMD needs bash, zsh or fish as $SHELL",
        error.Usage => "wrong arguments (see rtach ws)",
        else => @errorName(err),
    };
}

fn fail(comptime format: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, format, args) catch return;
    _ = sys.write(posix.STDERR_FILENO, msg) catch {};
}

/// The PANE argument, else the current session, else the one the app shows (so an
/// agent outside rtach can act on what the user is looking at)
fn paneArg(ctx: *Context, positional: []const []const u8, index: usize) ![]const u8 {
    if (positional.len > index) return positional[index];
    if (sys.getenv("RTACH_SESSION_ID")) |id| return id;
    const buf = try ctx.arena.alloc(u8, 64);
    return cli.activeSessionId(ctx.io, buf) orelse error.NoPane;
}

const Parsed = struct {
    positional: std.ArrayList([]const u8) = .empty,
    name: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    after: ?[]const u8 = null,
    before: ?[]const u8 = null,
    dir: Dir = .h,
    json: bool = false,
    /// After `--`: a command to type in the new pane
    run: ?[]const u8 = null,
};

fn parse(arena: Allocator, args: []const []const u8) !Parsed {
    var p: Parsed = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const option: ?*?[]const u8 = if (std.mem.eql(u8, arg, "--name"))
            &p.name
        else if (std.mem.eql(u8, arg, "--cwd"))
            &p.cwd
        else if (std.mem.eql(u8, arg, "--after"))
            &p.after
        else if (std.mem.eql(u8, arg, "--before"))
            &p.before
        else
            null;
        if (option) |field| {
            i += 1;
            if (i >= args.len) return error.Usage;
            field.* = args[i];
        } else if (std.mem.eql(u8, arg, "-h")) {
            p.dir = .h;
        } else if (std.mem.eql(u8, arg, "-v")) {
            p.dir = .v;
        } else if (std.mem.eql(u8, arg, "--json")) {
            p.json = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            const words = args[i + 1 ..];
            if (words.len == 0) return error.Usage;
            const command = try std.mem.join(arena, " ", words);
            // One line: it's typed at a prompt
            if (std.mem.indexOfAny(u8, command, "\r\n") != null) return error.Usage;
            // Only shell integration runs it
            const shell = sys.getenv("SHELL") orelse "/bin/sh";
            if (ShellIntegration.detectShellType(shell) == .unknown) return error.NoShellIntegration;
            p.run = command;
            break;
        } else {
            try p.positional.append(arena, arg);
        }
    }
    return p;
}

fn cmdNew(ctx: *Context, args: []const []const u8) !void {
    const p = try parse(ctx.arena, args);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const here = std.mem.sliceTo(std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.NoCwd, 0);
    const dir = p.cwd orelse projectRoot(ctx.arena, ctx.io, try ctx.arena.dupe(u8, here));
    // The home folder is "~", as in a prompt, not the user's name
    const at_home = std.mem.eql(u8, std.mem.trimEnd(u8, dir, "/"), std.mem.trimEnd(u8, ctx.home, "/"));
    const name = if (p.positional.items.len > 0) p.positional.items[0] else if (at_home) "~" else std.fs.path.basename(dir);

    // Start the pane before taking the lock: masters started by spawnd take it on exit
    const pane = try startPane(ctx.arena, ctx.io, ctx.home, dir, p.run);
    var store = try Store.open(ctx.arena, ctx.io, ctx.home);
    defer store.close();
    var ws: Workspace = .{ .id = try newId(ctx.io, ctx.arena), .name = name, .cwd = dir, .tabs = .empty };
    const tab: Tab = .{ .id = try newId(ctx.io, ctx.arena), .name = "1", .layout = .{ .pane = pane } };
    try ws.tabs.append(ctx.arena, tab);
    // Right after the workspace it's made from: --after's, else the current pane's
    const from = p.after orelse if (sys.getenv("RTACH_SESSION_ID")) |current|
        if (store.workspaceOf(current)) |w| w.id else null
    else
        null;
    const index = if (from) |id| if (store.indexOf(id)) |i| i + 1 else null else null;
    try store.workspaces.insert(ctx.arena, index orelse store.workspaces.items.len, ws);
    try store.save();
    ctx.json(.{ .workspace = ws.id, .tab = tab.id, .pane = pane });
    ctx.notify(ws.id, pane);
}

fn cmdTab(ctx: *Context, args: []const []const u8) !void {
    const p = try parse(ctx.arena, args);
    var store = try Store.open(ctx.arena, ctx.io, ctx.home);
    const ws_id = blk: {
        if (p.positional.items.len > 0) break :blk p.positional.items[0];
        const current = try paneArg(ctx, &.{}, 0);
        break :blk (store.workspaceOf(current) orelse return error.NotInWorkspace).id;
    };
    const cwd = (store.find(ws_id) orelse return error.NoSuchWorkspace).cwd;
    store.close();

    const pane = try startPane(ctx.arena, ctx.io, ctx.home, cwd, p.run);
    store = try Store.open(ctx.arena, ctx.io, ctx.home);
    defer store.close();
    // Gone while the pane started: end the pane again
    const ws = store.find(ws_id) orelse {
        stopPane(ctx.arena, ctx.home, pane);
        return error.NoSuchWorkspace;
    };
    const name = p.name orelse try std.fmt.allocPrint(ctx.arena, "{d}", .{ws.tabs.items.len + 1});
    const tab: Tab = .{ .id = try newId(ctx.io, ctx.arena), .name = name, .layout = .{ .pane = pane } };
    try ws.tabs.append(ctx.arena, tab);
    try store.save();
    ctx.json(.{ .workspace = ws.id, .tab = tab.id, .pane = pane });
    ctx.notify(ws.id, pane);
}

fn cmdSplit(ctx: *Context, args: []const []const u8) !void {
    const p = try parse(ctx.arena, args);
    const target = try paneArg(ctx, p.positional.items, 0);
    var store = try Store.open(ctx.arena, ctx.io, ctx.home);
    const ws_cwd = (store.workspaceOf(target) orelse return error.NotInWorkspace).cwd;
    store.close();
    // Next to the pane: in its directory
    const cwd = paneCwd(ctx.arena, ctx.io, ctx.home, target) orelse ws_cwd;

    const pane = try startPane(ctx.arena, ctx.io, ctx.home, cwd, p.run);
    store = try Store.open(ctx.arena, ctx.io, ctx.home);
    defer store.close();
    const ws = store.workspaceOf(target) orelse {
        stopPane(ctx.arena, ctx.home, pane);
        return error.NotInWorkspace;
    };
    const tab = ws.tabOf(target).?;
    tab.layout = try tab.layout.splitPane(ctx.arena, target, p.dir, pane);
    try store.save();
    ctx.json(.{ .workspace = ws.id, .tab = tab.id, .pane = pane });
    ctx.notify(ws.id, pane);
}

fn cmdClose(ctx: *Context, args: []const []const u8) !void {
    const p = try parse(ctx.arena, args);
    const pane = try paneArg(ctx, p.positional.items, 0);
    {
        var store = try Store.open(ctx.arena, ctx.io, ctx.home);
        defer store.close();
        if (store.workspaceOf(pane) == null) return error.NotInWorkspace;
        store.removePane(pane);
        try store.save();
    }
    // After the lock is released: the master takes it on exit
    stopPane(ctx.arena, ctx.home, pane);
    ctx.json(.{ .closed = pane });
    ctx.notify(null, null);
}

fn cmdEnd(ctx: *Context, args: []const []const u8) !void {
    const p = try parse(ctx.arena, args);
    if (p.positional.items.len != 1) return error.Usage;
    var panes: std.ArrayList([]const u8) = .empty;
    {
        var store = try Store.open(ctx.arena, ctx.io, ctx.home);
        defer store.close();
        const ws = store.find(p.positional.items[0]) orelse return error.NoSuchWorkspace;
        for (ws.tabs.items) |tab| try tab.layout.panes(ctx.arena, &panes);
        for (panes.items) |pane| store.removePane(pane);
        try store.save();
    }
    // After the lock is released: each master takes it on exit
    for (panes.items) |pane| stopPane(ctx.arena, ctx.home, pane);
    ctx.json(.{ .ended = p.positional.items[0] });
    ctx.notify(null, null);
}

fn cmdAdd(ctx: *Context, args: []const []const u8) !void {
    const p = try parse(ctx.arena, args);
    if (p.positional.items.len == 0) return error.Usage;
    var store = try Store.open(ctx.arena, ctx.io, ctx.home);
    defer store.close();
    var added: std.ArrayList(Created) = .empty;
    for (p.positional.items) |pane| {
        if (store.workspaceOf(pane) != null) return error.AlreadyInWorkspace;
        if (!paneAlive(ctx.arena, ctx.home, pane)) return error.NotASession;
        const title = paneTitle(ctx.arena, ctx.io, ctx.home, pane);
        var ws: Workspace = .{
            .id = try newId(ctx.io, ctx.arena),
            .name = p.name orelse if (title) |t| (if (t.len > 0) t else "shell") else "shell",
            // Where the session is isn't known; new panes start at home
            .cwd = p.cwd orelse ctx.home,
            .tabs = .empty,
        };
        const tab: Tab = .{ .id = try newId(ctx.io, ctx.arena), .name = "1", .layout = .{ .pane = pane } };
        try ws.tabs.append(ctx.arena, tab);
        try store.workspaces.append(ctx.arena, ws);
        try added.append(ctx.arena, .{ .workspace = ws.id, .tab = tab.id, .pane = pane });
    }
    try store.save();
    ctx.json(added.items);
    ctx.notify(null, null);
}

const Created = struct { workspace: []const u8, tab: []const u8, pane: []const u8 };

fn cmdMove(ctx: *Context, args: []const []const u8) !void {
    const p = try parse(ctx.arena, args);
    if (p.positional.items.len != 2) return error.Usage;
    const pane = p.positional.items[0];
    const tab_id = p.positional.items[1];
    var store = try Store.open(ctx.arena, ctx.io, ctx.home);
    defer store.close();
    if (store.workspaceOf(pane) == null) return error.NotInWorkspace;

    var dest: ?*Tab = null;
    var dest_ws: ?*Workspace = null;
    for (store.workspaces.items) |*ws| {
        for (ws.tabs.items) |*tab| {
            if (std.mem.eql(u8, tab.id, tab_id)) {
                dest = tab;
                dest_ws = ws;
            }
        }
    }
    const to = dest orelse return error.NoSuchTab;
    if (to.layout.contains(pane)) return;
    // Put it next to the destination's last pane before taking it out, so a move
    // that empties the source tab doesn't remove the destination's workspace
    var panes: std.ArrayList([]const u8) = .empty;
    try to.layout.panes(ctx.arena, &panes);
    const last = panes.items[panes.items.len - 1];
    const ws_id = dest_ws.?.id;
    const tab_copy = to.id;
    store.removePane(pane);
    // removePane can reorder or drop workspaces: find the tab again
    for (store.workspaces.items) |*ws| {
        if (!std.mem.eql(u8, ws.id, ws_id)) continue;
        for (ws.tabs.items) |*tab| {
            if (std.mem.eql(u8, tab.id, tab_copy)) {
                tab.layout = try tab.layout.splitPane(ctx.arena, last, .h, pane);
            }
        }
    }
    try store.save();
    ctx.json(.{ .workspace = ws_id, .tab = tab_copy, .pane = pane });
    ctx.notify(ws_id, pane);
}

fn cmdRename(ctx: *Context, args: []const []const u8) !void {
    const p = try parse(ctx.arena, args);
    if (p.positional.items.len != 2) return error.Usage;
    const id = p.positional.items[0];
    const name = p.positional.items[1];
    var store = try Store.open(ctx.arena, ctx.io, ctx.home);
    defer store.close();
    for (store.workspaces.items) |*ws| {
        if (std.mem.eql(u8, ws.id, id)) {
            ws.name = name;
            try store.save();
            ctx.json(.{ .renamed = id });
            ctx.notify(null, null);
            return;
        }
        for (ws.tabs.items) |*tab| {
            if (std.mem.eql(u8, tab.id, id)) {
                tab.name = name;
                try store.save();
                ctx.json(.{ .renamed = id });
                ctx.notify(null, null);
                return;
            }
        }
    }
    return error.NoSuchId;
}

fn cmdReorder(ctx: *Context, args: []const []const u8) !void {
    const p = try parse(ctx.arena, args);
    if (p.positional.items.len != 1) return error.Usage;
    const id = p.positional.items[0];
    var store = try Store.open(ctx.arena, ctx.io, ctx.home);
    defer store.close();
    const ws = store.workspaces.orderedRemove(store.indexOf(id) orelse return error.NoSuchWorkspace);
    const index = if (p.before) |other| store.indexOf(other) orelse return error.NoSuchWorkspace else store.workspaces.items.len;
    try store.workspaces.insert(ctx.arena, index, ws);
    try store.save();
    ctx.json(.{ .reordered = id });
    ctx.notify(null, null);
}

fn cmdResize(ctx: *Context, args: []const []const u8) !void {
    const p = try parse(ctx.arena, args);
    if (p.positional.items.len != 3) return error.Usage;
    const pane = p.positional.items[0];
    const other = p.positional.items[1];
    const ratio = std.fmt.parseFloat(f64, p.positional.items[2]) catch return error.Usage;
    if (!(ratio > 0 and ratio < 1)) return error.Usage;
    var store = try Store.open(ctx.arena, ctx.io, ctx.home);
    defer store.close();
    const ws = store.workspaceOf(pane) orelse return error.NotInWorkspace;
    const tab = ws.tabOf(pane).?;
    if (!tab.layout.resize(pane, other, ratio)) return error.NotSplit;
    try store.save();
    ctx.json(.{ .workspace = ws.id, .tab = tab.id });
    ctx.notify(null, null);
}

pub const PaneInfo = struct {
    id: []const u8,
    title: ?[]const u8,
    /// Its master's <socket>.state: fg, cwd, agent, state, note
    state: ?std.json.Value,
};

pub const TabInfo = struct {
    id: []const u8,
    name: []const u8,
    panes: []const PaneInfo,
    layout: Layout,
};

pub const WorkspaceInfo = struct {
    id: []const u8,
    name: []const u8,
    cwd: []const u8,
    tabs: []const TabInfo,
};

fn cmdList(ctx: *Context, args: []const []const u8) !void {
    const p = try parse(ctx.arena, args);
    const infos = try list(ctx.arena, ctx.io, ctx.home);
    if (p.json) {
        ctx.json(.{ .workspaces = infos });
        return;
    }
    if (infos.len == 0) {
        ctx.print("No workspaces. Start one with: rtach ws new\n", .{});
        return;
    }
    for (infos) |ws| {
        ctx.print("{s}  ({s})  {s}\n", .{ ws.name, ws.id, ws.cwd });
        for (ws.tabs) |tab| {
            ctx.print("  tab {s}  ({s})\n", .{ tab.name, tab.id });
            for (tab.panes) |pane| ctx.print("    {s}  {s}\n", .{ pane.id, pane.title orelse "" });
        }
    }
}

/// Every workspace with its panes' titles and states, in `arena`. Drops panes whose
/// master is gone.
pub fn list(arena: Allocator, io: std.Io, home: []const u8) ![]const WorkspaceInfo {
    var store = try Store.open(arena, io, home);
    defer store.close();

    // Drop panes whose master is gone (a crash, or an exit that couldn't update the file)
    var all: std.ArrayList([]const u8) = .empty;
    for (store.workspaces.items) |ws| {
        for (ws.tabs.items) |tab| try tab.layout.panes(arena, &all);
    }
    var pruned = false;
    for (all.items) |pane| {
        if (!paneAlive(arena, home, pane)) {
            store.removePane(pane);
            pruned = true;
        }
    }
    if (pruned) try store.save();

    var infos: std.ArrayList(WorkspaceInfo) = .empty;
    for (store.workspaces.items) |ws| {
        var tabs: std.ArrayList(TabInfo) = .empty;
        for (ws.tabs.items) |tab| {
            var ids: std.ArrayList([]const u8) = .empty;
            try tab.layout.panes(arena, &ids);
            var panes: std.ArrayList(PaneInfo) = .empty;
            for (ids.items) |id| try panes.append(arena, .{
                .id = id,
                .title = paneTitle(arena, io, home, id),
                .state = paneState(arena, io, home, id),
            });
            try tabs.append(arena, .{ .id = tab.id, .name = tab.name, .panes = panes.items, .layout = tab.layout });
        }
        try infos.append(arena, .{ .id = ws.id, .name = ws.name, .cwd = ws.cwd, .tabs = tabs.items });
    }
    return infos.items;
}

// MARK: Tests

const testing = std.testing;

fn testLayout(arena: Allocator, json: []const u8) !Layout {
    return Layout.fromJson(arena, try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}));
}

fn layoutJson(arena: Allocator, layout: Layout) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, layout, .{});
}

test "split, then remove, gives the sibling its place" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var layout = try testLayout(arena, "\"A\"");
    layout = try layout.splitPane(arena, "A", .h, "B");
    layout = try layout.splitPane(arena, "B", .v, "C");
    try testing.expectEqualStrings(
        \\{"split":"h","ratio":0.5,"a":"A","b":{"split":"v","ratio":0.5,"a":"B","b":"C"}}
    , try layoutJson(arena, layout));

    var panes: std.ArrayList([]const u8) = .empty;
    try layout.panes(arena, &panes);
    try testing.expectEqual(@as(usize, 3), panes.items.len);
    try testing.expectEqualStrings("C", panes.items[2]);

    layout = layout.without("B").?;
    try testing.expectEqualStrings(
        \\{"split":"h","ratio":0.5,"a":"A","b":"C"}
    , try layoutJson(arena, layout));
    layout = layout.without("A").?;
    try testing.expectEqualStrings("\"C\"", try layoutJson(arena, layout));
    try testing.expect(layout.without("C") == null);
}

test "a workspace round-trips through JSON" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\{"id":"w1","name":"proj","cwd":"/src/proj","tabs":[{"id":"t1","name":"1","layout":{"split":"v","ratio":0.25,"a":"A","b":"B"}}]}
    ;
    const ws = try Workspace.fromJson(arena, try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}));
    try testing.expectEqualStrings(text, try std.json.Stringify.valueAlloc(arena, ws, .{}));
}

test "removing a tab's last pane removes the tab" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ws: Workspace = .{ .id = "w", .name = "", .cwd = "", .tabs = .empty };
    try ws.tabs.append(arena, .{ .id = "t1", .name = "1", .layout = .{ .pane = "A" } });
    try ws.tabs.append(arena, .{ .id = "t2", .name = "2", .layout = .{ .pane = "B" } });
    ws.removePane("A");
    try testing.expectEqual(@as(usize, 1), ws.tabs.items.len);
    try testing.expectEqualStrings("t2", ws.tabs.items[0].id);
}

test "resize sets the split between two panes, from the first one's side" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const layout = try testLayout(arena,
        \\{"split":"h","ratio":0.5,"a":{"split":"h","ratio":0.5,"a":"A","b":"B"},"b":{"split":"v","ratio":0.5,"a":"C","b":"D"}}
    );
    try testing.expect(layout.resize("B", "C", 0.25));
    try testing.expect(layout.resize("D", "C", 0.75));
    try testing.expect(layout.resize("A", "B", 0.6));
    try testing.expectEqualStrings(
        \\{"split":"h","ratio":0.25,"a":{"split":"h","ratio":0.6,"a":"A","b":"B"},"b":{"split":"v","ratio":0.25,"a":"C","b":"D"}}
    , try layoutJson(arena, layout));
    try testing.expect(!layout.resize("A", "A", 0.5));
    try testing.expect(!layout.resize("A", "X", 0.5));
}

test "workspaces sort by the order file, the rest after it oldest first" {
    var workspaces = [_]Workspace{
        .{ .id = "3", .name = "", .cwd = "", .tabs = .empty },
        .{ .id = "1", .name = "", .cwd = "", .tabs = .empty },
        .{ .id = "4", .name = "", .cwd = "", .tabs = .empty },
        .{ .id = "2", .name = "", .cwd = "", .tabs = .empty },
    };
    // "9" is gone
    sortWorkspaces(&workspaces, &.{ "4", "9", "2" });
    var ids: [4][]const u8 = undefined;
    for (workspaces, 0..) |ws, i| ids[i] = ws.id;
    try testing.expectEqualDeep([_][]const u8{ "4", "2", "1", "3" }, ids);

    sortWorkspaces(&workspaces, &.{});
    for (workspaces, 0..) |ws, i| ids[i] = ws.id;
    try testing.expectEqualDeep([_][]const u8{ "1", "2", "3", "4" }, ids);
}
