const std = @import("std");
const chatllm = @import("build_chatllm.zig");

const Target = std.Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const CompileStep = std.Build.Step.Compile;
const Module = std.Build.Module;

/// Build options for the chatllm.zig project
pub const Options = struct {
    target: Target,
    optimize: OptimizeMode,
    chatllm_path: ?[]const u8 = null,
    backends: chatllm.Backends = .{},
};

/// Build context for chatllm.zig
pub const Context = struct {
    const Self = @This();

    b: *std.Build,
    options: Options,
    /// chatllm.cpp build context
    chatllm_ctx: chatllm.Context,
    /// Main Zig module exposing the chatllm bindings
    module: *Module,

    pub fn init(b: *std.Build, options: Options) Self {
        // Initialize the chatllm.cpp build context
        const chatllm_ctx = chatllm.Context.init(b, .{
            .target = options.target,
            .optimize = options.optimize,
            .chatllm_path = options.chatllm_path,
            .backends = options.backends,
        });

        // Create the main Zig module that exposes the C API bindings
        const mod = b.addModule("chatllm", .{
            .root_source_file = b.path("chatllm.cpp.zig/chatllm.zig"),
            .target = options.target,
            .optimize = options.optimize,
        });

        return .{
            .b = b,
            .options = options,
            .chatllm_ctx = chatllm_ctx,
            .module = mod,
        };
    }

    /// Link the chatllm.cpp library to a compile step
    pub fn link(self: *Self, compile: *CompileStep) void {
        self.chatllm_ctx.link(compile);
    }
};

pub fn build(b: *std.Build) !void {
    // Standard build options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // chatllm.zig specific options
    const chatllm_path = b.option(
        []const u8,
        "chatllm_path",
        "Path to local chatllm.cpp checkout. Required if not using a vendored copy.",
    );

    // GPU backend options
    const enable_cuda = b.option(bool, "cuda", "Enable CUDA GPU backend (NVIDIA)") orelse false;
    const enable_vulkan = b.option(bool, "vulkan", "Enable Vulkan GPU backend") orelse false;
    const enable_metal = b.option(bool, "metal", "Enable Metal GPU backend (macOS only)") orelse false;

    // Validate Metal is only enabled on macOS
    if (enable_metal and target.result.os.tag != .macos) {
        std.log.warn("Metal backend is only available on macOS, ignoring -Dmetal=true", .{});
    }

    const backends = chatllm.Backends{
        .cpu = true,
        .cuda = enable_cuda,
        .vulkan = enable_vulkan,
        .metal = enable_metal and target.result.os.tag == .macos,
    };

    // Initialize the build context
    var ctx = Context.init(b, .{
        // Note: ctx needs to be var since link() takes *Self
        .target = target,
        .optimize = optimize,
        .chatllm_path = chatllm_path,
        .backends = backends,
    });

    // Build and install the chatllm.cpp static library
    // Usage in dependent's build.zig:
    //   exe.root_module.addImport("chatllm", chatllm_dep.module("chatllm"));
    //   exe.linkLibrary(chatllm_dep.artifact("chatllm"));
    const chatllm_lib = ctx.chatllm_ctx.library();
    b.installArtifact(chatllm_lib);

    // Build the main CLI executable
    {
        const cli_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        // Add the chatllm module import
        cli_module.addImport("chatllm", ctx.module);

        const cli_exe = b.addExecutable(.{
            .name = "chatllm",
            .root_module = cli_module,
        });

        // Increase stack size for LLM operations
        cli_exe.stack_size = 32 * 1024 * 1024;

        // Link the chatllm.cpp library
        ctx.link(cli_exe);

        b.installArtifact(cli_exe);

        // Add run step
        const run_cli = b.addRunArtifact(cli_exe);
        if (b.args) |args| run_cli.addArgs(args);
        run_cli.step.dependOn(b.default_step);
        b.step("run", "Run the chatllm CLI").dependOn(&run_cli.step);
    }

    // Tests
    {
        // Test the main Zig bindings module
        const test_module = b.createModule(.{
            .root_source_file = b.path("chatllm.cpp.zig/chatllm.zig"),
            .target = target,
            .optimize = optimize,
        });

        const main_tests = b.addTest(.{
            .root_module = test_module,
        });

        ctx.link(main_tests);

        const run_main_tests = b.addRunArtifact(main_tests);

        const test_step = b.step("test", "Run library tests");
        test_step.dependOn(&run_main_tests.step);
    }
}
