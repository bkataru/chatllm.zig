const std = @import("std");
const Allocator = std.mem.Allocator;

/// Shared configuration for all CLI commands
pub const Config = struct {
    model_path: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    threads: ?u32 = null,
    context_size: u32 = 4096,
    temperature: f32 = 0.7,
    top_p: f32 = 0.9,
    top_k: u32 = 40,
    repeat_penalty: f32 = 1.1,
    max_tokens: i32 = -1, // unlimited
    quiet: bool = false,
    show_stats: bool = false,

    /// Convert config to CLI params for chatllm
    pub fn toParams(self: Config, allocator: Allocator) ![][]const u8 {
        var params = std.ArrayList([]const u8).init(allocator);
        errdefer {
            for (params.items) |item| {
                allocator.free(item);
            }
            params.deinit();
        }

        if (self.model_path) |path| {
            try params.append(try allocator.dupe(u8, "-m"));
            try params.append(try allocator.dupe(u8, path));
        }

        if (self.system_prompt) |prompt| {
            try params.append(try allocator.dupe(u8, "--system"));
            try params.append(try allocator.dupe(u8, prompt));
        }

        if (self.threads) |t| {
            try params.append(try allocator.dupe(u8, "-t"));
            try params.append(try std.fmt.allocPrint(allocator, "{d}", .{t}));
        }

        if (self.context_size != 4096) {
            try params.append(try allocator.dupe(u8, "-c"));
            try params.append(try std.fmt.allocPrint(allocator, "{d}", .{self.context_size}));
        }

        if (self.temperature != 0.7) {
            try params.append(try allocator.dupe(u8, "--temp"));
            try params.append(try std.fmt.allocPrint(allocator, "{d:.2}", .{self.temperature}));
        }

        if (self.top_p != 0.9) {
            try params.append(try allocator.dupe(u8, "--top-p"));
            try params.append(try std.fmt.allocPrint(allocator, "{d:.2}", .{self.top_p}));
        }

        if (self.top_k != 40) {
            try params.append(try allocator.dupe(u8, "--top-k"));
            try params.append(try std.fmt.allocPrint(allocator, "{d}", .{self.top_k}));
        }

        if (self.repeat_penalty != 1.1) {
            try params.append(try allocator.dupe(u8, "--repeat-penalty"));
            try params.append(try std.fmt.allocPrint(allocator, "{d:.2}", .{self.repeat_penalty}));
        }

        if (self.max_tokens != -1) {
            try params.append(try allocator.dupe(u8, "-n"));
            try params.append(try std.fmt.allocPrint(allocator, "{d}", .{self.max_tokens}));
        }

        if (self.quiet) {
            try params.append(try allocator.dupe(u8, "--quiet"));
        }

        if (self.show_stats) {
            try params.append(try allocator.dupe(u8, "--stats"));
        }

        return params.toOwnedSlice();
    }

    /// Free params allocated by toParams
    pub fn freeParams(allocator: Allocator, params: [][]const u8) void {
        for (params) |param| {
            allocator.free(param);
        }
        allocator.free(params);
    }
};

/// ANSI color codes for terminal output
pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const green = "\x1b[32m";
    pub const cyan = "\x1b[36m";
    pub const yellow = "\x1b[33m";
    pub const red = "\x1b[31m";
    pub const magenta = "\x1b[35m";
};

/// Print error message in red
pub fn printError(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.red ++ "error: " ++ Color.reset ++ fmt ++ "\n", args);
}

/// Print info message in cyan
pub fn printInfo(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.cyan ++ fmt ++ Color.reset ++ "\n", args);
}

/// Print success message in green
pub fn printSuccess(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(Color.green ++ fmt ++ Color.reset ++ "\n", args);
}

/// Get the models directory path
/// Returns ~/.chatllm/models on Unix or %APPDATA%/chatllm/models on Windows
pub fn getModelsDir(allocator: Allocator) ![]const u8 {
    const config_dir = try getConfigDir(allocator);
    defer allocator.free(config_dir);
    return std.fs.path.join(allocator, &.{ config_dir, "models" });
}

/// Get the config directory path
/// Returns ~/.chatllm on Unix or %APPDATA%/chatllm on Windows
pub fn getConfigDir(allocator: Allocator) ![]const u8 {
    if (@import("builtin").os.tag == .windows) {
        // Windows: use %APPDATA%
        const appdata = std.process.getEnvVarOwned(allocator, "APPDATA") catch |err| {
            if (err == error.EnvironmentVariableNotFound) {
                // Fallback to USERPROFILE
                const userprofile = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
                defer allocator.free(userprofile);
                return std.fs.path.join(allocator, &.{ userprofile, "AppData", "Roaming", "chatllm" });
            }
            return err;
        };
        defer allocator.free(appdata);
        return std.fs.path.join(allocator, &.{ appdata, "chatllm" });
    } else {
        // Unix: use ~/.chatllm
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| {
            if (err == error.EnvironmentVariableNotFound) {
                return error.HomeNotFound;
            }
            return err;
        };
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".chatllm" });
    }
}

/// Ensure the config and models directories exist
pub fn ensureConfigDirs(allocator: Allocator) !void {
    const config_dir = try getConfigDir(allocator);
    defer allocator.free(config_dir);

    const models_dir = try getModelsDir(allocator);
    defer allocator.free(models_dir);

    std.fs.makeDirAbsolute(config_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    std.fs.makeDirAbsolute(models_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

test "Config.toParams with defaults" {
    const allocator = std.testing.allocator;
    const config = Config{};
    const params = try config.toParams(allocator);
    defer Config.freeParams(allocator, params);

    try std.testing.expectEqual(@as(usize, 0), params.len);
}

test "Config.toParams with custom values" {
    const allocator = std.testing.allocator;
    const config = Config{
        .model_path = "/path/to/model.gguf",
        .threads = 8,
        .temperature = 0.5,
        .quiet = true,
    };
    const params = try config.toParams(allocator);
    defer Config.freeParams(allocator, params);

    // Should have: -m, path, -t, 8, --temp, 0.50, --quiet
    try std.testing.expectEqual(@as(usize, 7), params.len);
}
