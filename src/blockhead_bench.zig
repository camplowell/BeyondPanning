const std = @import("std");
const simd = @import("simd.zig");
const benchmark = @import("bench_runner.zig");
const Blockhead = @import("Blockhead.zig");

pub fn main(init: std.process.Init) !void {
    var ctx: Ctx = try .init(init.gpa);
    defer ctx.deinit(init.gpa);
    
    var io_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &io_buf);

    try benchmark.runAll(
        init.io, 
        &stdout.interface,
        &.{
            .init("Moving", &ctx, runFilter, .{}),
            .init("Static", &ctx, runStatic, .{}),
        }
    );
}

fn runFilter(ctx: *Ctx) void {
    ctx.filter.target = ctx.params[if (ctx.flip == 0) @as(usize, 1) else @as(usize, 0)];
    ctx.flip = (ctx.flip + 1) & 3;
    ctx.filter.process(&ctx.workload.input, &.{ &ctx.workload.output[0], &ctx.workload.output[1] });
    std.mem.doNotOptimizeAway(ctx.workload.output);
}

fn runStatic(ctx: *Ctx) void {
    ctx.filter.process(&ctx.workload.input, &.{ &ctx.workload.output[0], &ctx.workload.output[1] });
    std.mem.doNotOptimizeAway(ctx.workload.output);
}

const Ctx = struct {
    workload: Workload,
    listener: Blockhead,
    filter: Blockhead.Filter,
    params: [2]Blockhead.Params,
    flip: u8,

    fn init(gpa: std.mem.Allocator) !Ctx {
        var self: Ctx = undefined;
        self.workload = try .init(gpa);
        errdefer self.workload.deinit(gpa);
        self.listener = .init(48000, 0.087, 0.03);
        self.filter = try .init(gpa, Workload.batch_size, self.listener, .{0, 1, 0});
        self.flip = 1;
        self.params[0] = .init(self.listener, .{1, 0, 0});
        self.params[1] = self.filter.params;
        return self;
    }

    fn deinit(self: *Ctx, gpa: std.mem.Allocator) void {
        self.workload.deinit(gpa);
        self.filter.deinit(gpa);
    }
};

const Workload = struct {
    const batch_size = 128;

    input: [batch_size]f32,
    output: *[2][batch_size]f32,

    fn init(gpa: std.mem.Allocator) !Workload {
        var self: Workload = undefined;
        var prng = std.Random.DefaultPrng.init(0x5eed);
        const random = prng.random();
        for (&self.input) |*sample| {
            sample.* = random.float(f32) * 2.0 - 1.0;
        }
        self.output = try gpa.create([2][batch_size]f32);
        self.output[0] = @splat(0);
        self.output[1] = @splat(0);
        return self;
    }

    fn deinit(self: *Workload, gpa: std.mem.Allocator) void {
        gpa.free(self.output);
        self.* = undefined;
    }
};
