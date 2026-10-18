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
//! Every change happens under one flock on workspaces/.lock and replaces files by
//! rename, so the app and the desktop can both edit. A session in no workspace is a
//! plain tab. Removing a tab's last pane removes the tab, and a workspace's last tab
//! removes the workspace. A master that exits takes its pane out (`paneEnded`), and
//! `list` drops panes whose master doesn't answer.

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");
const cli = @import("cli.zig");

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
        // Oldest first: ids sort by creation (see newId)
        std.mem.sort(Workspace, self.workspaces.items, {}, struct {
            fn lessThan(_: void, a: Workspace, b: Workspace) bool {
                return std.mem.order(u8, a.id, b.id) == .lt;
            }
        }.lessThan);
    }

    /// Write every workspace, and delete the files of removed ones
    fn save(self: *Store) !void {
        const cwd = std.Io.Dir.cwd();
        for (self.workspaces.items) |ws| {
            const path = try std.fmt.allocPrint(self.arena, "{s}/{s}.json", .{ self.dir, ws.id });
            const tmp = try std.fmt.allocPrint(self.arena, "{s}.{d}.tmp", .{ path, std.c.getpid() });
            const data = try std.json.Stringify.valueAlloc(self.arena, ws, .{ .whitespace = .indent_2 });
            try cwd.writeFile(self.io, .{ .sub_path = tmp, .data = data, .flags = .{ .permissions = .fromMode(0o600) } });
            cwd.rename(tmp, cwd, path, self.io) catch |err| {
                cwd.deleteFile(self.io, tmp) catch {};
                return err;
            };
        }
        for (self.loaded_ids.items) |id| {
            if (self.find(id) != null) continue;
            const path = try std.fmt.allocPrint(self.arena, "{s}/{s}.json", .{ self.dir, id });
            cwd.deleteFile(self.io, path) catch {};
        }
    }

    fn find(self: *Store, id: []const u8) ?*Workspace {
        for (self.workspaces.items) |*ws| {
            if (std.mem.eql(u8, ws.id, id)) return ws;
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

/// Start a pane's master in `cwd`: this binary's `-n`, which goes through spawnd
/// where it runs
fn startPane(arena: Allocator, io: std.Io, home: []const u8, cwd: []const u8) ![]const u8 {
    const pane = try newPaneId(io, arena);
    const sessions = try std.fmt.allocPrint(arena, "{s}/.clauntty/sessions", .{home});
    try std.Io.Dir.cwd().createDirPath(io, sessions);

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = try arena.dupeZ(u8, exe_buf[0..try std.process.executablePath(io, &exe_buf)]);
    const start_in = try arena.dupeZ(u8, if (isDirectory(io, cwd)) cwd else home);
    const argv = [_:null]?[*:0]const u8{ exe, "-n", try arena.dupeZ(u8, try socketPath(arena, home, pane)) };

    // Not std.process.run: its children get the Io's environment, which is empty
    // here, and the pane needs ours (HOME, SHELL, PATH, ...)
    const pid = try sys.fork();
    if (pid == 0) {
        _ = std.c.chdir(start_in);
        sys.execveZ(exe, &argv, @ptrCast(std.c.environ));
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
    return std.mem.trim(u8, title, " \n");
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
    \\Usage: rtach ws <command> [args]
    \\
    \\Workspaces group rtach sessions (panes) into tabs with split layouts.
    \\PANE defaults to the current session ($RTACH_SESSION_ID), else the one the
    \\Clauntty app shows on this machine.
    \\
    \\Commands:
    \\  new [NAME] [--cwd DIR]      New workspace with one tab and pane. DIR defaults
    \\                              to the git root above the current directory.
    \\  tab [WS] [--name NAME]      New tab with one pane (WS: the current one)
    \\  split [PANE] [-h|-v]        New pane next to PANE (-h side by side, default;
    \\                              -v stacked)
    \\  close [PANE]                End PANE and take it out of its tab
    \\  move PANE TAB               Move PANE into TAB, next to its last pane
    \\  rename ID NAME              Rename a workspace or tab
    \\  list [--json]               Workspaces, tabs and panes
    \\
    \\Changes print the new or affected ids as JSON, and tell the Clauntty app,
    \\which shows a new pane right away (--quiet: don't).
    \\
;

const Context = struct {
    arena: Allocator,
    io: std.Io,
    home: []const u8,
    out: std.ArrayList(u8) = .empty,
    /// Don't tell the app (it ran the command itself)
    quiet: bool = false,

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
        if (self.quiet) return;
        const value = if (workspace != null and pane != null)
            std.fmt.allocPrint(self.arena, "{s}/{s}", .{ workspace.?, pane.? }) catch return
        else
            "";
        cli.notify(self.io, "workspace", value);
    }
};

/// `rtach ws <command>`
pub fn main(allocator: Allocator, io: std.Io, process_args: std.process.Args) u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args: std.ArrayList([]const u8) = .empty;
    var it = process_args.iterate();
    _ = it.skip(); // rtach
    _ = it.skip(); // ws
    var quiet = false;
    while (it.next()) |arg| {
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
    const rest = args.items[1..];

    const eql = std.mem.eql;
    const result = if (eql(u8, command, "new"))
        cmdNew(&ctx, rest)
    else if (eql(u8, command, "tab"))
        cmdTab(&ctx, rest)
    else if (eql(u8, command, "split"))
        cmdSplit(&ctx, rest)
    else if (eql(u8, command, "close"))
        cmdClose(&ctx, rest)
    else if (eql(u8, command, "move"))
        cmdMove(&ctx, rest)
    else if (eql(u8, command, "rename"))
        cmdRename(&ctx, rest)
    else if (eql(u8, command, "list") or eql(u8, command, "ls"))
        cmdList(&ctx, rest)
    else {
        fail(usage, .{});
        return 2;
    };
    result catch |err| {
        fail("rtach ws {s}: {s}\n", .{ command, errorText(err) });
        return 1;
    };
    _ = sys.write(posix.STDOUT_FILENO, ctx.out.items) catch {};
    return 0;
}

fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.NoPane => "no pane given, not inside an rtach session, and Clauntty shows none",
        error.NotInWorkspace => "that pane isn't in a workspace",
        error.NoSuchWorkspace => "no such workspace",
        error.NoSuchTab => "no such tab",
        error.NoSuchId => "no workspace or tab with that id",
        error.PaneDidntStart => "the new pane's session didn't start",
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
    dir: Dir = .h,
    json: bool = false,
};

fn parse(arena: Allocator, args: []const []const u8) !Parsed {
    var p: Parsed = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "--cwd")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            if (arg[2] == 'n') p.name = args[i] else p.cwd = args[i];
        } else if (std.mem.eql(u8, arg, "-h")) {
            p.dir = .h;
        } else if (std.mem.eql(u8, arg, "-v")) {
            p.dir = .v;
        } else if (std.mem.eql(u8, arg, "--json")) {
            p.json = true;
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
    const name = if (p.positional.items.len > 0) p.positional.items[0] else std.fs.path.basename(dir);

    // Start the pane before taking the lock: masters started by spawnd take it on exit
    const pane = try startPane(ctx.arena, ctx.io, ctx.home, dir);
    var store = try Store.open(ctx.arena, ctx.io, ctx.home);
    defer store.close();
    var ws: Workspace = .{ .id = try newId(ctx.io, ctx.arena), .name = name, .cwd = dir, .tabs = .empty };
    const tab: Tab = .{ .id = try newId(ctx.io, ctx.arena), .name = "1", .layout = .{ .pane = pane } };
    try ws.tabs.append(ctx.arena, tab);
    try store.workspaces.append(ctx.arena, ws);
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

    const pane = try startPane(ctx.arena, ctx.io, ctx.home, cwd);
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
    const cwd = (store.workspaceOf(target) orelse return error.NotInWorkspace).cwd;
    store.close();

    const pane = try startPane(ctx.arena, ctx.io, ctx.home, cwd);
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

const PaneInfo = struct {
    id: []const u8,
    title: ?[]const u8,
};

const TabInfo = struct {
    id: []const u8,
    name: []const u8,
    panes: []const PaneInfo,
    layout: Layout,
};

const WorkspaceInfo = struct {
    id: []const u8,
    name: []const u8,
    cwd: []const u8,
    tabs: []const TabInfo,
};

fn cmdList(ctx: *Context, args: []const []const u8) !void {
    const p = try parse(ctx.arena, args);
    var store = try Store.open(ctx.arena, ctx.io, ctx.home);
    defer store.close();

    // Drop panes whose master is gone (a crash, or an exit that couldn't update the file)
    var all: std.ArrayList([]const u8) = .empty;
    for (store.workspaces.items) |ws| {
        for (ws.tabs.items) |tab| try tab.layout.panes(ctx.arena, &all);
    }
    var pruned = false;
    for (all.items) |pane| {
        if (!paneAlive(ctx.arena, ctx.home, pane)) {
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
            try tab.layout.panes(ctx.arena, &ids);
            var panes: std.ArrayList(PaneInfo) = .empty;
            for (ids.items) |id| try panes.append(ctx.arena, .{ .id = id, .title = paneTitle(ctx.arena, ctx.io, ctx.home, id) });
            try tabs.append(ctx.arena, .{ .id = tab.id, .name = tab.name, .panes = panes.items, .layout = tab.layout });
        }
        try infos.append(ctx.arena, .{ .id = ws.id, .name = ws.name, .cwd = ws.cwd, .tabs = tabs.items });
    }

    if (p.json) {
        ctx.json(.{ .workspaces = infos.items });
        return;
    }
    if (infos.items.len == 0) {
        ctx.print("No workspaces. Start one with: rtach ws new\n", .{});
        return;
    }
    for (infos.items) |ws| {
        ctx.print("{s}  ({s})  {s}\n", .{ ws.name, ws.id, ws.cwd });
        for (ws.tabs) |tab| {
            ctx.print("  tab {s}  ({s})\n", .{ tab.name, tab.id });
            for (tab.panes) |pane| ctx.print("    {s}  {s}\n", .{ pane.id, pane.title orelse "" });
        }
    }
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
