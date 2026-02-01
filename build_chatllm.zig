const std = @import("std");
const Builder = std.Build;
const Target = std.Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const CompileStep = std.Build.Step.Compile;
const LazyPath = std.Build.LazyPath;

/// GPU backend configuration for chatllm.cpp
pub const Backends = struct {
    cpu: bool = true,
    metal: bool = false,
    cuda: bool = false,
    vulkan: bool = false,
    opencl: bool = false,
    rpc: bool = false,

    pub fn addDefines(self: @This(), comp: *CompileStep) void {
        if (self.cuda) comp.root_module.addCMacro("GGML_USE_CUDA", "");
        if (self.metal) comp.root_module.addCMacro("GGML_USE_METAL", "");
        if (self.vulkan) comp.root_module.addCMacro("GGML_USE_VULKAN", "");
        if (self.opencl) comp.root_module.addCMacro("GGML_USE_CLBLAST", "");
        if (self.rpc) comp.root_module.addCMacro("GGML_USE_RPC", "");
        if (self.cpu) comp.root_module.addCMacro("GGML_USE_CPU", "");
    }
};

/// Build options for chatllm.cpp
pub const Options = struct {
    target: Target,
    optimize: OptimizeMode,
    backends: Backends = .{},
    shared: bool = false, // static or shared lib
    chatllm_path: ?[]const u8 = null, // Path to chatllm.cpp checkout
};

