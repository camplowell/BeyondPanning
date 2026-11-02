//! Not pulled into the build yet.

const std = @import("std");
const Delay = @import("Delay.zig");
const Blockhead = @This();

radius: f32,
block: f32,
sample_rate: f32,

pub const Params = struct {
    delay: [2]f32,
    b: [2]f32,
    a1: f32,
    
    pub fn init(listener: Blockhead, direction: [3]f32) Params {
        const angle = acosf(direction[1]);
        const angle_r = std.math.pi - angle;
    }
};


// Ref: Nicholas Chapman (https://www.forwardscattering.org/post/66)
pub fn acosf(x: f32) f32 {
    if (x < 0) {
        return std.math.pi - (
            (x * 0.124605335 + 0.1570634) *
            (0.99418175 + x) +
            @sqrt(x * 2 + 2)
        );
    }
    return (
        (x * -0.124605335 + 0.1570634) *
        (0.99418175 - x) +
        @sqrt(x * -2 + 2)
    );
}

/// [7/6] Padé approximate for tanh
pub fn tanhf(x: f32) f32 {
    if (@abs(x) > 5) return std.math.copysign(@as(f32, 1.0), x);
    const x2 = x * x;
    const num = x * (x2 * (x2 * (378.0 + x2) + 17325.0) + 135135.0);
    const den = (x2 * (x2 * (x2 * 28.0 + 3150.0) + 62370.0) + 135135.0);
    return num / den;
}
