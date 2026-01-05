const std = @import("std");
const posix = std.posix;

/// Shell types we support
pub const ShellType = enum {
    bash,
    zsh,
    fish,
    unknown,
};

/// Embedded shell integration scripts
pub const bash_integration =
    \\# Clauntty Shell Integration for Bash (embedded in rtach)
    \\# Sets terminal title to show current directory and running command
    \\[[ "$-" != *i* ]] && return
    \\[[ -n "$CLAUNTTY_SHELL_INTEGRATION" ]] && return
    \\export CLAUNTTY_SHELL_INTEGRATION=1
    \\
    \\# Set title before prompt (shows current directory)
    \\__clauntty_prompt() {
    \\    printf '\033]0;%s\007' "${PWD/#$HOME/~}"
    \\}
    \\PROMPT_COMMAND="__clauntty_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
    \\
    \\# Set title before command runs (shows the command)
    \\__clauntty_preexec() {
    \\    # Skip internal commands (prompts, completions)
    \\    [[ "$1" == __clauntty_* ]] && return
    \\    [[ "$1" == _* ]] && return
    \\    printf '\033]0;%s\007' "$1"
    \\}
    \\trap '__clauntty_preexec "$BASH_COMMAND"' DEBUG
    \\
;

pub const zsh_integration =
    \\# Clauntty Shell Integration for Zsh (embedded in rtach)
    \\# Sets terminal title to show current directory and running command
    \\[[ -o interactive ]] || return
    \\[[ -n "$CLAUNTTY_SHELL_INTEGRATION" ]] && return
    \\export CLAUNTTY_SHELL_INTEGRATION=1
    \\
    \\# Set title before prompt (shows current directory)
    \\__clauntty_precmd() {
    \\    print -Pn '\033]0;%~\007'
    \\}
    \\precmd_functions+=(__clauntty_precmd)
    \\
    \\# Set title before command runs (shows the command)
    \\__clauntty_preexec() {
    \\    print -Pn '\033]0;%~: '"${1}\007"
    \\}
    \\preexec_functions+=(__clauntty_preexec)
    \\
;

pub const fish_integration =
    \\# Clauntty Shell Integration for Fish (embedded in rtach)
    \\# Sets terminal title to show current directory and running command
    \\status is-interactive; or exit
    \\set -q CLAUNTTY_SHELL_INTEGRATION; and exit
    \\set -gx CLAUNTTY_SHELL_INTEGRATION 1
    \\
    \\# Set title to current directory (fish_title is called automatically)
    \\function fish_title
    \\    if set -q argv[1]
    \\        echo (prompt_pwd): $argv[1]
    \\    else
    \\        prompt_pwd
    \\    end
    \\end
    \\
;

/// Detect shell type from command path
pub fn detectShellType(command: []const u8) ShellType {
    // Get basename
    const basename = blk: {
        if (std.mem.lastIndexOf(u8, command, "/")) |idx| {
            break :blk command[idx + 1 ..];
        }
        break :blk command;
    };

    if (std.mem.eql(u8, basename, "bash")) return .bash;
    if (std.mem.eql(u8, basename, "zsh")) return .zsh;
    if (std.mem.eql(u8, basename, "fish")) return .fish;

    // Check for common variations
    if (std.mem.startsWith(u8, basename, "bash")) return .bash;
    if (std.mem.startsWith(u8, basename, "zsh")) return .zsh;
    if (std.mem.startsWith(u8, basename, "fish")) return .fish;

    return .unknown;
}

/// Get the appropriate integration script for a shell type
pub fn getIntegrationScript(shell_type: ShellType) ?[]const u8 {
    return switch (shell_type) {
        .bash => bash_integration,
        .zsh => zsh_integration,
        .fish => fish_integration,
        .unknown => null,
    };
}

