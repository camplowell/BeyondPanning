const std = @import("std");
const Build = std.Build;

const Self = @This();
b: *Build,
target: Build.ResolvedTarget,
optimize: ?std.builtin.Optimize,
exe_query: ExeSelection,
run_step: *Build.Step,
test_step: *Build.Step,

demo_assets: std.array_hash_map.String(PageContent),

const spec: BuildSpec = .{
    .tests = &.{ "src/Delay.zig", "src/Blockhead.zig" },
    .bench = &.{
        .{ .name = "delay", .root_source_file = "src/delay_bench.zig"},
        .{ .name = "blockhead", .root_source_file = "src/blockhead_bench.zig"},
    },
    .demo = &.{
        .{
            .name = "blockhead",
            .root_source_file = "preview/blockhead/worker.zig",
            .imports = &.{ .{ .name="Blockhead", .root_source_file="src/Blockhead.zig" }},
            .assets = &.{
                .{ .target="", .t=.html, .path="preview/blockhead/index.html" },
                .{ .target="worker.js", .t=.js, .path="preview/blockhead/worker.js" },
            }
        }
    },
    .demo_assets = &.{
        .{
            .target = "anton__sewing-machine-gritty-loop.opus", 
            .t = .{ .other = "audio/ogg; codecs=opus" }, 
            .path = "preview/anton__sewing-machine-gritty-loop.opus"
        }
    },
};

pub fn build(b: *Build) !void {
    var self: Self = .{
        .b = b,
        .target = b.standardTargetOptions(.{}),
        .optimize = b.option(
            std.builtin.Optimize, 
            "optimize",
            "Prioritize performance, safety, or binary size",
        ),
        .exe_query = b.option(
            ExeSelection,
            "exe",
            "Executable (category) to build / run",
        ) orelse .all,
        .run_step = b.step("run", "Run the compiled executable"),
        .test_step = b.step("test", "Run unit tests"),
        .demo_assets = .empty,
    };
    for (spec.tests) |t| self.addTest(t);
    for (spec.bench) |bench| self.addBench(bench);
    for (spec.demo) |d| try self.addDemo(d);
    for (spec.demo_assets) |a| {
        try self.demo_assets.putNoClobber(b.allocator, a.target, .{ .t = a.t, .path = b.path(a.path)});
    }
    try self.finalizeDemoServer();
}

fn addTest(self: Self, root: []const u8) void {
    const exe = self.b.addTest(.{
        .root_module = self.b.createModule(.{
            .root_source_file = self.b.path(root),
            .optimize = self.optimize orelse .debug,
            .target = self.target
        }),
    });
    const run_exe = self.b.addRunArtifact(exe);
    self.test_step.dependOn(&run_exe.step);
}

fn addBench(self: Self, opts: Module) void {
    const exe = self.b.addExecutable(.{
        .name = opts.name,
        .root_module = self.b.createModule(.{
            .root_source_file = self.b.path(opts.root_source_file),
            .optimize = self.optimize orelse .fast,
            .target = self.target,
        }),
    });
    if (!self.isActive("bench", opts.name)) return;
    const install_exe = self.b.addInstallArtifact(
        exe,
        .{.dest_dir = .{.override = .{.custom = "bench"}}}
    );
    self.b.getInstallStep().dependOn(&install_exe.step);
    const run_exe = self.b.addRunArtifact(exe);
    self.run_step.dependOn(&run_exe.step);
}

fn addDemo(self: *Self, opts: Demo) !void {
    const resolved_optimize = self.optimize orelse .fast;
    const wasm_standalone = self.b.resolveTargetQuery(wasm_standalone_query);
    const exe = self.b.addExecutable(.{
        .name = opts.name,
        .root_module = self.b.createModule(.{
            .root_source_file = self.b.path(opts.root_source_file),
            .target = wasm_standalone,
            .optimize = resolved_optimize,
        })
    });
    exe.entry = .disabled;
    exe.rdynamic = true;

    for (opts.imports) |mod| {
        exe.root_module.addImport(
            mod.name, 
            self.b.createModule(.{
                .root_source_file = self.b.path(mod.root_source_file),
                .target = wasm_standalone,
                .optimize = resolved_optimize,
            }),
        );
    }
    if (!self.isActive("demo", opts.name)) return;
    try self.demo_assets.putNoClobber(self.b.allocator, self.b.fmt("{s}/worker.wasm", .{opts.name}), .{ .t = .wasm, .path = exe.getEmittedBin() });
    for (opts.assets) |asset| {
        try self.demo_assets.putNoClobber(self.b.allocator, self.b.fmt("{s}/{s}", .{opts.name, asset.target}), .{ .t = asset.t, .path = self.b.path(asset.path) });
    }
}

fn finalizeDemoServer(self: Self) !void {
    const exe = self.b.addExecutable(.{
        .name = "dev_server",
        .root_module = self.b.createModule(.{
            .root_source_file = self.b.path("preview/server.zig"),
            .optimize = .debug,
            .target = self.b.resolveTargetQuery(.{}),
        }),
    });
    var meta = self.b.addOptions();
    var asset_iter = self.demo_assets.iterator();
    var i: usize = 0;
    while (asset_iter.next()) |asset|: (i += 1) {
        meta.addOption([]const u8, self.b.fmt("target_{d}", .{i}), asset.key_ptr.*);
        meta.addOption([]const u8, self.b.fmt("content_type_{d}", .{i}), switch(asset.value_ptr.t) {
            .html => "text/html",
            .js => "application/javascript",
            .wasm => "application/wasm",
            .other => |s| s,
        });
        meta.addOptionPath(self.b.fmt("path_{d}", .{i}), asset.value_ptr.path);
    }
    meta.addOption(usize, "page_count", self.demo_assets.count());
    exe.root_module.addOptions("pages", meta);
    if (std.mem.startsWith(u8, @tagName(self.exe_query), "demo")) {
        const run_server = self.b.addRunArtifact(exe);
        run_server.cwd = self.b.path(".");
        self.run_step.dependOn(&run_server.step);
    }
}

fn isActive(self: Self, category: []const u8, name: []const u8) bool {
    return (
        self.exe_query == .all or
        std.mem.eql(u8, @tagName(self.exe_query), category) or
        std.mem.eql(u8, @tagName(self.exe_query), self.b.fmt("{s}-{s}", .{category, name}))
    );
}


const BuildSpec = struct{
    tests: []const []const u8,
    bench: []const Module,
    demo: []const Demo,
    demo_assets: []const Demo.Asset,
};

const Demo = struct {
    name: []const u8,
    root_source_file: []const u8,
    imports: []const Module,
    assets: []const Asset,

    const Asset = struct {
        target: []const u8,
        t: ContentType,
        path: []const u8,
    };
};

const PageContent = struct{
    t: ContentType,
    path: Build.LazyPath,
};

const Module = struct{
    name: []const u8,
    root_source_file: []const u8,
};

const ContentType = union(enum) {
    html: void,
    js: void,
    wasm: void,
    other: []const u8
};

const ExeSelection = D: {
    var names: []const []const u8 = &.{ "all", "demo" };
    for (spec.demo) |d| { names = names ++ .{ "demo-" ++ d.name }; }
    names = names ++ .{ "bench" };
    for (spec.bench) |b| { names = names ++ .{ "bench-" ++ b.name }; }
    break :D @Enum(usize, .exhaustive, names, &@as([names.len]usize, std.simd.iota(usize, names.len)));
};

const wasm_standalone_query: std.Target.Query = .{
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
};
