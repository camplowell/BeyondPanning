//! A fractional delay using a cubic Lagrange interpolator.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const simd = @import("simd.zig");
const Vec = simd.Vec;
const UVec = simd.UVec;

const Delay = @This();

const VDir = @Vector(filter_taps, f32);

const lossyCast = std.math.lossyCast;

const filter_taps = 4;
const mirror_len = simd.len + filter_taps;

data: []f32,
i: usize,
capacity: usize,
mask: u32,

pub fn init(gpa: Allocator, capacity: usize) Allocator.Error!Delay {
    const trueCapacity: usize = @intCast(std.math.ceilPowerOfTwoPromote(usize, @max(capacity + filter_taps, mirror_len)));
    const buf = try gpa.alloc(f32, trueCapacity + mirror_len);
    @memset(buf, 0.0);
    return .{
        .data = buf,
        .i = 0,
        .capacity = trueCapacity,
        .mask = @intCast(trueCapacity - 1),
    };
}

pub fn deinit(self: *Delay, gpa: Allocator) void {
    gpa.free(self.data);
    self.* = undefined;
}

pub fn push(noalias self: *Delay, noalias values: []const f32) void {
    std.debug.assert(values.len < self.capacity);
    const before_wrap = @min(values.len, self.capacity - self.i);
    const wrapped = before_wrap < values.len;
    @memcpy(self.data[self.i..][0..before_wrap], values[0..before_wrap]);
    if (wrapped) {
        @memcpy(self.data[0 .. values.len - before_wrap], values[before_wrap..]);
    }
    if (wrapped or self.i < mirror_len) {
        @memcpy(self.data[self.capacity..][0..mirror_len], self.data[0..mirror_len]);
    }
    self.i = (self.i + values.len) & self.mask;
}


/// Retrieve a scalar or vector of elements from the delay, relative to the most recently added value.
///
/// Expects either f32 or an auto-sized vector of f32.
pub fn get(self: Delay, start: usize, delay: anytype) @TypeOf(delay) {
    return switch (@typeInfo(@TypeOf(delay))) {
        .vector, .array => self.getVec(start, delay),
        .float => self.getOne(start, delay),
        else => @compileError("Expected a float or simd-sized vector!"),
    };
}

/// Retrieve a vector of consecutive output samples.
///
/// ret[i] represents a value `1 + start - i + delay[i]` samples old,
/// where age 0 is the most recently added value.
///
/// The +1 ensures requesting a delay of 0 remains causal.
pub fn getVec(self: Delay, start: usize, delay: Vec) Vec {
    @setFloatMode(.optimized);
    const aligned = delay + simd.splat(Vec, lossyCast(f32, start));
    const aligned_floor: UVec = @floor(aligned);
    const frac = aligned - @floor(aligned);
    std.debug.assert(@reduce(.Min, aligned - simd.iota(Vec)) >= 0);

    const tap: [filter_taps]Vec = if (aligned_floor[0] == aligned_floor[simd.len - 1]) fast: {
        const base = (self.i -% filter_taps -% aligned_floor[0]) & self.mask;
        var tmp: [filter_taps]Vec = undefined;
        inline for (0..filter_taps) |j| tmp[j] = self.data[base + j ..][0..simd.len].*;
        break :fast tmp;
    } else slow: {
        const newest_minus_taps: u32 = @as(u32, @truncate(self.i)) -% filter_taps;
        const slots: [simd.len]u32 = (simd.splat(UVec, newest_minus_taps) +%
            simd.iota(UVec) -%
            aligned_floor) & simd.splat(UVec, self.mask);
        var rows: [simd.len * filter_taps]f32 = undefined;
        inline for (slots, 0..) |slot, lane| {
            rows[lane * filter_taps ..][0..filter_taps].* = self.data[slot..][0..filter_taps].*;
        }
        break :slow std.simd.deinterlace(filter_taps, rows);
    };

    const sixth: Vec = @splat(1.0 / 6.0);
    const half: Vec = @splat(0.5);
    const third: Vec = @splat(1.0 / 3.0);

    const cubic = (tap[0] - tap[3]) * sixth + (tap[2] - tap[1]) * half;
    const quadratic = half * (tap[1] + tap[3]) - tap[2];
    const linear = (-third * tap[3] + (-half * tap[2] + (tap[1] - tap[0] * sixth)));
    const constant = tap[2];

    return (((cubic * frac + quadratic) * frac + linear) * frac + constant);
}

