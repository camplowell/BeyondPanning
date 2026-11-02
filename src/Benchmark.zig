const std = @import("std");
const Timestamp = std.Io.Timestamp;

const Benchmark = @This();
const sample_size: usize = 1 << 8;

io: std.Io,
gpa: std.mem.Allocator,
max_iters: usize = 100_000_000,
time_budget_ns: u64 = 2 * std.time.ns_per_s,
results: std.ArrayList(Result) = .empty,
max_name_len: usize = 0,

pub fn deinit(self: *Benchmark) void {
    self.results.deinit(self.gpa);
    self.* = undefined;
}

pub fn run(self: *Benchmark, name: []const u8, ctx: anytype, comptime func: fn(@TypeOf(ctx)) void) !void {
    try self.results.append(self.gpa, .{ .name = name });
    self.max_name_len = @max(self.max_name_len, name.len);
    var result = self.results.lastPtr().?;
    // Warm up and calibrate
    const batch_size = self.calibrate(ctx, func);
    result.iters = sample_size * batch_size;
    for (0..sample_size) |i| {
        const start: Timestamp = .now(self.io, .awake);
        for (0..batch_size) |_| {func(ctx);}
        const elapsed: u64 = @intCast(start.untilNow(self.io, .awake).toNanoseconds());
        result.time += elapsed;
        result._samples[i] = elapsed;
    }
    for (&result._samples) |*sample| { sample.* = @divCeil(sample.*, batch_size); }
    std.sort.heap(u64, result._samples[0..@min(sample_size, result.iters)], {}, resultLessThan);
}

fn calibrate(self: Benchmark, ctx: anytype, comptime func: fn(@TypeOf(ctx)) void) usize {
    const start: Timestamp = .now(self.io, .awake);
    const ns_per_target = self.time_budget_ns / sample_size;
    var elapsed: usize = 0;
    var iters: usize = 0;
    var batch_size: usize = 100;
    while (elapsed < self.time_budget_ns and iters < self.max_iters) {
        for (0..@min(batch_size, self.max_iters - iters)) |_| {
            func(ctx);
        }
        iters += batch_size;
        elapsed = @intCast(start.untilNow(self.io, .awake).nanoseconds);
        batch_size = @intCast(@divCeil(iters * ns_per_target, @max(elapsed, 1)));
    }
    return @min(batch_size, @divCeil(self.max_iters, sample_size));
}

fn resultLessThan(context: void, lhs: u64, rhs: u64) bool {
	_ = context;
	return lhs < rhs;
}

pub fn format(
    self: Benchmark,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    _ = try writer.alignBuffer("benchmark", self.max_name_len, .left, ' ');
    try writer.print(
        "    {s:<24} {s:<28}\n",
        .{
            "time/run (avg ± σ)",
            "(min ... max)",
        }
    );
    try writer.splatByteAll('-', self.max_name_len + 61);
    try writer.writeByte('\n');

    for (self.results.items) |*result| {
        try writer.writeAll(result.name);
        try writer.splatByteAll(' ', self.max_name_len - result.name.len);
        try writer.print("    {f}", .{ result });
    }
}

pub const Result = struct {
    name: []const u8,
    time: u64 = 0,
    iters: u64 = 0,
    _samples: [sample_size]u64 = undefined,

    pub fn format(self: Result, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [128]u8 = undefined;
        const start = std.fmt.bufPrint(
            &buf,
            "{d:.2}ns ± {d:.2}ns",
            .{
                self.mean(),
                self.stdDev(),
            }
        ) catch return error.WriteFailed;
        
        try writer.print(
            "{s: <23} ({d:.2}ns ... {d:.2}ns)\n",
            .{
                start,
                self._samples[0],
                self.worst(),
            }
        );
    }

    pub fn samples(self: *const Result) []const u64 {
		return self._samples[0..@min(self.iters, sample_size)];
	}
    
	pub fn worst(self: *const Result) u64 {
		const s = self.samples();
		return s[s.len - 1];
	}
    
	pub fn mean(self: *const Result) f64 {
		const s = self.samples();
    
		var total: u64 = 0;
		for (s) |value| {
			total += value;
		}
		return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(s.len));
	}
    
	pub fn median(self: *const Result) u64 {
		const s = self.samples();
		return s[s.len / 2];
	}
    
	pub fn stdDev(self: *const Result) f64 {
		const m = self.mean();
		const s = self.samples();
    
		var total: f64 = 0.0;
		for (s) |value| {
			const t = @as(f64, @floatFromInt(value)) - m;
			total += t * t;
		}
		const variance = total / @as(f64, @floatFromInt(s.len - 1));
		return std.math.sqrt(variance);
	}
};
