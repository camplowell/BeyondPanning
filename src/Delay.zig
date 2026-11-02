//! A fractional delay using a cubic Lagrange interpolator.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const simd = @import("simd.zig");
const Vec = simd.Vec;
const UVec = simd.UVec;

const Delay = @This();

const VDir = @Vector(filter_taps, f32);

const filter_taps = 4;
const mirror_len = simd.len + filter_taps;

data: []f32,
i: usize,
capacity: usize,
mask: usize,

pub fn init(gpa: Allocator, capacity: usize) Allocator.Error!Delay {
    const trueCapacity: usize = @intCast(std.math.ceilPowerOfTwoPromote(usize, @max(capacity + filter_taps, mirror_len)));
    const buf = try gpa.alloc(f32, trueCapacity + mirror_len);
    @memset(buf, 0.0);
    return .{
        .data = buf,
        .i = 0,
        .capacity = trueCapacity,
        .mask = trueCapacity - 1,
    };
}

pub fn deinit(self: *Delay, gpa: Allocator) void {
    gpa.free(self.data);
    self.* = undefined;
}

pub fn push(self: *Delay, values: []const f32) void {
    std.debug.assert(values.len < self.capacity);
    const before_wrap = @min(values.len, self.capacity - self.i);
    const wrapped = before_wrap < values.len;
    @memcpy(self.data[self.i..][0..before_wrap], values[0..before_wrap]);
    if (wrapped) {
        @memcpy(self.data[0..values.len - before_wrap], values[before_wrap..]);
    }
    if (wrapped or self.i < mirror_len) {
        @memcpy(self.data[self.capacity..][0..mirror_len], self.data[0..mirror_len]);
    }
    self.i = (self.i + values.len) & self.mask;
}

/// Retrieve a scalar or vector of elements from the delay, relative to the most recently added value.
/// 
/// Expects either f32 or an auto-sized vector of f32.
pub fn get(self: Delay, delay: anytype) @TypeOf(delay) {
    return switch (@typeInfo(@TypeOf(delay))) {
        .vector, .array => self.getVec(delay),
        .float => self.getOne(delay),
        else => @compileError("Expected a float or simd-sized vector!"),
    };
}

pub fn getVec(self: Delay, delay: Vec) Vec {
    @setFloatMode(.optimized);
    const aligned: Vec = delay + @as(Vec, @floatFromInt(std.simd.iota(u32, simd.len)));
    const lowest = @min(aligned[0], aligned[simd.len - 1]);
    const highest = @max(aligned[0], aligned[simd.len - 1]);
    const tap: [filter_taps]Vec = if (highest - lowest <= 0.5) D: {
        const reference: f32 = @floor(lowest);
        const base = (self.i -% filter_taps -% @as(usize, @intFromFloat(reference))) & self.mask;
        
        var tap: [filter_taps]Vec = undefined;
        inline for (0..filter_taps) |j| tap[j] = self.data[base + j ..][0..simd.len].*;
        break :D tap;
    } else D: {
        const d_i: UVec = @floor(delay);
        var direct: [simd.len * filter_taps]f32 = undefined;
        inline for (0.., @as([simd.len]u32, d_i)) |k, d_k| {
            direct[4 * k..][0..4].* = self.loadVec(self.i -% d_k);
        }
        break :D std.simd.deinterlace(4, direct);
    };

    const frac = delay - @floor(delay);

    const sixth: Vec = @splat(1.0 / 6.0);
    const half: Vec = @splat(0.5);
    const third: Vec = @splat(1.0 / 3.0);
    
    const cubic = (tap[0] - tap[3]) * sixth + (tap[2] - tap[1]) * half;
    const quadratic = half * (tap[1] + tap[3]) - tap[2];
    const linear = (-third * tap[3] + (-half * tap[2] + (tap[1] - tap[0] * sixth)));
    const constant = tap[2];

    
    return (((cubic * frac + quadratic) * frac + linear) * frac + constant);

//     const tap_coefficients = [filter_taps][4]f32{
//         .{ 1.0 / 6.0, 0.0, -1.0 / 6.0, 0.0 },
//         .{ -0.5, 0.5, 1.0, 0.0 },
//         .{ 0.5, -1.0, -0.5, 1.0 },
//         .{ -1.0 / 6.0, 0.5, -1.0 / 3.0, 0.0 },
//     };
// 
//     var result: Vec = @splat(0.0);
//     inline for (tap_coefficients, tap) |coefficients, tap_samples| {
//         var weight: Vec = @splat(coefficients[0]);
//         inline for (coefficients[1..]) |coefficient| {
//             weight = weight * frac + @as(Vec, @splat(coefficient));
//         }
//         result = tap_samples * weight + result;
//     }
//     return result;
}

/// Retrieve one element from the delay, relative to the most recently added value.
/// 
/// Introduces one extra sample of delay to ensure causality.
pub fn getOne(self: Delay, delay: f32) f32 {
    @setFloatMode(.optimized);
    const d_i: usize = @as(usize, @floor(delay));
    std.debug.assert(d_i + filter_taps < self.capacity);
    const x = self.loadVec(self.i -% d_i);
    const frac: VDir = @splat(delay - @floor(delay));
    var weights: VDir = frac * VDir{ 1.0/6.0, -0.5, 0.5, -1.0/6.0 } + VDir{ 0.0, 0.5, -1.0, 0.5 };
    weights = weights * frac + VDir{ -1.0/6.0, 1.0, -0.5, -1.0/3.0 };
    weights = weights * frac + VDir{ 0.0, 0.0, 1.0, 0.0 };
    return @reduce(.Add, x * weights);
}

