//! Blockhead geometric model of the head

const std = @import("std");
const simd = @import("simd.zig");
const Delay = @import("Delay.zig");
const Blockhead = @This();

const UVec = simd.UVec;
const Vec = simd.Vec;

pub const speed_of_sound = 343.0;

radius: f32,
block: f32,
sample_rate: f32,
/// Only used to normalize the other filter parameters.
a0: f32,
/// Denominator of the 1-pole filter, normalized.
na1: f32,
/// Max possible delay at the current parameters, in samples.
max_delay: usize,

pub fn init(sample_rate: f32, radius: f32, block: f32) Blockhead {
    const dt_di = 1.0 / sample_rate;
    const r_norm = radius / speed_of_sound;
    const a0 = dt_di + r_norm;
    var self: Blockhead = .{
        .radius = r_norm,
        .block = block / speed_of_sound,
        .sample_rate = sample_rate,
        .a0 = a0,
        .na1 = -(dt_di - r_norm) / a0,
        .max_delay = undefined,
    };
    self.max_delay = @ceil(self.delayOf(-1, std.math.pi));
    return self;
}

pub const Params = struct {
    delay: [2]f32,
    b: [2][2]f32,
    na1: f32,

    pub fn init(listener: Blockhead, direction: [3]f32) Params {
        const angle = acosf(direction[1]);
        const angle_r = std.math.pi - angle;
        return .{
            .delay = .{
                listener.delayOf(direction[1], angle),
                listener.delayOf(-direction[1], angle_r),
            },
            .b = .{ listener.getB(angle), listener.getB(angle_r) },
            .na1 = listener.na1,
        };
    }
};

pub const Filter = struct {
    params: Params,
    target: Params,
    delay: Delay,
    x1: [2]f32,
    y1: [2]f32,
    delay_mix: []f32,

    const shift_in_mask = D: {
        var mask: [simd.len]i32 = undefined;
        mask[0] = simd.len - 1; // last lane of previous vector
        for (1..simd.len) |lane| mask[lane] = ~@as(i32, @intCast(lane - 1));
        break :D mask;
    };

    pub fn init(gpa: std.mem.Allocator, block_len: usize, listener: Blockhead, direction: [3]f32) std.mem.Allocator.Error!Filter {
        var self: Filter = .{
            .params = .init(listener, direction),
            .target = undefined,
            .delay = try .init(gpa, block_len + listener.max_delay),
            .x1 = @splat(0.0),
            .y1 = @splat(0.0),
            .delay_mix = try gpa.alloc(f32, block_len + 1),
        };
        self.target = self.params;
        for (0..block_len + 1) |i| {
            self.delay_mix[i] = @as(f32, 1.0) - @exp(-std.math.lossyCast(f32, i) *
                (50.0 / listener.sample_rate));
        }
        return self;
    }

    pub fn deinit(self: *Filter, gpa: std.mem.Allocator) void {
        self.delay.deinit(gpa);
        gpa.free(self.delay_mix);
        self.* = undefined;
    }

    pub fn process(noalias self: *Filter, noalias input: []f32, output: [2][]f32) void {
        @setFloatMode(.optimized);
        std.debug.assert(input.len == self.delay_mix.len - 1);
        for (0..2) |channel| {
            const delay_offset = self.target.delay[channel] - self.params.delay[channel];

            const b0: Vec = @splat(self.params.b[channel][0]);
            const b1: Vec = @splat(self.params.b[channel][1]);
            var x1: Vec = @splat(self.x1[channel]);
            var y1 = self.y1[channel];

            var t: usize = 0;
            var delay_base = input.len;
            while (t + simd.len <= input.len) : ({
                t += simd.len;
                delay_base -= simd.len;
            }) {
                const delay = simd.mulAdd(
                    Vec,
                    @splat(delay_offset),
                    self.delay_mix[t..][0..simd.len].*,
                    @splat(self.params.delay[channel]),
                );
                const x0 = self.delay.getVec(delay_base, delay);
                const x0_s = @shuffle(f32, x1, x0, shift_in_mask);
                const m = simd.mulAdd(Vec, x0_s, b1, x0 * b0);
                x1 = x0;
                const out = output[channel][t..][0..simd.len];
                inline for (0..simd.len) |lane| {
                    y1 = @mulAdd(f32, self.params.na1, y1, m[lane]);
                    out[lane] = y1;
                }
            }

            self.x1[channel] = x1[simd.len - 1];
            self.y1[channel] = y1;

            while (t < input.len) : ({
                t += 1;
                delay_base -= 1;
            }) {
                const delay = @mulAdd(f32, delay_offset, self.delay_mix[t], self.params.delay[channel]);
                const x = self.delay.getOne(delay_base, delay);
                output[channel][t] = self.onePole(channel, x);
            }
            self.params.delay[channel] += delay_offset * self.delay_mix[self.delay_mix.len - 1];
        }
    }

    fn onePole(self: *Filter, channel: usize, x: f32) f32 {
        const b = self.params.b[channel];
        const na = self.params.na1;
        const y = @mulAdd(f32, x, b[0], @mulAdd(f32, self.x1[channel], b[1], self.y1[channel] * na));
        self.x1[channel] = x;
        self.y1[channel] = y;
        return y;
    }
};


