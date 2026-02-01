const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn run(allocator: Allocator, args: []const []const u8) !void {
    _ = allocator;

    var model: ?[]const u8 = null;
    var port: u16 = 8080;
    var host: []const u8 = "127.0.0.1";
    var show_help = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i < args.len) {
                model = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i < args.len) {
                port = std.fmt.parseInt(u16, args[i], 10) catch 8080;
            }
        } else if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i < args.len) {
                host = args[i];
            }
        }
    }

    if (show_help) {
        std.debug.print(
            \\Usage: chatllm serve [OPTIONS]
            \\
            \\Start an HTTP server for model inference.
            \\
            \\Options:
            \\  -m, --model <MODEL>    Model to serve
            \\  -p, --port <PORT>      Port to listen on (default: 8080)
            \\      --host <HOST>      Host to bind to (default: 127.0.0.1)
            \\  -h, --help             Show this help message
            \\
            \\Example:
            \\  chatllm serve -m llama3.1:8b -p 8080
            \\
        , .{});
        return;
    }

    std.debug.print(
        \\HTTP server not yet implemented. Coming in Phase 3.
        \\
        \\Planned configuration:
        \\  Host:  {s}
        \\  Port:  {d}
        \\  Model: {s}
        \\
        \\The server will support:
        \\  - OpenAI API (/v1/chat/completions, /v1/completions)
        \\  - Ollama API (/api/generate, /api/chat)
        \\  - llama.cpp API (/completion, /tokenize)
        \\
    , .{
        host,
        port,
        model orelse "(none specified)",
    });
}
