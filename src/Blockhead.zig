//! Blockhead geometric model of the head

const std = @import("std");
const simd = @import("simd.zig");
const Delay = @import("Delay.zig");
const Blockhead = @This();

const UVec = simd.UVec;
const Vec = simd.Vec;

pub const speed_of_sound = 343.0;
const channel_count = 2;

/// in sound-seconds
radius: f32,
/// in sound-seconds
block: f32,
sample_rate: f32,
/// in samples
max_delay: usize,

filter_a0: f32,
filter_a1: f32,

/// Sample rate is in samples per second.
/// Radius and block are in meters.
pub fn init(sample_rate: f32, radius: f32, block: f32) Blockhead {
    const dt_di = 1.0 / sample_rate;
    const r = radius / speed_of_sound;
    const a0 = dt_di + r;
    var self: Blockhead = .{
        .radius = r,
        .block = block / speed_of_sound,
        .sample_rate = sample_rate,
        .filter_a0 = a0,
        .filter_a1 = (dt_di - r) / a0,
        .max_delay = undefined,
    };
    self.max_delay = @ceil(self.getDelay(-1, std.math.pi));
    return self;
}

fn getDelay(self: Blockhead, cos_angle: f32, angle: f32) f32 {
    if (cos_angle > 0.0) return (1.0 - cos_angle) * self.radius * self.sample_rate;
    const contra_angle = (angle - @as(f32, std.math.pi / 2.0));
    const cos_contra_angle = @sqrt(1.0 - cos_angle * cos_angle);
    const arc_len = contra_angle * self.radius;
    return (arc_len + self.block * (1.0 - cos_contra_angle) + self.radius) * self.sample_rate;
}

/// Numerator of the 1-pole filter, normalized.
fn getB(self: Blockhead, angle: f32) [2]f32 {
    const alpha = @mulAdd(f32, 0.85, (1.0 - tanhf(@mulAdd(f32, angle, 1.7, -2.89))), 0.3);
    const spread = self.radius * alpha;
    const dt_di = 1.0 / self.sample_rate;
    return .{ (dt_di + spread) / self.filter_a0, (dt_di - spread) / self.filter_a0 };
}