/// Retrieve a sample from the delay.
///
/// The returned value is `1 + start + delay` samples old,
/// where age 0 is the most recently added value.
///
/// The +1 ensures requesting a delay of 0 remains causal.
pub fn getOne(self: Delay, start: usize, delay: f32) f32 {
    @setFloatMode(.optimized);
    std.debug.assert(delay >= 0);
    const delay_floor: usize = @intFromFloat(@floor(delay));
    std.debug.assert(start + delay_floor + filter_taps < self.capacity);
    const x = self.loadVec(self.i -% start -% delay_floor);
    const frac: VDir = @splat(delay - @floor(delay));
    var weights: VDir = frac * VDir{ 1.0 / 6.0, -0.5, 0.5, -1.0 / 6.0 } + VDir{ 0.0, 0.5, -1.0, 0.5 };
    weights = weights * frac + VDir{ -1.0 / 6.0, 1.0, -0.5, -1.0 / 3.0 };
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
    var delay_line = try Delay.init(std.testing.allocator, 64);
    defer delay_line.deinit(std.testing.allocator);

    var samples: [64]f32 = undefined;
    for (&samples, 0..) |*sample, index| {
        sample.* = @as(f32, @floatFromInt(index)); // - 8.0;
    }
    delay_line.push(&samples);

    for (32..48) |t| {
        for (0..16) |d_i| {
            const d: f32 = lossyCast(f32, d_i);
            const expected = samples[t - 2 - d_i ..][0..simd.len];

            const actual: [simd.len]f32 = delay_line.getVec(samples.len - t, @splat(d));
            for (expected, actual) |e, a| {
                try std.testing.expectApproxEqAbs(e, a, 1e-6);
            }
            try std.testing.expectApproxEqAbs(
                expected[0],
                delay_line.getOne(samples.len - t, d),
                1e-6,
            );
        }
    }
}

fn lagrange3(samples: []const f32, position: f64) f32 {
    const base: usize = @intFromFloat(@floor(position));
    const f = position - @floor(position);
    const weights = [4]f64{
        -f * (f - 1) * (f - 2) / 6,
        (f + 1) * (f - 1) * (f - 2) / 2,
        -(f + 1) * f * (f - 2) / 2,
        (f + 1) * f * (f - 1) / 6,
    };
    var sum: f64 = 0;
    for (weights, 0..) |weight, tap| sum += weight * samples[base - 1 + tap];
    return lossyCast(f32, sum);
}

fn testWithSlope(slope: f32) !void {
    var input: [64]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    for (0..input.len) |i| {
        input[i] = random.float(f32) * 2.0 - 1.0;
    }
    var delay_line: Delay = try .init(std.testing.allocator, 64);
    defer delay_line.deinit(std.testing.allocator);
    // Cause wrap in the middle somewhere
    delay_line.push(&@as([24]f32, @splat(0.0)));
    const delay: [simd.len]f32 = (simd.iota(Vec) * simd.splat(Vec, slope) -
        simd.splat(Vec, simd.len * @min(0, slope)) // Ensure delay > 0
    );
    delay_line.push(&input);
    for (32..64 - simd.len) |t| {
        const start = input.len - t;
        const actual_vec: [simd.len]f32 = delay_line.getVec(start, delay);
        for (0.., delay, actual_vec) |off, d, a_vec| {
            std.debug.assert(d >= 0);
            const expected = lagrange3(&input, lossyCast(f64, t - 2 + off) - d);
            try std.testing.expectApproxEqAbs(expected, a_vec, 4e-6);
            try std.testing.expectApproxEqAbs(expected, delay_line.getOne(start - off, d), 4e-6);
        }
    }
}

test "m =-0.05" {
    try testWithSlope(-0.05);
}
test "m = 0.00" {
    try testWithSlope(0.0);
}
test "m = 0.05" {
    try testWithSlope(0.05);
}
test "m = 0.30" {
    try testWithSlope(0.30);
}
test "m = 1.70" {
    try testWithSlope(1.70);
}

//     for ([5]f32{ -0.05, 0.0, 0.05, 0.3, 1.7 }) |slope| {