/// Loads filter_taps contiguous samples around base_off (direct orientation).
/// 
/// Introduces one extra sample of delay to ensure causality.
fn loadVec(self: Delay, base_off: usize) [filter_taps]f32 {
    const start = (base_off -% filter_taps) & self.mask;
    return self.data[start..][0..filter_taps].*;
}


test "integer delays return exact past samples" {
    var delay_line = try Delay.init(std.testing.allocator, 32);
    defer delay_line.deinit(std.testing.allocator);

    var samples: [20]f32 = undefined;
    for (&samples, 0..) |*sample, index| {
        sample.* = @as(f32, @floatFromInt(index * index % 17)) - 8.0;
        pushOne(&delay_line, sample.*);
    }

    for (0..10) |whole_delay| {
        const expected = samples[samples.len - 1 - whole_delay - 1];
        const actual = delay_line.getOne(@floatFromInt(whole_delay));
        try std.testing.expectApproxEqAbs(expected, actual, 1e-6);
    }
}

test "reproduces cubic polynomial at fractional delays" {
    var delay_line = try Delay.init(std.testing.allocator, 64);
    defer delay_line.deinit(std.testing.allocator);

    const count = 40;
    pushCubicSignal(&delay_line, count);

    var delay: f32 = 0.0;
    while (delay < 12.0) : (delay += 0.37) {
        try std.testing.expectApproxEqRel(expectedCubic(count, delay), delay_line.getOne(delay), 4e-7);
    }
}

test "constant signal is constant at any fractional delay" {
    var delay_line = try Delay.init(std.testing.allocator, 32);
    defer delay_line.deinit(std.testing.allocator);

    for (0..32) |_| pushOne(&delay_line, 0.75);

    var delay: f32 = 0.0;
    while (delay < 10.0) : (delay += 0.13) {
        try std.testing.expectApproxEqAbs(0.75, delay_line.getOne(delay), 4e-7);
    }
}

test "correct after buffer wraps around" {
    var delay_line = try Delay.init(std.testing.allocator, 16);
    defer delay_line.deinit(std.testing.allocator);

    const count = 100; // several times the capacity
    for (0..count) |index| {
        pushOne(&delay_line, cubicSignal(@floatFromInt(index)));
        if (index < 12) continue;
        for ([_]f32{ 0.0, 0.5, 1.25, 3.9, 7.5 }) |delay| {
            try std.testing.expectApproxEqRel(expectedCubic(index + 1, delay), delay_line.getOne(delay), 4e-7);
        }
    }
}

test "chunked push matches sample-by-sample push" {
    var single = try Delay.init(std.testing.allocator, 32);
    defer single.deinit(std.testing.allocator);
    var chunked = try Delay.init(std.testing.allocator, 32);
    defer chunked.deinit(std.testing.allocator);

    var chunk: [7]f32 = undefined;
    for (0..9) |chunk_index| { // 63 samples, wraps the 32-sample buffer
        for (&chunk, 0..) |*sample, offset| {
            sample.* = cubicSignal(@floatFromInt(chunk_index * chunk.len + offset));
            pushOne(&single, sample.*);
        }
        chunked.push(&chunk);
    }

    var delay: f32 = 0.0;
    while (delay < 12.0) : (delay += 0.29) {
        try std.testing.expectEqual(single.getOne(delay), chunked.getOne(delay));
    }
}

test "vector get matches scalar get per lane" {
    var delay_line = try Delay.init(std.testing.allocator, 64);
    defer delay_line.deinit(std.testing.allocator);

    const count = 50;
    pushCubicSignal(&delay_line, count);

    var lane_delays: [simd.len]f32 = undefined;
    for (&lane_delays, 0..) |*lane, index| lane.* = 0.4 + 0.31 * @as(f32, @floatFromInt(index));
    const delays: Vec = lane_delays;

    const result: [simd.len]f32 = delay_line.getVec(delays);
    for (result, lane_delays) |actual, delay| {
        try std.testing.expectApproxEqRel(delay_line.getOne(delay), actual, 4e-7);
        try std.testing.expectApproxEqRel(expectedCubic(count, delay), actual, 4e-7);
    }
}

test "get dispatches on scalar and vector types" {
    var delay_line = try Delay.init(std.testing.allocator, 32);
    defer delay_line.deinit(std.testing.allocator);
    pushCubicSignal(&delay_line, 20);

    const scalar: f32 = delay_line.get(@as(f32, 2.5));
    try std.testing.expectEqual(delay_line.getOne(2.5), scalar);

    const vector: Vec = delay_line.get(@as(Vec, @splat(2.5)));
    for (@as([simd.len]f32, vector)) |lane| try std.testing.expectApproxEqAbs(scalar, lane, 4e-7);
}

test "empty delay line returns silence" {
    var delay_line = try Delay.init(std.testing.allocator, 16);
    defer delay_line.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(f32, 0.0), delay_line.getOne(3.7));
}

fn pushOne(delay_line: *Delay, value: f32) void {
    var buffer = [1]f32{value};
    delay_line.push(&buffer);
}

fn cubicSignal(index: f64) f32 {
    const x = index * 0.1;
    const result: f64 = 0.5 + 0.8 * x - 0.3 * x * x + 0.05 * x * x * x;
    return @floatCast(result);
}

fn pushCubicSignal(delay_line: *Delay, count: usize) void {
    for (0..count) |index| pushOne(delay_line, cubicSignal(@floatFromInt(index)));
}

fn expectedCubic(count: usize, delay: f32) f32 {
    const newest: f64 = @floatFromInt(count - 1);
    return cubicSignal(newest - delay - 1);
}
