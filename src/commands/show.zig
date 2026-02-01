//! Show Command - Display information about a downloaded model
//!
//! Shows metadata from the model file header including architecture,
//! parameters, context length, and quantization details.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const config = @import("../config.zig");

pub fn run(allocator: Allocator, args: []const []const u8) !void {
    var model_name: ?[]const u8 = null;
    var show_help = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            model_name = arg;
        }
    }

    if (show_help) {
        std.debug.print(
            \\Usage: chatllm show <MODEL>
            \\
            \\Display information about a downloaded model.
            \\
            \\Arguments:
            \\  <MODEL>    Model name or path
            \\
            \\Options:
            \\  -h, --help    Show this help message
            \\
            \\Examples:
            \\  chatllm show llama3.1-8b.bin
            \\  chatllm show ~/.chatllm/models/qwen3-1.7b.bin
            \\
        , .{});
        return;
    }

    if (model_name == null) {
        config.printError("Model name is required.", .{});
        std.debug.print("\nUsage: chatllm show <MODEL>\n", .{});
        return;
    }

    // Try to find the model file
    const model_path = try resolveModelPath(allocator, model_name.?);
    defer if (model_path.allocated) allocator.free(model_path.path);

    if (model_path.path.len == 0) {
        config.printError("Model not found: {s}", .{model_name.?});
        return;
    }

    // Get file info
    const stat = fs.cwd().statFile(model_path.path) catch |err| {
        config.printError("Cannot access model file: {}", .{err});
        return;
    };

    std.debug.print("\nModel: {s}\n", .{model_name.?});
    std.debug.print("Path:  {s}\n", .{model_path.path});
    std.debug.print("Size:  {s}\n", .{formatSize(stat.size)});

    // Try to read model header for more info
    readModelHeader(model_path.path) catch {
        std.debug.print("\n(Could not read model metadata)\n", .{});
    };
}

const ResolvedPath = struct {
    path: []const u8,
    allocated: bool,
};

fn resolveModelPath(allocator: Allocator, name: []const u8) !ResolvedPath {
    // If it's an absolute path or relative path that exists, use it directly
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
    // Use a static buffer for simple formatting
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

fn readModelHeader(path: []const u8) !void {
    var file = try fs.cwd().openFile(path, .{});
    defer file.close();

    // Read magic number
    var magic: [4]u8 = undefined;
    _ = try file.read(&magic);

    // Check for common model formats
    if (std.mem.eql(u8, &magic, "GGUF")) {
        std.debug.print("Format: GGUF\n", .{});
        // Could parse GGUF header here for more details
    } else if (std.mem.eql(u8, &magic, "GGML")) {
        std.debug.print("Format: GGML (legacy)\n", .{});
    } else if (std.mem.eql(u8, magic[0..2], "lm")) {
        std.debug.print("Format: chatllm.cpp binary\n", .{});
    } else {
        std.debug.print("Format: Unknown (magic: 0x{x:0>2}{x:0>2}{x:0>2}{x:0>2})\n", .{ magic[0], magic[1], magic[2], magic[3] });
    }
}
