const std = @import("std");
const meta = @import("pages");
const net = std.Io.net;


pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const addr: net.IpAddress = .{ 
        .ip4 = .loopback(try std.fmt.parseInt(u16, init.environ_map.get("PORT") orelse "8080", 10)),
    };
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    std.log.info("Listening at http://{f}/\n", .{ addr });
    // for (pages) |page| {
    //     std.log.debug("{s} ({s}) @ {s}", .{page.target, page.content_type, page.path});
    // }
    while (true) {
        const stream = try listener.accept(io);
        const thread = std.Thread.spawn(.{}, serve, .{ gpa, io, stream }) catch |err| {
            std.log.err("Unable to accept connection: {t}", .{err});
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn serve(gpa: std.mem.Allocator, io: std.Io, stream: net.Stream) !void {
    defer stream.close(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    var server: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = server.receiveHead() catch |err| {
        std.log.err("Failed to get request head: {t}", .{err});
        return;
    };
    respond(arena.allocator(), io, &request) catch |err| {
        std.log.err("Failed to respond to request: {t}", .{err});
        return;
    };
}

fn respond(gpa: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request) !void {
    const target = std.mem.trim(u8, request.head.target, "/");
    if (target.len == 0) {
        try request.respond(homepage_contents, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html" },
                .{ .name = "cache-control", .value = "no-store" },
            }
        });
        return;
    }
    for (pages) |page| {
        if (!std.mem.eql(u8, target, page.target)) continue;
        const content = try std.Io.Dir.cwd().readFileAlloc(io, page.path, gpa, .unlimited);
        try request.respond(content, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = page.content_type },
                .{ .name = "cache-control", .value = "no-store" },
            }
        });
        return;
    }
    
    std.log.debug("404: {s}", .{target});
    try request.respond("Not found\n", .{ .status = .not_found });
}

const pages: [meta.page_count]Page = D: {
    var p: [meta.page_count]Page = undefined;
    for (0..p.len) |i| {
        p[i] = .{
            .target = @field(meta, std.fmt.comptimePrint("target_{d}", .{ i })),
            .content_type = @field(meta, std.fmt.comptimePrint("content_type_{d}", .{ i })),
            .path = @field(meta, std.fmt.comptimePrint("path_{d}", .{ i })),
        };
    }
    break :D p;
};

const homepage_contents = std.fmt.comptimePrint(
    \\<!DOCTYPE html>
    \\<head></head>
    \\<body>
    \\<ul>{s}</ul>
    \\</body>
    ,
    .{D: {
        var result: []const u8 = &.{};
        for (pages) |page| {
            if (!std.mem.eql(u8, page.content_type, "text/html")) continue;
            result = result ++ std.fmt.comptimePrint("<li><a href=\"{0s}\">{0s}</a></li>", .{ page.target });
        }
        break :D result;
    }}
);

const Page = struct{
    target: []const u8,
    content_type: []const u8,
    path: []const u8,
};
