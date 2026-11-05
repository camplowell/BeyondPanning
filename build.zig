const std = @import("std");
const Build = std.Build;
const Cfg = @This();

b: *Build,
target: Build.ResolvedTarget,
optimize: std.builtin.Optimize,
test_step: *Build.Step,
run: *Build.Step,
executable: ?[]const u8,

pub fn build(b: *Build) void {
    var self: Cfg = .{
        .b = b,
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .run = b.step("run", "Run the compiled program"),
        .test_step = b.step("test", "Run unit tests"),
        .executable = b.option([]const u8, "exe", "Executable to build / run"),
    };
    self.addTests(b.path("src/Delay.zig"));
    self.addTests(b.path("src/Blockhead.zig"));
    self.addBench("delay", b.path("src/delay_bench.zig"));
    self.addBench("blockhead", b.path("src/blockhead_bench.zig"));
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
    exe.entry = .disabled;
    exe.rdynamic = true;
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
    const any_selected = self.executable != null;
    const selected = any_selected and std.mem.eql(u8, self.executable.?, self.b.fmt("bench-{s}", .{name}));
    if (any_selected and !selected) return;
    const exe = self.b.addExecutable(.{
        .name = name,
        .root_module = self.b.createModule(.{
            .root_source_file = root,
            .optimize = self.optimize,
            .target = self.target
        }),
    });
    const install_exe = self.b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "benchmark" } }});
    self.b.getInstallStep().dependOn(&install_exe.step);
    if (selected) {
        const run_exe = self.b.addRunArtifact(exe);
        self.run.dependOn(&run_exe.step);
    }
}
