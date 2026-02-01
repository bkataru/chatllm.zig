const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;

pub fn run(allocator: Allocator, args: []const []const u8) !void {
    var list_remote = false;
    var list_local = true;
    var show_help = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--remote")) {
            list_remote = true;
            list_local = false;
        } else if (std.mem.eql(u8, arg, "--local")) {
            list_local = true;
            list_remote = false;
        }
    }

    if (show_help) {
        std.debug.print(
            \\Usage: chatllm list [OPTIONS]
            \\
            \\List available models.
            \\
            \\Options:
            \\      --local            List downloaded models (default)
            \\      --remote           List models available for download
            \\  -h, --help             Show this help message
            \\
            \\Examples:
            \\  chatllm list
            \\  chatllm list --local
            \\  chatllm list --remote
            \\
        , .{});
        return;
    }

    if (list_remote) {
        std.debug.print(
            \\Remote model listing not yet implemented. Coming in Phase 4.
            \\
            \\This will list models available for download from:
            \\  - ModelScope
            \\  - Hugging Face
            \\  - Ollama Registry
            \\
        , .{});
        return;
    }

    if (list_local) {
        try listLocalModels(allocator);
    }
}

fn listLocalModels(allocator: Allocator) !void {
    // Get home directory and construct models path
    const home = std.process.getEnvVarOwned(allocator, "USERPROFILE") catch |err| blk: {
        if (err == error.EnvironmentVariableNotFound) {
            // Try HOME for non-Windows systems
            break :blk std.process.getEnvVarOwned(allocator, "HOME") catch {
                std.debug.print("No models found.\n\nCould not determine home directory.\n", .{});
                return;
            };
        }
        return err;
    };
    defer allocator.free(home);

    const models_path = try std.fs.path.join(allocator, &.{ home, ".chatllm", "models" });
    defer allocator.free(models_path);

    // Try to open the models directory
    var dir = fs.openDirAbsolute(models_path, .{ .iterate = true }) catch {
        std.debug.print(
            \\No models found.
            \\
            \\Models directory: {s}
            \\
            \\Download models with:
            \\  chatllm pull llama3.1:8b:q8
            \\
        , .{models_path});
        return;
    };
    defer dir.close();

    std.debug.print("Downloaded models ({s}):\n\n", .{models_path});

    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file or entry.kind == .directory) {
            std.debug.print("  {s}\n", .{entry.name});
            count += 1;
        }
    }

    if (count == 0) {
        std.debug.print(
            \\  (empty)
            \\
            \\Download models with:
            \\  chatllm pull llama3.1:8b:q8
            \\
        , .{});
    } else {
        std.debug.print("\n{d} model(s) found.\n", .{count});
    }
}