/// Write shell integration files to ~/.clauntty/shell-integration/
/// Returns true if successful
pub fn deployIntegrationFiles() !void {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    // Create directory
    var path_buf: [512]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&path_buf, "{s}/.clauntty/shell-integration", .{home});

    std.fs.makeDirAbsolute(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Write each integration file
    const files = [_]struct { name: []const u8, content: []const u8 }{
        .{ .name = "clauntty.bash", .content = bash_integration },
        .{ .name = "clauntty.zsh", .content = zsh_integration },
        .{ .name = "clauntty.fish", .content = fish_integration },
    };

    for (files) |file| {
        var file_path_buf: [512]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}/{s}", .{ dir_path, file.name });

        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();
        try f.writeAll(file.content);
    }

    // Also write wrapper rcfiles that source user config + our integration

    // Bash wrapper
    {
        var file_path_buf: [512]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}/bashrc", .{dir_path});
        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();

        var content_buf: [1024]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buf,
            \\# Clauntty bashrc wrapper - sources user config then integration
            \\[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
            \\[ -f ~/.bashrc ] && . ~/.bashrc
            \\. {s}/.clauntty/shell-integration/clauntty.bash
            \\
        , .{home});
        try f.writeAll(content);
    }

    // Zsh wrapper (zprofile in ZDOTDIR)
    {
        var file_path_buf: [512]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}/.zprofile", .{dir_path});
        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();

        var content_buf: [1024]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buf,
            \\# Clauntty zprofile wrapper - sources user config
            \\[ -f ~/.zprofile ] && . ~/.zprofile
            \\
        , .{});
        try f.writeAll(content);
    }

    // Zsh wrapper (zshrc in ZDOTDIR)
    {
        var file_path_buf: [512]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}/.zshrc", .{dir_path});
        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();

        var content_buf: [1024]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buf,
            \\# Clauntty zshrc wrapper - sources user config then integration
            \\[ -f /etc/zsh/zshrc ] && . /etc/zsh/zshrc
            \\[ -f ~/.zshrc ] && . ~/.zshrc
            \\. {s}/.clauntty/shell-integration/clauntty.zsh
            \\
        , .{home});
        try f.writeAll(content);
    }

}

/// Build argv for shell with integration
/// For bash: use --rcfile to load our wrapper
/// For zsh: use ZDOTDIR environment
/// For fish: use --init-command
/// Returns the modified command and any extra environment needed
pub const ShellSetup = struct {
    /// Modified argv (null-terminated)
    argv: [8:null]?[*:0]const u8,
    argc: usize,
    /// Extra environment variable to set (e.g., ZDOTDIR=...)
    env_name: ?[*:0]const u8 = null,
    env_value: ?[*:0]const u8 = null,
};

/// Prepare shell arguments with integration
/// Caller must ensure shell_path is null-terminated
pub fn prepareShellArgs(
    allocator: std.mem.Allocator,
    shell_path: [*:0]const u8,
    shell_type: ShellType,
) !ShellSetup {
    _ = allocator; // Not needed for now since we use static buffers

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    var setup = ShellSetup{
        .argv = .{ null, null, null, null, null, null, null, null },
        .argc = 0,
    };

    // Static buffers for paths (persists for exec)
    const S = struct {
        var rcfile_path: [512:0]u8 = undefined;
        var zdotdir_name: [8:0]u8 = undefined;
        var zdotdir_value: [512:0]u8 = undefined;
        var init_cmd: [1024:0]u8 = undefined;
        var rcfile_arg: [10:0]u8 = undefined;
        var init_cmd_arg: [16:0]u8 = undefined;
        var login_arg: [3:0]u8 = undefined;
    };

    switch (shell_type) {
        .bash => {
            // bash --rcfile ~/.clauntty/shell-integration/bashrc
            const path = std.fmt.bufPrintZ(&S.rcfile_path, "{s}/.clauntty/shell-integration/bashrc", .{home}) catch return error.PathTooLong;
            _ = std.fmt.bufPrintZ(&S.rcfile_arg, "--rcfile", .{}) catch unreachable;

            setup.argv[0] = shell_path;
            setup.argv[1] = &S.rcfile_arg;
            setup.argv[2] = path.ptr;
            setup.argc = 3;
        },
        .zsh => {
            // For zsh, set ZDOTDIR to our integration directory and run as login shell
            _ = std.fmt.bufPrintZ(&S.zdotdir_name, "ZDOTDIR", .{}) catch unreachable;
            const zdotdir = std.fmt.bufPrintZ(&S.zdotdir_value, "{s}/.clauntty/shell-integration", .{home}) catch return error.PathTooLong;
            _ = std.fmt.bufPrintZ(&S.login_arg, "-l", .{}) catch unreachable;

            setup.argv[0] = shell_path;
            setup.argv[1] = &S.login_arg;
            setup.argc = 2;
            setup.env_name = &S.zdotdir_name;
            setup.env_value = zdotdir.ptr;
        },
        .fish => {
            // fish --init-command "source ~/.clauntty/shell-integration/clauntty.fish"
            const cmd = std.fmt.bufPrintZ(&S.init_cmd, "source {s}/.clauntty/shell-integration/clauntty.fish", .{home}) catch return error.PathTooLong;
            _ = std.fmt.bufPrintZ(&S.init_cmd_arg, "--init-command", .{}) catch unreachable;

            setup.argv[0] = shell_path;
            setup.argv[1] = &S.init_cmd_arg;
            setup.argv[2] = cmd.ptr;
            setup.argc = 3;
        },
        .unknown => {
            // Unknown shell - just run it directly
            setup.argv[0] = shell_path;
            setup.argc = 1;
        },
    }

    return setup;
}
