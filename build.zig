const std = @import("std");
const Build = std.Build;
const Cfg = @This();

b: *Build,
target: Build.ResolvedTarget,
optimize: ?std.builtin.Optimize,
test_step: *Build.Step,
run: *Build.Step,
target_exe: ?[]const u8,

serve_step: *Build.Step,
serve_meta: *Build.Step.Options,
serve_meta_count: usize,

pub fn build(b: *Build) !void {
    var self: Cfg = .{
        .b = b,
        .target = b.standardTargetOptions(.{}),
        .optimize = b.option(std.builtin.Optimize, "optimize", "Prioritize performance, safety, or binary size"),
        .run = b.step("run", "Run the compiled program"),
        .test_step = b.step("test", "Run unit tests"),
        .target_exe = b.option([]const u8, "exe", "Executable to build / run"),
        .serve_step = b.step("serve", "Serve a web demo"),
        .serve_meta = b.addOptions(),
        .serve_meta_count = 0,
    };
    
    self.addTests(b.path("src/Delay.zig"));
    self.addTests(b.path("src/Blockhead.zig"));
    
    self.addBench("delay", b.path("src/delay_bench.zig"));
    self.addBench("blockhead", b.path("src/blockhead_bench.zig"));

    self.addDemo(.{
        .name = "blockhead",
        .root_source_file = b.path("preview/blockhead/worker.zig"),
        .imports = &.{ .{"Blockhead", b.path("src/Blockhead.zig")} },
        .assets = &.{
            .{"blockhead", .html, b.path("preview/blockhead/index.html") },
            .{"blockhead/worker.js", .js, b.path("preview/blockhead/worker.js")},
        },
    });

    const server_exe = b.addExecutable(.{
        .name = "dev_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("preview/server.zig"),
            .optimize = .debug,
            .target = b.resolveTargetQuery(.{}),
        }),
    });
    self.addServerResource("anton__sewing-machine-gritty-loop.opus", .{ .other = "audio/ogg; codecs=opus" }, b.path("preview/anton__sewing-machine-gritty-loop.opus"));
    self.serve_meta.addOption(usize, "page_count", self.serve_meta_count);
    server_exe.root_module.addOptions("pages", self.serve_meta);
    const run_server = b.addRunArtifact(server_exe);
    run_server.cwd = b.path(".");
    self.serve_step.dependOn(&run_server.step);
}

fn addTests(self: *Cfg, root: Build.LazyPath) void {
    const exe = self.b.addTest(.{
        .root_module = self.b.createModule(.{
            .root_source_file = root,
            .optimize = self.optimize orelse .debug,
            .target = self.target
        }),
    });
    const run_exe = self.b.addRunArtifact(exe);
    self.test_step.dependOn(&run_exe.step);
}

fn addBench(self: *Cfg, name: []const u8, root: Build.LazyPath) void {
    const any_selected = self.target_exe != null;
    const selected = any_selected and (
        std.mem.eql(u8, self.target_exe.?, self.b.fmt("bench-{s}", .{name})) or
        std.mem.eql(u8, self.target_exe.?, "bench")
    );
    const exe = self.b.addExecutable(.{
        .name = name,
        .root_module = self.b.createModule(.{
            .root_source_file = root,
            .optimize = self.optimize orelse .fast,
            .target = self.target
        }),
    });
    if (selected or !any_selected) {
        const install_exe = self.b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "benchmark" } }});
        self.b.getInstallStep().dependOn(&install_exe.step);
    }
    if (selected) {
        const run_exe = self.b.addRunArtifact(exe);
        self.run.dependOn(&run_exe.step);
    }
}

fn addDemo(
    self: *Cfg,
    options: struct {
        name: []const u8,
        root_source_file: Build.LazyPath,
        imports: []const struct{ []const u8, Build.LazyPath } = &.{},
        assets: []const struct{ []const u8, ContentType, Build.LazyPath } = &.{},
    },
) void {
    const exe = self.b.addExecutable(.{
        .name = options.name,
        .root_module = self.b.createModule(.{
            .root_source_file = options.root_source_file,
            .optimize = self.optimize orelse .small,
            .target = self.b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
                .cpu_features_add = std.Target.wasm.featureSet(&.{
                    .bulk_memory,
                    .extended_const,
                    .multivalue,
                    .mutable_globals,
                    .nontrapping_fptoint,
                    .reference_types,
                    .sign_ext,
                    .simd128,
                    .tail_call,
                })
            })
        }),
    });
    exe.entry = .disabled;
    exe.rdynamic = true;

    for (options.imports) |r| {
        exe.root_module.addImport(r[0], self.b.createModule(.{
            .root_source_file = r[1],
            .optimize = exe.root_module.optimize,
            .target = exe.root_module.resolved_target,
        }));
    }

    if (
        self.target_exe == null or
        std.mem.eql(u8, self.target_exe.?, self.b.fmt("demo-{s}", .{options.name})) or
        std.mem.eql(u8, self.target_exe.?, "demo")
    ) {
        self.addServerResource(self.b.fmt("{s}/worker.wasm", .{options.name}), .wasm, exe.getEmittedBin());
        for (options.assets) |a| { self.addServerResource(a[0], a[1], a[2]); }
    }
}


fn addWasmEntry(
    self: *Cfg, 
    name: []const u8, 
    root: Build.LazyPath,
) ?*Build.Step.Compile {
    const any_selected = self.target_exe != null;
    const selected = any_selected and (
        std.mem.eql(u8, self.target_exe.?, self.b.fmt("demo-{s}", .{name})) or
        std.mem.eql(u8, self.target_exe.?, "demo")
    );
    
    const exe = self.b.addExecutable(.{
        .name = name,
        .root_module = self.b.createModule(.{
            .root_source_file = root,
            .optimize = self.optimize,
            .target = self.b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
                .cpu_features_add = std.Target.wasm.featureSet(&.{
                    .bulk_memory,
                    .extended_const,
                    .multivalue,
                    .mutable_globals,
                    .nontrapping_fptoint,
                    .reference_types,
                    .sign_ext,
                    .simd128,
                    .tail_call,
                })
            })
        }),
    });
    exe.entry = .disabled;
    exe.rdynamic = true;
    
    if (selected or !any_selected) {
        const install_exe = self.b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "demo" } }});
        self.b.getInstallStep().dependOn(&install_exe.step);
        return exe;
    }
    return null;
}

fn addServerResource(self: *Cfg, target: []const u8, content_type: ContentType, path: Build.LazyPath) void {
    self.serve_meta.addOption([]const u8, self.b.fmt("target_{d}", .{self.serve_meta_count}), target);
    self.serve_meta.addOption([]const u8, self.b.fmt("content_type_{d}", .{self.serve_meta_count}), switch (content_type) {
        .html => "text/html",
        .js => "application/javascript",
        .wasm => "application/wasm",
        .other => |s| s,
    });
    self.serve_meta.addOptionPath(self.b.fmt("path_{d}", .{self.serve_meta_count}), path);
    self.serve_meta_count += 1;
}

const ContentType = union(enum) {
    html: void,
    js: void,
    wasm: void,
    other: []const u8
};
