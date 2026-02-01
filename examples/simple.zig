//! Simple example: Basic single-prompt inference
//!
//! This example demonstrates the most basic usage of chatllm.zig:
//! loading a model and generating a response to a single prompt.

const std = @import("std");
const chatllm = @import("chatllm");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize the library globally (call once)
    if (!chatllm.ChatLLM.globalInit()) {
        std.debug.print("Failed to initialize chatllm\n", .{});
        return error.InitFailed;
    }

    // Create a ChatLLM instance
    var llm = try chatllm.ChatLLM.init(allocator);
    defer llm.deinit();

    // Configure the model path
    // Replace with your actual model path
    try llm.appendParam("-m");
    try llm.appendParam("path/to/your/model.bin");

    // Simple callback context that just prints output
    const SimpleCtx = struct {
        done: bool = false,

        pub fn onPrint(self: *@This(), print_type: chatllm.PrintType, text: []const u8) void {
            _ = self;
            if (print_type == .chat_chunk) {
                std.debug.print("{s}", .{text});
            }
        }

        pub fn onEnd(self: *@This()) void {
            self.done = true;
            std.debug.print("\n", .{});
        }
    };

    var ctx = SimpleCtx{};
    var callback = chatllm.CallbackContext(*SimpleCtx){
        .user_data = &ctx,
        .print_fn = SimpleCtx.onPrint,
        .end_fn = SimpleCtx.onEnd,
    };

    // Start the model (loads weights, prepares for inference)
    std.debug.print("Loading model...\n", .{});
    try llm.startWithContext(*SimpleCtx, &callback);

    // Send a prompt and wait for the response
    std.debug.print("Prompt: What is the capital of France?\n", .{});
    std.debug.print("Response: ", .{});
    try llm.userInput("What is the capital of France?");

    std.debug.print("\nDone!\n", .{});
}