pub const Filter = struct {
    params: Params,
    target: Params,
    delay_line: Delay,
    x_prev: [2]f32,
    m: []f32,
    delay_mix: []f32,

    pub fn init(
        gpa: std.mem.Allocator, 
        block_len: usize, 
        listener: Blockhead, 
        direction: [3]f32
    ) std.mem.Allocator.Error!Filter {
        const params: Params = .init(listener, direction);
        const buf: []f32 = try gpa.alloc(f32, 2 * block_len + 1);
        errdefer gpa.free(buf);
        var self: Filter = .{
            .params = params,
            .target = params,
            .delay_line = try .init(gpa, block_len + listener.max_delay),
            .x_prev = @splat(0),
            .m = buf[0..block_len],
            .delay_mix = buf[block_len..],
        };
        @memset(self.m, 0);
        for (0..self.delay_mix.len) |t| {
            self.delay_mix[t] = (@as(f32, 1.0) -
                @exp(-std.math.lossyCast(f32, t) * (50.0 / listener.sample_rate)));
        }
        return self;
    }

    pub fn deinit(self: *Filter, gpa: std.mem.Allocator) void {
        self.delay_line.deinit(gpa);
        gpa.free(self.m.ptr[0..self.m.len + self.delay_mix.len]);
        self.* = undefined;
    }

    pub fn process(
        noalias self: *Filter, 
        noalias input: []f32, 
        noalias output: *const [2][]f32
    ) void {
        std.debug.assert(input.len == self.m.len);
        self.delay_line.push(self.filterRecursive(input));
        var new_params: Params = self.target;
        for (0..2) |channel| {
            const current_delay = self.params.delay[channel];
            const delay_off = self.target.delay[channel] - self.params.delay[channel];
            const b = self.params.b[channel];
            var t: usize = 0;
            var x_carry: Vec = @splat(self.x_prev[channel]);
            while (t <= input.len - simd.len) : (t += simd.len) {
                const delay = simd.mulAdd(
                    Vec,
                    @splat(delay_off),
                    self.delay_mix[t..][0..simd.len].*,
                    @splat(current_delay),
                );
                const x0: Vec = self.delay_line.getVec(
                    input.len - t,
                    delay
                );
                const x1 = @shuffle(f32, x_carry, x0, shift_in_mask);
                output[channel][t..][0..simd.len].* = simd.mulAdd(
                    Vec, 
                    x1, 
                    @splat(b[1]), 
                    x0 * simd.splat(Vec, b[0]),
                );
                x_carry = x0;
            }
            var x1: f32 = simd.last(x_carry);
            while (t < input.len) : (t += 1) {
                const delay = @mulAdd(f32, delay_off, self.delay_mix[t], current_delay);
                const x0 = self.delay_line.getOne(input.len - t, delay);
                output[channel][t] = @mulAdd(f32, x1, b[1], x0 * b[0]);
                x1 = x0;
            }
            self.x_prev[channel] = x1;
            new_params.delay[channel] = @mulAdd(f32, delay_off, self.delay_mix[self.delay_mix.len - 1], current_delay);
        }
        self.params = new_params;
        self.params.b = self.target.b;
        self.params.decay = self.target.decay;
    }

    fn filterRecursive(noalias self: *Filter, noalias input: []f32) []f32 {
        std.debug.assert(input.len == self.m.len);
        var y_prev = self.m[self.m.len - 1];
        var t: usize = 0;
        while (t <= input.len - simd.len) : (t += simd.len) {
            const y = self.params.decay.nextVec(input[t..][0..simd.len].*, y_prev);
            self.m[t..][0..simd.len].* = y;
            y_prev = simd.last(y);
        }
        while (t < self.m.len) : (t += 1) {
            const y = self.params.decay.nextScalar(input[t], y_prev);
            self.m[t] = y;
            y_prev = y;
        }
        return self.m;
    }

    const shift_in_mask = D: {
        var mask: [simd.len]i32 = undefined;
        mask[0] = simd.len - 1; // last lane of previous vector
        for (1..simd.len) |lane| mask[lane] = ~@as(i32, @intCast(lane - 1));
        break :D mask;
    };
};

pub const Params = struct {
    delay: [channel_count]f32,
    b: [channel_count][2]f32,
    decay: simd.Decay(Vec),

    pub fn init(head: Blockhead, direction: [3]f32) Params {
        const angle = acosf(direction[1]);
        const angle_r = std.math.pi - angle;
        return .{
            .delay = .{
                head.getDelay(direction[1], angle),
                head.getDelay(-direction[1], angle_r)
            },
            .b = .{ head.getB(angle), head.getB(angle_r) },
            .decay = .init(-head.filter_a1),
        };
    }
};

// Ref: Nicholas Chapman (https://www.forwardscattering.org/post/66)
fn acosf(x: f32) f32 {
    @setFloatMode(.optimized);
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
    @setFloatMode(.optimized);
    if (@abs(x) > 5) return std.math.copysign(@as(f32, 1.0), x);
    const x2 = x * x;
    const num = x * (x2 * (x2 * (378.0 + x2) + 17325.0) + 135135.0);
    const den = (x2 * (x2 * (x2 * 28.0 + 3150.0) + 62370.0) + 135135.0);
    return num / den;
}

test "blockhead delay" {
    const head: Blockhead = .init(48000, 0.087, 0.03);
    try std.testing.expectApproxEqAbs(0.0, head.getDelay(1.0, 0.0), 0.125);
    try std.testing.expectApproxEqAbs(6.087, head.getDelay(0.5, std.math.pi / 3.0), 0.125);
    try std.testing.expectApproxEqAbs(12.175, head.getDelay(0.0, std.math.pi / 2.0), 0.125);
    try std.testing.expectApproxEqAbs(19.112, head.getDelay(-0.5, std.math.pi * 2.0 / 3.0), 0.125);
    try std.testing.expectApproxEqAbs(35.498, head.getDelay(-1.0, std.math.pi), 0.125);
}

test "a1" {
    const head: Blockhead = .init(48000, 0.087, 0.03);
    try std.testing.expectApproxEqAbs(-0.8481965, head.filter_a1, 1e-5);
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
