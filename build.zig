const std = @import("std");
const Build = std.Build;
const Cfg = @This();

b: *Build,
target: Build.ResolvedTarget,
optimize: std.builtin.Optimize,
test_step: *Build.Step,
bench: *Build.Step,

pub fn build(b: *Build) void {
    var self: Cfg = .{
        .b = b,
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .bench = b.step("bench", "Run benchmarks"),
        .test_step = b.step("test", "Run unit tests"),
    };
    self.addTests(b.path("src/Delay.zig"));
    self.addTests(b.path("src/Blockhead.zig"));
    self.addBench("benchDelay", b.path("src/delay_bench.zig"));
    self.addBench("benchBlockhead", b.path("src/blockhead_bench.zig"));
}

fn addExe(self: *Cfg, name: []const u8, root: Build.LazyPath) *Build.Step.Compile {
    const exe = self.b.addExecutable(.{
        .name = name,
        .root_module = self.b.createModule(.{
            .root_source_file = root,
            .optimize = self.optimize,
            .target = self.target,
        }),
    });
    self.b.installArtifact(exe);
    
    return exe;
}

fn addTests(self: *Cfg, root: Build.LazyPath) void {
    const exe = self.b.addTest(.{
        .root_module = self.b.createModule(.{
            .root_source_file = root,
            .optimize = self.optimize,
            .target = self.target
        }),
    });
    const run_exe = self.b.addRunArtifact(exe);
    self.test_step.dependOn(&run_exe.step);
}

fn addBench(self: *Cfg, name: []const u8, root: Build.LazyPath) void {
    const exe = self.b.addExecutable(.{
        .name = name,
        .root_module = self.b.createModule(.{
            .root_source_file = root,
            .optimize = self.optimize,
            .target = self.target
        }),
    });
    self.b.installArtifact(exe);
    const run_exe = self.b.addRunArtifact(exe);
    self.bench.dependOn(&run_exe.step);
}
// 
// pub fn build(b: *std.Build) void {
//     const bench = b.step("bench", "Run benchmark");
//     var ctx: Context = .{
//         .b = b,
//         .test_step = b.step("test", "Run unit tests"),
//         .optimize = b.standardOptimizeOption(.{}),
//         .target = b.standardTargetOptions(.{ .default_target = .{
//             .os_tag = .freestanding,
//             .cpu_arch = .wasm32,
//             .cpu_features_add = std.Target.wasm.featureSet(&.{
//                 .bulk_memory, .simd128
//             })
//         }}),
//         .native = b.resolveTargetQuery(.{}),
//     };
//     ctx.addTestRoot(b.path("src/Delay.zig"));
//     const bench_delay_exe = ctx.addExeRoot("benchDelay", b.path("src/bench_delay.zig"));
//     const run_bench_delay = b.addRunArtifact(bench_delay_exe);
//     bench.dependOn(&run_bench_delay.step);
// }
// 
// const Context = struct {
//     b: *std.Build,
//     test_step: *std.Build.Step,
//     optimize: std.builtin.Optimize,
//     target: std.Build.ResolvedTarget,
//     native: std.Build.ResolvedTarget,
// 
//     fn addRoot(self: *Context, name: []const u8, root_source_file: std.Build.LazyPath) void {
//         _ = self.addExeRoot(name, root_source_file);
//         self.addTestRoot(root_source_file);
//     }
// 
//     fn addExeRoot(self: *Context, name: []const u8, root_source_file: std.Build.LazyPath) *std.Build.Step.Compile {
//         const b = self.b;
//         const exe = b.addExecutable(.{
//             .name = name,
//             .root_module = b.createModule(.{
//                 .root_source_file = root_source_file,
//                 .target = self.target,
//                 .optimize = self.optimize,
//             })
//         });
//         exe.link_gc_sections = true;
//         b.installArtifact(exe);
//         return exe;
//     }
// 
//     fn addTestRoot(self: *Context, root_source_file: std.Build.LazyPath) void {
//         const b = self.b;
//         const test_exe = b.addTest(.{
//             .root_module = b.createModule(.{
//                 .root_source_file = root_source_file,
//                 .target = self.native,
//                 .optimize = self.optimize,
//             })
//         });
//         const run_test_exe = b.addRunArtifact(test_exe);
//         self.test_step.dependOn(&run_test_exe.step);
//     }
// 
// };
