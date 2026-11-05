const std = @import("std");
const Duration = std.Io.Duration;
const Timestamp = std.Io.Timestamp;
const Writer = std.Io.Writer;
const lossyCast = std.math.lossyCast;

const RunFn = fn(std.Io, *anyopaque) Result;
const sample_size = 1000;

const target_interval: u96 = 100 * std.time.ns_per_us;
const max_reps: usize = 100_000;

pub fn runAll(io: std.Io, writer: *std.Io.Writer, tasks: []const Task) std.Io.Writer.Error!void {
    const name_col_width = try printHeader(writer, tasks);
    for (tasks) |task| {
        try writer.alignBuffer(task.name, name_col_width, .left, ' ');
        try writer.flush();
        const result = task.func(io, task.ctx);
        try result.format(writer, task.opts);
        try writer.writeByte('\n');
        try writer.flush();
    }
}

pub const Task = struct {
    name: []const u8,
    ctx: *anyopaque,
    func: *const RunFn,
    opts: Options,

    /// Create a task based on a function and a pointer to the context it needs.
    pub fn init(
        comptime name: []const u8, 
        ctx: anytype,
        comptime func: fn(@TypeOf(ctx))void,
        options: Options,
    ) Task {
        if (@typeInfo(@TypeOf(ctx)) != .pointer) @compileError("Must be a pointer to a stable value");
        return .{
            .name = name,
            .ctx = @ptrCast(ctx),
            .func = runner(@TypeOf(ctx), func),
            .opts = options,
        };
    }

    const Options = struct {
        frames_per_call: usize = 128,
        sample_rate: usize = 48000,
    };
};

fn printHeader(writer: *std.Io.Writer, tasks: []const Task) std.Io.Writer.Error!usize {
    const name_col_width = D: {
        var v: usize = 0;
        for (tasks) |task| v = @max(v, task.name.len);
        break :D v;
    } + 4;
    try writer.alignBuffer("Task", name_col_width, .left, ' ');
    const header_size = try Result.header(writer);
    try writer.splatByteAll('-', name_col_width + header_size);
    try writer.writeByte('\n');
    try writer.flush();
    return name_col_width;
}

fn runner(T: type, func: fn(T) void) RunFn {
    return struct {
        fn run(io: std.Io, ctx_opaque: *anyopaque) Result {
            const ctx = @as(T, @alignCast(@ptrCast(ctx_opaque)));
            var measurements: [sample_size]Duration = undefined;
            // Calibrate and warmup
            var reps: usize = 1;
            while (batch(io, ctx, reps).nanoseconds < target_interval) {
                if (reps > max_reps) break;
                reps *= 2;
            }
            // Measured samples
            for (0..sample_size) |i| measurements[i] = batch(io, ctx, reps);

            return .init(&measurements, lossyCast(f64, reps));
        }

        fn batch(io: std.Io, ctx: T, reps: usize) std.Io.Duration {
            const start: Timestamp = .now(io, .awake);
            for (0..reps) |_| func(ctx);
            return start.untilNow(io, .awake);
        }
    }.run;
}

pub const Result = struct {
    const i_p50 = @divExact(sample_size, 2);
    const i_p25 = @divExact(sample_size, 4);
    const i_p75 = 3 * i_p25;
    const i_p99 = sample_size - @divExact(sample_size, 100);
    
    median: u64,
    iqr: f64,
    p99: u64,
    max: u64,

    pub fn init(samples: *[sample_size]Duration, reps_per_sample: f64) Result {
        std.mem.sort(Duration, samples, {}, compDurations);
        return .{
            .median = @round(lossyCast(f64, samples[i_p50].nanoseconds) / reps_per_sample),
            .iqr = lossyCast(
                f64,
                samples[i_p75].nanoseconds - samples[i_p25].nanoseconds,
            ) / reps_per_sample,
            .p99 = @round(lossyCast(f64, samples[i_p99].nanoseconds) / reps_per_sample),
            .max = @round(lossyCast(f64, samples[samples.len - 1].nanoseconds) / reps_per_sample),
        };
    }

    pub fn header(
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!usize {
        try writer.print("| {s: ^12} | {s: ^10} | {s: ^10} | {s: ^10} | {s: ^10}\n", .{
            "median (ns)",
            "IQR (ns)",
            "p99 (ns)",
            "max (ns)",
            "X realtime",
        });
        return 66;
    }

    pub fn format(
        self: Result,
        writer: *std.Io.Writer,
        options: Task.Options,
    ) std.Io.Writer.Error!void {
        const rt_period = std.time.ns_per_s * lossyCast(f64, options.frames_per_call) / lossyCast(f64, options.sample_rate);
        try writer.print("| {d: >12} | {d: >10.2} | {d: >10} | {d: >10} | {d: >10.1}", .{
            self.median,
            self.iqr,
            self.p99,
            self.max,
            rt_period / std.math.lossyCast(f64, self.p99),
        });
    }
};

fn compDurations(ctx: void, lhs: Duration, rhs: Duration) bool {
    _ = ctx;
    return lhs.nanoseconds < rhs.nanoseconds;
}
