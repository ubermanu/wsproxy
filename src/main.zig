const std = @import("std");
const proxy = @import("proxy.zig");

pub const std_options: std.Options = .{ .log_level = .info };

const log = std.log.scoped(.wsproxy);

const usage =
    \\WebSocket to TCP proxy for roBrowserLegacy.
    \\
    \\Usage: wsproxy [options]
    \\
    \\Options:
    \\  -p, --port PORT          Port to listen on (env: PORT, default: 5999)
    \\  -a, --allow HOST:PORT,...
    \\                           Comma separated list of targets the proxy may connect to
    \\  -h, --help               Print this help
    \\
;

const Options = struct {
    port: u16 = 5999,
    allow: []const u8 = "",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const options = parseOptions(args[1..], init.environ_map.get("PORT")) catch |err| switch (err) {
        error.Help => {
            try std.Io.File.stdout().writeStreamingAll(io, usage);
            return;
        },
        else => {
            std.debug.print("error: {t}\n\n{s}", .{ err, usage });
            std.process.exit(2);
        },
    };

    const allow: proxy.AllowList = .{ .list = options.allow };
    if (allow.isEmpty()) {
        log.warn("no --allow list given: the proxy relays to any requested host:port", .{});
    }

    const address: std.Io.net.IpAddress = .{ .ip4 = .unspecified(options.port) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    log.info("listening on port {d}", .{options.port});
    try proxy.serve(io, &server, allow);
}

fn parseOptions(args: []const []const u8, port_env: ?[]const u8) !Options {
    var options: Options = .{};
    if (port_env) |port| options.port = try parsePort(port);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "-h") or eql(arg, "--help")) return error.Help;
        if (try value(args, &i, "-p", "--port")) |port| {
            options.port = try parsePort(port);
        } else if (try value(args, &i, "-a", "--allow")) |list| {
            options.allow = list;
        } else {
            return error.UnknownOption;
        }
    }
    return options;
}

/// Accepts `-x VALUE`, `--name VALUE` and `--name=VALUE`.
fn value(args: []const []const u8, i: *usize, short: []const u8, long: []const u8) !?[]const u8 {
    const arg = args[i.*];
    if (std.mem.cutPrefix(u8, arg, long)) |rest| {
        if (std.mem.cutPrefix(u8, rest, "=")) |inline_value| return inline_value;
        if (rest.len > 0) return null;
    } else if (!eql(arg, short)) return null;

    i.* += 1;
    if (i.* >= args.len) return error.MissingValue;
    return args[i.*];
}

fn parsePort(text: []const u8) !u16 {
    return std.fmt.parseInt(u16, text, 10) catch error.InvalidPort;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test {
    _ = proxy;
}

test "parses options" {
    const options = try parseOptions(&.{ "-p", "6000", "--allow=a:1,b:2" }, "7000");

    try std.testing.expectEqual(6000, options.port);
    try std.testing.expectEqualStrings("a:1,b:2", options.allow);
}

test "reads the port from the environment" {
    try std.testing.expectEqual(7000, (try parseOptions(&.{}, "7000")).port);
}

test "rejects bad options" {
    try std.testing.expectError(error.UnknownOption, parseOptions(&.{"--nope"}, null));
    try std.testing.expectError(error.MissingValue, parseOptions(&.{"--port"}, null));
    try std.testing.expectError(error.InvalidPort, parseOptions(&.{ "--port", "70000" }, null));
}
