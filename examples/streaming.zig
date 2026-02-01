//! Streaming example: Token-by-token output with callbacks
//!
//! This example demonstrates advanced callback usage for streaming,
//! including handling different output types and building a custom UI.

const std = @import("std");
const chatllm = @import("chatllm");

const Allocator = std.mem.Allocator;

/// ANSI escape codes for terminal formatting
const Ansi = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const green = "\x1b[32m";
    const cyan = "\x1b[36m";
    const yellow = "\x1b[33m";
    const red = "\x1b[31m";
    const magenta = "\x1b[35m";
};

/// Advanced streaming context with statistics
const StreamContext = struct {
    allocator: Allocator,

    // Accumulated response
    response: std.ArrayList(u8),

    // Statistics
    token_count: usize = 0,
    start_time: i64 = 0,

    // State
    in_thought: bool = false,
    done: bool = false,

    pub fn init(allocator: Allocator) StreamContext {
        return .{
            .allocator = allocator,
            .response = std.ArrayList(u8).init(allocator),
            .start_time = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *StreamContext) void {
        self.response.deinit();
    }

    pub fn onPrint(self: *StreamContext, print_type: chatllm.PrintType, text: []const u8) void {
        switch (print_type) {
            .chat_chunk => {
                // Regular chat output - stream to terminal
                std.debug.print("{s}", .{text});
                self.response.appendSlice(text) catch {};
                self.token_count += 1;
            },

            .thought_chunk => {
                // Model's internal reasoning (for thinking models)
                if (!self.in_thought) {
                    std.debug.print("\n{s}[thinking...]{s}\n", .{ Ansi.dim, Ansi.reset });
                    self.in_thought = true;
                }
                std.debug.print("{s}{s}{s}", .{ Ansi.dim, text, Ansi.reset });
            },

            .evt_thought_completed => {
                if (self.in_thought) {
                    std.debug.print("\n{s}[/thinking]{s}\n\n", .{ Ansi.dim, Ansi.reset });
                    self.in_thought = false;
                }
            },

            .meta => {
                // Model metadata/info
                std.debug.print("{s}[meta]{s} {s}\n", .{ Ansi.cyan, Ansi.reset, text });
            },

            .@"error" => {
                // Error messages
                std.debug.print("{s}[error]{s} {s}\n", .{ Ansi.red, Ansi.reset, text });
            },

            .tool_calling => {
                // Tool/function calls
                std.debug.print("{s}[tool]{s} {s}\n", .{ Ansi.yellow, Ansi.reset, text });
            },

            .ref => {
                // References/citations
                std.debug.print("{s}[ref]{s} {s}\n", .{ Ansi.magenta, Ansi.reset, text });
            },

            .model_info => {
                // Model info JSON
                std.debug.print("{s}[model]{s} {s}\n", .{ Ansi.green, Ansi.reset, text });
            },

            .logging => {
                // Internal logging (usually hidden)
                // std.debug.print("{s}[log]{s} {s}\n", .{ Ansi.dim, Ansi.reset, text });
            },

            else => {
                // Unknown types - log for debugging
                std.debug.print("[type={d}] {s}\n", .{ @intFromEnum(print_type), text });
            },
        }
    }

    pub fn onEnd(self: *StreamContext) void {
        self.done = true;
        self.in_thought = false;

        const elapsed_ms = std.time.milliTimestamp() - self.start_time;
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
        const tokens_per_sec = if (elapsed_sec > 0)
            @as(f64, @floatFromInt(self.token_count)) / elapsed_sec
        else
            0;

        std.debug.print("\n\n{s}--- Statistics ---{s}\n", .{ Ansi.dim, Ansi.reset });
        std.debug.print("Tokens: {d}\n", .{self.token_count});
        std.debug.print("Time: {d:.2}s\n", .{elapsed_sec});
        std.debug.print("Speed: {d:.1} tokens/sec\n", .{tokens_per_sec});
        std.debug.print("Response length: {d} chars\n", .{self.response.items.len});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize
    if (!chatllm.ChatLLM.globalInit()) {
        return error.InitFailed;
    }

    var llm = try chatllm.ChatLLM.init(allocator);
    defer llm.deinit();

    // Configure
    try llm.appendParam("-m");
    try llm.appendParam("path/to/your/model.bin");

    // Optional: Limit tokens for demo
    llm.setGenMaxTokens(100);

    var ctx = StreamContext.init(allocator);
    defer ctx.deinit();

    var callback = chatllm.CallbackContext(*StreamContext){
        .user_data = &ctx,
        .print_fn = StreamContext.onPrint,
        .end_fn = StreamContext.onEnd,
    };

    std.debug.print("Loading model...\n\n", .{});
    try llm.startWithContext(*StreamContext, &callback);

    std.debug.print("{s}User:{s} Write a haiku about programming.\n\n", .{ Ansi.green, Ansi.reset });
    std.debug.print("{s}Assistant:{s} ", .{ Ansi.cyan, Ansi.reset });

    try llm.userInput("Write a haiku about programming.");

    std.debug.print("\n{s}Streaming complete!{s}\n", .{ Ansi.bold, Ansi.reset });
}
