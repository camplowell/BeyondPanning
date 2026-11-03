const std = @import("std");
const simd = @import("simd.zig");
const Benchmark = @import("Benchmark.zig");
const Delay = @import("Delay.zig");

pub fn main(init: std.process.Init) !void {
    const stdout: std.Io.File = .stdout();
    var bench: Benchmark = .{ .gpa = init.gpa, .io = init.io };

    defer bench.deinit();
    var delay: Delay = try .init(init.gpa, 256);
    defer delay.deinit(init.gpa);
    const ctx: Ctx = .{ .delay = &delay, .workload = .init() };
    ctx.delay.push(&ctx.workload.input);

    try bench.run("Push only", &ctx, pushOnly);
    try bench.run("Push + getVec", &ctx, pushAndGetVec);
    try bench.run("Push + getOne", &ctx, pushAndGetOne);

    var io_buf: [1024]u8 = undefined;
    var stdout_writer = stdout.writer(init.io, &io_buf);
    try stdout_writer.interface.print("{f}", .{bench});
    try stdout_writer.flush();
}

fn pushOnly(ctx: *const Ctx) void {
    ctx.delay.push(&ctx.workload.input);
    std.mem.doNotOptimizeAway(ctx.delay.data);
}


fn pushAndGetVec(ctx: *const Ctx) void {
    ctx.delay.push(&ctx.workload.input);
    var t: usize = 0;
    while (t + simd.len <= Workload.batch_size) : (t += simd.len) {
        std.mem.doNotOptimizeAway(ctx.delay.getVec(Workload.batch_size - t, ctx.workload.delays[t..][0..simd.len].*));
    }
}

fn pushAndGetOne(ctx: *const Ctx) void {
    ctx.delay.push(&ctx.workload.input);
    for (0..Workload.batch_size) |t| {
        std.mem.doNotOptimizeAway(ctx.delay.getOne(t, ctx.workload.delays[t]));
    }
}

const Ctx = struct {
    workload: Workload,
    delay: *Delay,
};

const Workload = struct {
    const batch_size = 128;

    input: [batch_size]f32,
    delays: [batch_size]f32,

    fn init() Workload {
        comptime _ = @divExact(Workload.batch_size, simd.len);
        var self: Workload = undefined;
        var prng = std.Random.DefaultPrng.init(0x5eed);
        const random = prng.random();
        const mix = 1.0 - @exp(-50.0 / 48000.0);
        var smoothed: f32 = 0.0;
        const target: f32 = 30.0;
        for (&self.input, &self.delays) |*sample, *delay| {
            sample.* = random.float(f32) * 2.0 - 1.0;
            smoothed += (target - smoothed) * mix;
            delay.* = smoothed;
        }
        return self;
    }
};