/// Build context for chatllm.cpp
pub const Context = struct {
    b: *Builder,
    options: Options,
    path_prefix: []const u8 = "",
    lib: ?*CompileStep = null,

    pub fn init(b: *Builder, options: Options) Context {
        return .{
            .b = b,
            .options = options,
            .path_prefix = options.chatllm_path orelse "chatllm.cpp",
        };
    }

    /// Build the chatllm static library containing everything
    pub fn library(ctx: *Context) *CompileStep {
        if (ctx.lib) |l| return l;

        const lib_module = ctx.b.createModule(.{
            .target = ctx.options.target,
            .optimize = ctx.options.optimize,
        });
        const linkage: std.builtin.LinkMode = if (ctx.options.shared) .dynamic else .static;
        const lib = ctx.b.addLibrary(.{
            .name = "chatllm",
            .root_module = lib_module,
            .linkage = linkage,
        });

        // Add backend defines
        ctx.options.backends.addDefines(lib);

        // Configure common settings
        ctx.common(lib);

        // Add include paths
        ctx.addIncludePaths(lib);

        // Add GGML sources
        ctx.addGgmlSources(lib);

        // Add chatllm core sources
        ctx.addCoreSources(lib);

        // Add model sources
        ctx.addModelSources(lib);

        // Always define CHATLLM_SHARED_LIB to expose the C API and exclude main()
        // This macro controls whether main.cpp exports the C API or builds an executable
        lib.root_module.addCMacro("CHATLLM_SHARED_LIB", "");

        ctx.lib = lib;
        return lib;
    }

    /// Link chatllm library to a compile step
    pub fn link(ctx: *Context, comp: *CompileStep) void {
        const lib = ctx.library();
        comp.linkLibrary(lib);
        if (ctx.options.shared) ctx.b.installArtifact(lib);
    }

    fn common(ctx: Context, lib: *CompileStep) void {
        lib.linkLibCpp();

        // Add GNU source define for non-MSVC targets
        if (ctx.options.target.result.abi != .msvc) {
            lib.root_module.addCMacro("_GNU_SOURCE", "");
        }

        // Windows-specific
        if (ctx.options.target.result.os.tag == .windows) {
            lib.root_module.addCMacro("GGML_ATTRIBUTE_FORMAT(...)", "");
            lib.root_module.addCMacro("_CRT_SECURE_NO_WARNINGS", "");
        }

        // Release mode
        if (ctx.options.optimize != .Debug) {
            lib.root_module.addCMacro("NDEBUG", "");
        }
    }

    fn addIncludePaths(ctx: Context, lib: *CompileStep) void {
        // chatllm.cpp root (for src/*.h headers)
        lib.addIncludePath(ctx.path(&.{}));
        lib.addIncludePath(ctx.path(&.{"src"}));

        // ggml include paths
        lib.addIncludePath(ctx.path(&.{ "ggml", "include" }));
        lib.addIncludePath(ctx.path(&.{ "ggml", "include", "ggml" }));
        lib.addIncludePath(ctx.path(&.{ "ggml", "src" }));

        // Models directory
        lib.addIncludePath(ctx.path(&.{"models"}));

        // Bindings directory (for libchatllm.h)
        lib.addIncludePath(ctx.path(&.{"bindings"}));
    }

    fn addGgmlSources(ctx: Context, lib: *CompileStep) void {
        const cpp_flags = ctx.cppFlags();
        const c_flags = ctx.cFlags();

        // GGML version defines
        lib.root_module.addCMacro("GGML_VERSION", "\"0.9.5\"");
        lib.root_module.addCMacro("GGML_COMMIT", "\"unknown\"");

        // Core GGML sources
        const ggml_c_sources = [_][]const []const u8{
            &.{ "ggml", "src", "ggml-alloc.c" },
            &.{ "ggml", "src", "ggml-quants.c" },
            &.{ "ggml", "src", "ggml.c" },
        };

        const ggml_cpp_sources = [_][]const []const u8{
            &.{ "ggml", "src", "ggml-backend-reg.cpp" },
            &.{ "ggml", "src", "ggml-backend.cpp" },
            &.{ "ggml", "src", "ggml-opt.cpp" },
            &.{ "ggml", "src", "ggml-threading.cpp" },
            &.{ "ggml", "src", "ggml.cpp" },
            &.{ "ggml", "src", "gguf.cpp" },
        };

        for (ggml_c_sources) |src_path| {
            lib.addCSourceFile(.{ .file = ctx.path(src_path), .flags = c_flags });
        }

        for (ggml_cpp_sources) |src_path| {
            lib.addCSourceFile(.{ .file = ctx.path(src_path), .flags = cpp_flags });
        }

        // CPU backend sources
        if (ctx.options.backends.cpu) {
            lib.addIncludePath(ctx.path(&.{ "ggml", "src", "ggml-cpu" }));

            const cpu_c_sources = [_][]const []const u8{
                &.{ "ggml", "src", "ggml-cpu", "ggml-cpu.c" },
                &.{ "ggml", "src", "ggml-cpu", "quants.c" },
            };

            const cpu_cpp_sources = [_][]const []const u8{
                &.{ "ggml", "src", "ggml-cpu", "ggml-cpu.cpp" },
                &.{ "ggml", "src", "ggml-cpu", "binary-ops.cpp" },
                &.{ "ggml", "src", "ggml-cpu", "unary-ops.cpp" },
                &.{ "ggml", "src", "ggml-cpu", "hbm.cpp" },
                &.{ "ggml", "src", "ggml-cpu", "traits.cpp" },
                &.{ "ggml", "src", "ggml-cpu", "ops.cpp" },
                &.{ "ggml", "src", "ggml-cpu", "repack.cpp" },
                &.{ "ggml", "src", "ggml-cpu", "vec.cpp" },
                // AMX (Intel Advanced Matrix Extensions)
                &.{ "ggml", "src", "ggml-cpu", "amx", "amx.cpp" },
                &.{ "ggml", "src", "ggml-cpu", "amx", "mmq.cpp" },
            };

            for (cpu_c_sources) |src_path| {
                lib.addCSourceFile(.{ .file = ctx.path(src_path), .flags = c_flags });
            }

            for (cpu_cpp_sources) |src_path| {
                lib.addCSourceFile(.{ .file = ctx.path(src_path), .flags = cpp_flags });
            }

            // Architecture-specific sources
            ctx.addArchSpecificSources(lib);
        }
    }

    fn addArchSpecificSources(ctx: Context, lib: *CompileStep) void {
        const c_flags = ctx.cFlags();
        const cpp_flags = ctx.cppFlags();
        const arch = ctx.options.target.result.cpu.arch;

        if (arch == .x86_64 or arch == .x86) {
            const x86_sources_c = [_][]const []const u8{
                &.{ "ggml", "src", "ggml-cpu", "arch", "x86", "quants.c" },
            };
            const x86_sources_cpp = [_][]const []const u8{
                &.{ "ggml", "src", "ggml-cpu", "arch", "x86", "repack.cpp" },
                &.{ "ggml", "src", "ggml-cpu", "arch", "x86", "cpu-feats.cpp" },
            };
            for (x86_sources_c) |src_path| {
                lib.addCSourceFile(.{ .file = ctx.path(src_path), .flags = c_flags });
            }
            for (x86_sources_cpp) |src_path| {
                lib.addCSourceFile(.{ .file = ctx.path(src_path), .flags = cpp_flags });
            }
        } else if (arch == .aarch64 or arch == .arm) {
            const arm_sources_c = [_][]const []const u8{
                &.{ "ggml", "src", "ggml-cpu", "arch", "arm", "quants.c" },
            };
            const arm_sources_cpp = [_][]const []const u8{
                &.{ "ggml", "src", "ggml-cpu", "arch", "arm", "repack.cpp" },
                &.{ "ggml", "src", "ggml-cpu", "arch", "arm", "cpu-feats.cpp" },
            };
            for (arm_sources_c) |src_path| {
                lib.addCSourceFile(.{ .file = ctx.path(src_path), .flags = c_flags });
            }
            for (arm_sources_cpp) |src_path| {
                lib.addCSourceFile(.{ .file = ctx.path(src_path), .flags = cpp_flags });
            }
        } else if (arch == .powerpc64 or arch == .powerpc64le or arch == .powerpc) {
            lib.addCSourceFile(.{
                .file = ctx.path(&.{ "ggml", "src", "ggml-cpu", "arch", "powerpc", "quants.c" }),
                .flags = c_flags,
            });
        } else if (arch == .riscv64) {
            lib.addCSourceFile(.{
                .file = ctx.path(&.{ "ggml", "src", "ggml-cpu", "arch", "riscv", "quants.c" }),
                .flags = c_flags,
            });
            lib.addCSourceFile(.{
                .file = ctx.path(&.{ "ggml", "src", "ggml-cpu", "arch", "riscv", "repack.cpp" }),
                .flags = cpp_flags,
            });
        } else if (arch == .wasm32 or arch == .wasm64) {
            lib.addCSourceFile(.{
                .file = ctx.path(&.{ "ggml", "src", "ggml-cpu", "arch", "wasm", "quants.c" }),
                .flags = c_flags,
            });
        } else if (arch == .s390x) {
            lib.addCSourceFile(.{
                .file = ctx.path(&.{ "ggml", "src", "ggml-cpu", "arch", "s390", "quants.c" }),
                .flags = c_flags,
            });
        }
    }

    fn addCoreSources(ctx: Context, lib: *CompileStep) void {
        const cpp_flags = ctx.cppFlags();

        // Core chatllm.cpp source files from CMakeLists.txt
        const core_sources = [_][]const []const u8{
            &.{ "src", "backend.cpp" },
            &.{ "src", "chat.cpp" },
            &.{ "src", "vectorstore.cpp" },
            &.{ "src", "layers.cpp" },
            &.{ "src", "tokenizer.cpp" },
            &.{ "src", "models.cpp" },
            &.{ "src", "unicode.cpp" },
            &.{ "src", "unicode-data.cpp" },
            &.{ "src", "vision_process.cpp" },
            &.{ "src", "audio_process.cpp" },
            // C API bindings (exports chatllm_* functions)
            &.{ "src", "main.cpp" },
        };

        for (core_sources) |src_path| {
            lib.addCSourceFile(.{ .file = ctx.path(src_path), .flags = cpp_flags });
        }
    }

    fn addModelSources(ctx: Context, lib: *CompileStep) void {
        const cpp_flags = ctx.cppFlags();

        // All model implementations from CMakeLists.txt
        const model_sources = [_][]const []const u8{
            &.{ "models", "adept.cpp" },
            &.{ "models", "allenai.cpp" },
            &.{ "models", "alphageo.cpp" },
            &.{ "models", "apertus.cpp" },
            &.{ "models", "apriel.cpp" },
            &.{ "models", "aquila.cpp" },
            &.{ "models", "baichuan.cpp" },
            &.{ "models", "bailing.cpp" },
            &.{ "models", "bce.cpp" },
            &.{ "models", "bge.cpp" },
            &.{ "models", "bluelm.cpp" },
            &.{ "models", "chatglm.cpp" },
            &.{ "models", "characterglm.cpp" },
            &.{ "models", "codegeex.cpp" },
            &.{ "models", "codefuse.cpp" },
            &.{ "models", "codellama.cpp" },
            &.{ "models", "cohere.cpp" },
            &.{ "models", "decilm.cpp" },
            &.{ "models", "deepseek.cpp" },
            &.{ "models", "dolphinphi2.cpp" },
            &.{ "models", "dots.cpp" },
            &.{ "models", "ernie.cpp" },
            &.{ "models", "exaone.cpp" },
            &.{ "models", "falcon.cpp" },
            &.{ "models", "gemma.cpp" },
            &.{ "models", "gigachat.cpp" },
            &.{ "models", "gpt.cpp" },
            &.{ "models", "granite.cpp" },
            &.{ "models", "groq.cpp" },
            &.{ "models", "grok.cpp" },
            &.{ "models", "grove.cpp" },
            &.{ "models", "hermes.cpp" },
            &.{ "models", "hunyuan.cpp" },
            &.{ "models", "index.cpp" },
            &.{ "models", "instella.cpp" },
            &.{ "models", "internlm.cpp" },
            &.{ "models", "janus.cpp" },
            &.{ "models", "jina.cpp" },
            &.{ "models", "jiutian.cpp" },
            &.{ "models", "llama.cpp" },
            &.{ "models", "maya.cpp" },
            &.{ "models", "m_a_p.cpp" },
            &.{ "models", "megrez.cpp" },
            &.{ "models", "minicpm.cpp" },
            &.{ "models", "mistral.cpp" },
            &.{ "models", "moonshot.cpp" },
            &.{ "models", "neuralbeagle.cpp" },
            &.{ "models", "numinamath.cpp" },
            &.{ "models", "orpheus.cpp" },
            &.{ "models", "openchat.cpp" },
            &.{ "models", "orion.cpp" },
            &.{ "models", "ouro.cpp" },
            &.{ "models", "oute.cpp" },
            &.{ "models", "pangu.cpp" },
            &.{ "models", "phi.cpp" },
            &.{ "models", "qwen.cpp" },
            &.{ "models", "qwen_asr.cpp" },
            &.{ "models", "reka.cpp" },
            &.{ "models", "rnj.cpp" },
            &.{ "models", "seed.cpp" },
            &.{ "models", "siglip.cpp" },
            &.{ "models", "smol.cpp" },
            &.{ "models", "solar.cpp" },
            &.{ "models", "stablelm.cpp" },
            &.{ "models", "starcoder.cpp" },
            &.{ "models", "starling.cpp" },
            &.{ "models", "step.cpp" },
            &.{ "models", "telechat.cpp" },
            &.{ "models", "tigerbot.cpp" },
            &.{ "models", "wizard.cpp" },
            &.{ "models", "xverse.cpp" },
            &.{ "models", "yi.cpp" },
            &.{ "models", "zhinao.cpp" },
        };

        for (model_sources) |src_path| {
            lib.addCSourceFile(.{ .file = ctx.path(src_path), .flags = cpp_flags });
        }
    }

    fn cppFlags(ctx: Context) []const []const u8 {
        _ = ctx;
        return &.{
            "-std=c++20",
            "-fno-sanitize=undefined",
            "-fexceptions",
        };
    }

    fn cFlags(ctx: Context) []const []const u8 {
        _ = ctx;
        return &.{"-fno-sanitize=undefined"};
    }

    pub fn path(self: Context, subpath: []const []const u8) LazyPath {
        const sp = self.b.pathJoin(subpath);
        return .{ .cwd_relative = self.b.pathJoin(&.{ self.path_prefix, sp }) };
    }
};

/// Main entry point: creates a chatllm.cpp static library
/// Following the pattern from build_llama.zig
pub fn addChatLLM(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    chatllm_path: ?[]const u8,
) *std.Build.Step.Compile {
    var ctx = Context.init(b, .{
        .target = target,
        .optimize = optimize,
        .backends = .{ .cpu = true },
        .shared = false,
        .chatllm_path = chatllm_path,
    });

    return ctx.library();
}

/// Extended entry point with full options control
pub fn addChatLLMWithOptions(
    b: *std.Build,
    options: Options,
) *std.Build.Step.Compile {
    var ctx = Context.init(b, options);
    return ctx.library();
}

fn thisPath() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}
