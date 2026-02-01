const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn run(allocator: Allocator, args: []const []const u8) !void {
    _ = allocator;

    var model_name: ?[]const u8 = null;
    var registry: []const u8 = "modelscope";
    var show_help = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--registry")) {
            i += 1;
            if (i < args.len) {
                registry = args[i];
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            model_name = arg;
        }
    }

    if (show_help) {
        std.debug.print(
            \\Usage: chatllm pull [OPTIONS] <MODEL>
            \\
            \\Download a model from a registry.
            \\
            \\Arguments:
            \\  <MODEL>                Model name (e.g., llama3.1:8b:q8)
            \\
            \\Options:
            \\      --registry <NAME>  Model registry (default: modelscope)
            \\  -h, --help             Show this help message
            \\
            \\Examples:
            \\  chatllm pull llama3.1:8b:q8
            \\  chatllm pull --registry huggingface mistral:7b
            \\
        , .{});
        return;
    }

    if (model_name == null) {
        std.debug.print(
            \\Error: No model specified.
            \\
            \\Usage: chatllm pull llama3.1:8b:q8
            \\
            \\Run 'chatllm pull --help' for more information.
            \\
        , .{});
        return;
    }

    std.debug.print(
        \\Model download not yet implemented. Coming in Phase 4.
        \\
        \\Requested:
        \\  Model:    {s}
        \\  Registry: {s}
        \\
        \\Example usage:
        \\  chatllm pull llama3.1:8b:q8
        \\
    , .{
        model_name.?,
        registry,
    });
}