// test "reproduces cubic polynomial at fractional delays" {
//     var delay_line = try Delay.init(std.testing.allocator, 64);
//     defer delay_line.deinit(std.testing.allocator);

//     const count = 40;
//     pushCubicSignal(&delay_line, count);

//     var delay: f32 = 0.0;
//     while (delay < 12.0) : (delay += 0.37) {
//         try std.testing.expectApproxEqRel(expectedCubic(count, delay), delay_line.getOne(delay), 4e-7);
//     }
// }

// test "constant signal is constant at any fractional delay" {
//     var delay_line = try Delay.init(std.testing.allocator, 32);
//     defer delay_line.deinit(std.testing.allocator);

//     for (0..32) |_| pushOne(&delay_line, 0.75);

//     var delay: f32 = 0.0;
//     while (delay < 10.0) : (delay += 0.13) {
//         try std.testing.expectApproxEqAbs(0.75, delay_line.getOne(delay), 4e-7);
//     }
// }

// test "correct after buffer wraps around" {
//     var delay_line = try Delay.init(std.testing.allocator, 16);
//     defer delay_line.deinit(std.testing.allocator);

//     const count = 100; // several times the capacity
//     for (0..count) |index| {
//         pushOne(&delay_line, cubicSignal(@floatFromInt(index)));
//         if (index < 12) continue;
//         for ([_]f32{ 0.0, 0.5, 1.25, 3.9, 7.5 }) |delay| {
//             try std.testing.expectApproxEqRel(expectedCubic(index + 1, delay), delay_line.getOne(delay), 4e-7);
//         }
//     }
// }

// test "chunked push matches sample-by-sample push" {
//     var single = try Delay.init(std.testing.allocator, 32);
//     defer single.deinit(std.testing.allocator);
//     var chunked = try Delay.init(std.testing.allocator, 32);
//     defer chunked.deinit(std.testing.allocator);

//     var chunk: [7]f32 = undefined;
//     for (0..9) |chunk_index| { // 63 samples, wraps the 32-sample buffer
//         for (&chunk, 0..) |*sample, offset| {
//             sample.* = cubicSignal(@floatFromInt(chunk_index * chunk.len + offset));
//             pushOne(&single, sample.*);
//         }
//         chunked.push(&chunk);
//     }

//     var delay: f32 = 0.0;
//     while (delay < 12.0) : (delay += 0.29) {
//         try std.testing.expectEqual(single.getOne(delay), chunked.getOne(delay));
//     }
// }

// test "vector get matches scalar get per lane" {
//     var delay_line = try Delay.init(std.testing.allocator, 64);
//     defer delay_line.deinit(std.testing.allocator);

//     const count = 50;
//     pushCubicSignal(&delay_line, count);

//     var lane_delays: [simd.len]f32 = undefined;
//     for (&lane_delays, 0..) |*lane, index| lane.* = 0.4 + 0.31 * @as(f32, @floatFromInt(index));
//     const delays: Vec = lane_delays;

//     const result: [simd.len]f32 = delay_line.getVec(simd.len - 1, delays);
//     for (result, lane_delays) |actual, delay| {
//         try std.testing.expectApproxEqRel(delay_line.getOne(delay), actual, 4e-7);
//         try std.testing.expectApproxEqRel(expectedCubic(count, delay), actual, 4e-7);
//     }
// }
//
// test "get dispatches on scalar and vector types" {
//     var delay_line = try Delay.init(std.testing.allocator, 32);
//     defer delay_line.deinit(std.testing.allocator);
//     pushCubicSignal(&delay_line, 20);
//
//     const scalar: f32 = delay_line.get(@as(f32, 2.5));
//     try std.testing.expectEqual(delay_line.getOne(2.5), scalar);
//
//     const vector: Vec = delay_line.get(@as(Vec, @splat(2.5)));
//     for (@as([simd.len]f32, vector)) |lane| try std.testing.expectApproxEqAbs(scalar, lane, 4e-7);
// }

// test "empty delay line returns silence" {
//     var delay_line = try Delay.init(std.testing.allocator, 16);
//     defer delay_line.deinit(std.testing.allocator);

//     try std.testing.expectEqual(@as(f32, 0.0), delay_line.getOne(3.7));
// }

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
