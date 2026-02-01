//! Remove Command - Delete a downloaded model
//!
//! Removes model files from the local models directory.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const File = std.fs.File;
const config = @import("../config.zig");

pub fn run(allocator: Allocator, args: []const []const u8) !void {
    var model_name: ?[]const u8 = null;
    var show_help = false;
    var force = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            model_name = arg;
        }
    }

    if (show_help) {
        std.debug.print(
            \\Usage: chatllm rm <MODEL>
            \\
            \\Remove a downloaded model.
            \\
            \\Arguments:
            \\  <MODEL>       Model name or filename
            \\
            \\Options:
            \\  -f, --force   Don't prompt for confirmation
            \\  -h, --help    Show this help message
            \\
            \\Examples:
            \\  chatllm rm llama3.1-8b.bin
            \\  chatllm rm qwen3-1.7b.bin --force
            \\
        , .{});
        return;
    }

    if (model_name == null) {
        config.printError("Model name is required.", .{});
        std.debug.print("\nUsage: chatllm rm <MODEL>\n", .{});
        return;
    }

    // Resolve model path
    const model_path = try resolveModelPath(allocator, model_name.?);
    defer if (model_path.allocated) allocator.free(model_path.path);

    if (model_path.path.len == 0) {
        config.printError("Model not found: {s}", .{model_name.?});
        return;
    }

    // Get file info for display
    const stat = fs.cwd().statFile(model_path.path) catch |err| {
        config.printError("Cannot access model file: {}", .{err});
        return;
    };

    // Confirm deletion unless --force
    if (!force) {
        std.debug.print("Remove model: {s}\n", .{model_path.path});
        std.debug.print("Size: {s}\n", .{formatSize(stat.size)});
        std.debug.print("\nAre you sure? [y/N] ", .{});

        // Read confirmation using buffered reader
        var stdin_buf: [64]u8 = undefined;
        var stdin_reader = File.stdin().reader(&stdin_buf);
        const line = stdin_reader.interface.takeDelimiterInclusive('\n') catch {
            std.debug.print("Aborted.\n", .{});
            return;
        };

        const response = std.mem.trim(u8, line, " \t\r\n");
        if (!std.mem.eql(u8, response, "y") and !std.mem.eql(u8, response, "Y") and !std.mem.eql(u8, response, "yes")) {
            std.debug.print("Aborted.\n", .{});
            return;
        }
    }

    // Delete the file
    fs.cwd().deleteFile(model_path.path) catch |err| {
        config.printError("Failed to delete model: {}", .{err});
        return;
    };

    config.printSuccess("Removed: {s}", .{model_path.path});
}

const ResolvedPath = struct {
    path: []const u8,
    allocated: bool,
};

fn resolveModelPath(allocator: Allocator, name: []const u8) !ResolvedPath {
    // If it's an absolute path, use it directly
    if (std.fs.path.isAbsolute(name)) {
        return .{ .path = name, .allocated = false };
    }

    // Check if it exists in current directory
    if (fs.cwd().statFile(name)) |_| {
        return .{ .path = name, .allocated = false };
    } else |_| {}

    // Check in models directory
    const models_dir = config.getModelsDir(allocator) catch {
        return .{ .path = "", .allocated = false };
    };
    defer allocator.free(models_dir);

    // Try exact name
    var path = try std.fs.path.join(allocator, &.{ models_dir, name });
    if (fs.cwd().statFile(path)) |_| {
        return .{ .path = path, .allocated = true };
    } else |_| {
        allocator.free(path);
    }

    // Try with .bin extension
    const with_bin = try std.mem.concat(allocator, u8, &.{ name, ".bin" });
    defer allocator.free(with_bin);

    path = try std.fs.path.join(allocator, &.{ models_dir, with_bin });
    if (fs.cwd().statFile(path)) |_| {
        return .{ .path = path, .allocated = true };
    } else |_| {
        allocator.free(path);
    }

    return .{ .path = "", .allocated = false };
}

fn formatSize(size: u64) []const u8 {
    const Static = struct {
        var buf: [32]u8 = undefined;
    };

    if (size >= 1024 * 1024 * 1024) {
        const gb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0 * 1024.0);
        return std.fmt.bufPrint(&Static.buf, "{d:.2} GB", .{gb}) catch "? GB";
    } else if (size >= 1024 * 1024) {
        const mb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(&Static.buf, "{d:.2} MB", .{mb}) catch "? MB";
    } else if (size >= 1024) {
        const kb = @as(f64, @floatFromInt(size)) / 1024.0;
        return std.fmt.bufPrint(&Static.buf, "{d:.2} KB", .{kb}) catch "? KB";
    } else {
        return std.fmt.bufPrint(&Static.buf, "{d} B", .{size}) catch "? B";
    }
}
