const std = @import("std");
const builtin = @import("builtin");
const Delay = @import("Delay.zig");
const simd = @import("simd.zig");

const batch_size = 128;
const warmup_batches = 100_000;
const timed_batches = 200_000_000;
const max_delay_samples = 100.0;

const is_wasm = builtin.cpu.arch.isWasm() and builtin.os.tag == .freestanding;

fn runTask(ctx: Ctx(), name: []const u8, comptime kernel: fn (*Delay, *Workload) void, delay: *Delay, workload: *Workload) void {
    for (0..warmup_batches) |_| kernel(delay, workload);
    const start = ctx.nanoseconds();
    for (0..timed_batches) |_| kernel(delay, workload);
    const elapsed_nanoseconds: f64 = @floatFromInt(ctx.nanoseconds() - start);
    std.mem.doNotOptimizeAway(workload.output);
    std.mem.doNotOptimizeAway(delay.i);

    const nanoseconds_per_batch = elapsed_nanoseconds / timed_batches;
    const nanoseconds_per_sample = nanoseconds_per_batch / batch_size;
    // ctx.print("{s}:\t{d:2.2} ns\t{d:2.2} ns\n", .{ name, nanoseconds_per_batch, nanoseconds_per_sample});
    _ = nanoseconds_per_sample;
    _ = name;
}

fn runAll(ctx: Ctx()) !void {
    var delay: Delay = try .init(ctx.gpa, 256);
    defer delay.deinit(ctx.gpa);
    const workload: Workload = .init();
    _ = workload;
    // _ = ctx;
    // runTask(ctx, "push only", pushOnly, &delay, &workload);
}

fn Ctx() type {
    return struct {
        extern "env" fn nowMilliseconds() f64;
        extern "env" fn write(ptr: [*]const u8, len: usize) void;

        gpa: std.mem.Allocator,

        pub fn init() @This() {
            return .{
                .gpa = std.heap.wasm_allocator,
            };
        }
    
        pub fn nanoseconds(_: @This()) u64 {
            return @intFromFloat(nowMilliseconds() * 1_000_000.0);
        }

        pub fn print(_: @This(), comptime fmt: []const u8, args: anytype) void {
            var buffer: [512]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, fmt, args) catch buffer[0..];
            write(text.ptr, text.len);
        }
    };
//     return if (is_wasm) struct {
//         extern "env" fn nowMilliseconds() f64;
//         extern "env" fn write(ptr: [*]const u8, len: usize) void;
// 
//         gpa: std.mem.Allocator,
// 
//         pub fn init() @This() {
//             return .{
//                 .gpa = std.heap.wasm_allocator,
//             };
//         }
//     
//         pub fn nanoseconds(_: @This()) u64 {
//             return @intFromFloat(nowMilliseconds() * 1_000_000.0);
//         }
// 
//         pub fn print(_: @This(), comptime fmt: []const u8, args: anytype) void {
//             var buffer: [512]u8 = undefined;
//             const text = std.fmt.bufPrint(&buffer, fmt, args) catch buffer[0..];
//             write(text.ptr, text.len);
//         }
//     } else struct {
//         io: *std.Io,
//         gpa: std.mem.Allocator,
// 
//         pub fn init() @This() {
//             return .{ .io = std.Io.Threaded.global_single_threaded, .gpa = std.heap.smp_allocator };
//         }
// 
//         pub fn nanoseconds(self: @This()) u64 {
//             return @intCast(std.Io.Clock.awake.now(self.io).nanoseconds);
//         }
// 
//         pub fn print(_: @This(), comptime fmt: []const u8, args: anytype) void {
//             std.debug.print(fmt, args);
//         }
//     };
}

pub fn main() !void {
    try runAll(.init());
}

// 
// 
// pub fn main(init: std.process.Init) !void {
//     comptime {
//         std.debug.assert(batch_size % simd.len == 0);
//     }
//     const gpa = init.gpa;
//     const io = init.io;
// 
//     var delay_line = try Delay.init(gpa, 256);
//     defer delay_line.deinit(gpa);
// 
//     var workload = Workload.init();
//     // std.debug.print(
//     //     "batch={d} simd.len={d} warmup={d} timed={d} batches\n",
//     //     .{ batch_size, simd.len, warmup_batches, timed_batches },
//     // );
//     run("push only", io, &delay_line, &workload, pushOnly);
//     run("push + getOne", io, &delay_line, &workload, pushAndGetScalar);
//     run("push + getVec", io, &delay_line, &workload, pushAndGetVector);
//     run("getVec only", io, &delay_line, &workload, getVectorOnly);
// }
// 
const Workload = struct {
    input: [batch_size]f32,
    delays: [batch_size]f32,
    output: [batch_size]f32,

    fn init() Workload {
        var workload: Workload = undefined;
        var prng = std.Random.DefaultPrng.init(0x5eed);
        const random = prng.random();
        const mix = 1.0 - @exp(-50.0 / 48000.0);
        var smoothed: f32 = 0.0;
        const target: f32 = 30.0;
        for (&workload.input, &workload.delays, 0..) |*sample, *delay, index| {
            sample.* = random.float(f32) * 2.0 - 1.0;
            // Smoothly modulated delay in [1, max_delay_samples], like a chorus/flanger.
            // const phase = std.math.tau * @as(f32, @floatFromInt(index)) / (44100.0 / 50.0);
            smoothed += (target - smoothed) * mix;
            delay.* = smoothed + @as(f32, @floatFromInt(batch_size - 1 - index));
        }
        @memset(&workload.output, 0.0);
        return workload;
    }
};

fn pushOnly(delay_line: *Delay, workload: *Workload) void {
    delay_line.push(&workload.input);
}
// 
// fn pushAndGetScalar(delay_line: *Delay, workload: *Workload) void {
//     delay_line.push(&workload.input);
//     for (&workload.output, workload.delays) |*out, delay| {
//         out.* = delay_line.getOne(delay);
//     }
//     std.mem.doNotOptimizeAway(&workload.output);
// }
// 
// fn pushAndGetVector(delay_line: *Delay, workload: *Workload) void {
//     delay_line.push(&workload.input);
//     var offset: usize = 0;
//     while (offset < batch_size) : (offset += simd.len) {
//         const delays: simd.Vec = workload.delays[offset..][0..simd.len].*;
//         workload.output[offset..][0..simd.len].* = delay_line.getVec(delays);
//     }
//     std.mem.doNotOptimizeAway(&workload.output);
// }
// 
// fn getVectorOnly(delay_line: *Delay, workload: *Workload) void {
//     var offset: usize = 0;
//     while (offset < batch_size) : (offset += simd.len) {
//         const delays: simd.Vec = workload.delays[offset..][0..simd.len].*;
//         workload.output[offset..][0..simd.len].* = delay_line.getVec(delays);
//     }
//     std.mem.doNotOptimizeAway(&workload.output);
// }
// 
// fn nowNanoseconds(io: std.Io) i96 {
//     return std.Io.Clock.awake.now(io).nanoseconds;
// }