/// Numerator of the 1-pole filter, normalized.
fn getB(self: Blockhead, angle: f32) [2]f32 {
    const alpha = @mulAdd(f32, 0.85, (1.0 - tanhf(@mulAdd(f32, angle, 1.7, -2.89))), 0.3);
    const spread = self.radius * alpha;
    const dt_di = 1.0 / self.sample_rate;
    return .{ (dt_di + spread) / self.a0, (dt_di - spread) / self.a0 };
}

/// Delay at a direction, in samples
fn delayOf(self: Blockhead, cos_angle: f32, angle: f32) f32 {
    if (cos_angle > 0) return (1.0 - cos_angle) * self.radius * self.sample_rate;
    const contra_angle = (angle - @as(f32, std.math.pi / 2.0));
    const cos_contra_angle = @sqrt(1.0 - cos_angle * cos_angle);
    const arc_len = contra_angle * self.radius;
    return (arc_len + self.block * (1.0 - cos_contra_angle) + self.radius) * self.sample_rate;
}

fn mix(T: type, a: anytype, b: anytype, fac: anytype) T {
    const fb = simd.splat(T, fac);
    const fa = switch (@typeInfo(@TypeOf(fac))) {
        .vector, .array => simd.splat(T, 1.0) - @as(T, fac),
        else => simd.splat(T, 1.0 - fac),
    };
    return fa * simd.splat(T, a) + fb * simd.splat(T, b);
}

// Ref: Nicholas Chapman (https://www.forwardscattering.org/post/66)
fn acosf(x: f32) f32 {
    if (x < 0) {
        return std.math.pi - ((x * 0.124605335 + 0.1570634) *
            (0.99418175 + x) +
            @sqrt(x * 2 + 2));
    }
    return ((x * -0.124605335 + 0.1570634) *
        (0.99418175 - x) +
        @sqrt(x * -2 + 2));
}

/// [7/6] Padé approximate for tanh
fn tanhf(x: f32) f32 {
    if (@abs(x) > 5) return std.math.copysign(@as(f32, 1.0), x);
    const x2 = x * x;
    const num = x * (x2 * (x2 * (378.0 + x2) + 17325.0) + 135135.0);
    const den = (x2 * (x2 * (x2 * 28.0 + 3150.0) + 62370.0) + 135135.0);
    return num / den;
}

test "blockhead delay" {
    const head: Blockhead = .init(48000, 0.087, 0.03);
    try std.testing.expectApproxEqAbs(0.0, head.delayOf(1.0, 0.0), 0.125);
    try std.testing.expectApproxEqAbs(6.087, head.delayOf(0.5, std.math.pi / 3.0), 0.125);
    try std.testing.expectApproxEqAbs(12.175, head.delayOf(0.0, std.math.pi / 2.0), 0.125);
    try std.testing.expectApproxEqAbs(19.112, head.delayOf(-0.5, std.math.pi * 2.0 / 3.0), 0.125);
    try std.testing.expectApproxEqAbs(35.498, head.delayOf(-1.0, std.math.pi), 0.125);
}

test "a1" {
    const head: Blockhead = .init(48000, 0.087, 0.03);
    try std.testing.expectApproxEqAbs(-0.8481965, head.a1, 1e-5);
}

test "b ipsilateral" {
    const head: Blockhead = .init(48000, 0.087, 0.03);
    const actual = head.getB(0);
    try std.testing.expectApproxEqAbs(1.91926099, actual[0], 1e-5);
    try std.testing.expectApproxEqAbs(-1.7674574, actual[1], 1e-5);
}

test "b neutral" {
    const head: Blockhead = .init(48000, 0.087, 0.03);
    const actual = head.getB(std.math.pi / 2.0);
    try std.testing.expectApproxEqAbs(1.3084212, actual[0], 1e-5);
    try std.testing.expectApproxEqAbs(-1.1566177, actual[1], 1e-5);
}

test "b contralateral" {
    const head: Blockhead = .init(48000, 0.087, 0.03);
    const actual = head.getB(std.math.pi);
    try std.testing.expectApproxEqAbs(0.3647268, actual[0], 1e-5);
    try std.testing.expectApproxEqAbs(-0.2129233, actual[1], 1e-5);
}
