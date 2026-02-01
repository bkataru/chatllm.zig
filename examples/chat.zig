//! Chat example: Multi-turn conversation
//!
//! This example demonstrates how to have a multi-turn conversation
//! with context preservation between turns.

const std = @import("std");
const chatllm = @import("chatllm");

const Allocator = std.mem.Allocator;

/// Chat context that accumulates responses
const ChatContext = struct {
    allocator: Allocator,
    response: std.ArrayList(u8),
    done: bool = false,

    pub fn init(allocator: Allocator) ChatContext {
        return .{
            .allocator = allocator,
            .response = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *ChatContext) void {
        self.response.deinit();
    }

    pub fn reset(self: *ChatContext) void {
        self.response.clearRetainingCapacity();
        self.done = false;
    }

    pub fn onPrint(self: *ChatContext, print_type: chatllm.PrintType, text: []const u8) void {
        if (print_type == .chat_chunk) {
            std.debug.print("{s}", .{text});
            self.response.appendSlice(text) catch {};
        }
    }

    pub fn onEnd(self: *ChatContext) void {
        self.done = true;
        std.debug.print("\n\n", .{});
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

    // Configure model
    try llm.appendParam("-m");
    try llm.appendParam("path/to/your/model.bin");

    // Set a system prompt
    try llm.appendParam("-s");
    try llm.appendParam("You are a helpful assistant. Be concise.");

    // Set up callbacks
    var ctx = ChatContext.init(allocator);
    defer ctx.deinit();

    var callback = chatllm.CallbackContext(*ChatContext){
        .user_data = &ctx,
        .print_fn = ChatContext.onPrint,
        .end_fn = ChatContext.onEnd,
    };

    std.debug.print("Loading model...\n", .{});
    try llm.startWithContext(*ChatContext, &callback);

    // Multi-turn conversation
    const prompts = [_][]const u8{
        "What is machine learning?",
        "Can you give me a simple example?",
        "How is that different from traditional programming?",
    };

    for (prompts, 1..) |prompt, turn| {
        std.debug.print("--- Turn {d} ---\n", .{turn});
        std.debug.print("User: {s}\n", .{prompt});
        std.debug.print("Assistant: ", .{});

        ctx.reset();
        try llm.userInput(prompt);

        // The model remembers previous turns automatically
    }

    // Optional: Clear history and start fresh
    std.debug.print("--- Clearing history ---\n", .{});
    try llm.restart(null);

    std.debug.print("User: What were we talking about?\n", .{});
    std.debug.print("Assistant: ", .{});
    ctx.reset();
    try llm.userInput("What were we talking about?");

    std.debug.print("Conversation complete!\n", .{});
}
