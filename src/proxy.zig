const std = @import("std");
const Io = std.Io;
const net = Io.net;
const posix = std.posix;
const WebSocket = std.http.Server.WebSocket;

const log = std.log.scoped(.wsproxy);

const relay_buffer_len = 16 * 1024;
/// Also caps the size of one WebSocket message from the client.
const client_buffer_len = 64 * 1024;
const max_frame_header_len = 14;

/// Targets the proxy may connect to, compared as exact `host:port` strings.
///
/// An empty list permits every target, as upstream wsProxy does.
pub const AllowList = struct {
    list: []const u8,

    pub fn isEmpty(self: AllowList) bool {
        var targets = self.iterator();
        return targets.next() == null;
    }

    pub fn permits(self: AllowList, target: []const u8) bool {
        if (self.isEmpty()) return true;
        var targets = self.iterator();
        while (targets.next()) |allowed| {
            if (std.mem.eql(u8, allowed, target)) return true;
        }
        return false;
    }

    fn iterator(self: AllowList) Iterator {
        return .{ .inner = std.mem.splitScalar(u8, self.list, ',') };
    }

    const Iterator = struct {
        inner: std.mem.SplitIterator(u8, .scalar),

        fn next(it: *Iterator) ?[]const u8 {
            while (it.inner.next()) |raw| {
                const target = std.mem.trim(u8, raw, " \t");
                if (target.len > 0) return target;
            }
            return null;
        }
    };
};

pub fn serve(io: Io, server: *net.Server, allow: AllowList) Io.Cancelable!void {
    var connections: Io.Group = .init;
    defer connections.cancel(io);

    while (true) {
        const client = server.accept(io) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => {
                log.warn("accept failed: {t}", .{err});
                continue;
            },
        };
        connections.concurrent(io, handle, .{ io, client, allow }) catch {
            log.warn("no thread left for a new connection", .{});
            client.close(io);
        };
    }
}

fn handle(io: Io, client: net.Stream, allow: AllowList) Io.Cancelable!void {
    defer client.close(io);
    const peer = peerAddress(client);

    proxy(io, client, peer, allow) catch |err| switch (err) {
        error.Canceled => |e| return e,
        error.EndOfStream => log.info("{f} connection dropped", .{peer}),
        else => log.warn("{f} connection failed: {t}", .{ peer, err }),
    };
}

fn proxy(io: Io, client: net.Stream, peer: net.IpAddress, allow: AllowList) !void {
    setNoDelay(client);

    var client_in: [client_buffer_len]u8 = undefined;
    var client_out: [relay_buffer_len + max_frame_header_len]u8 = undefined;
    var client_reader = client.reader(io, &client_in);
    var client_writer = client.writer(io, &client_out);
    var server: std.http.Server = .init(&client_reader.interface, &client_writer.interface);
    var request = try server.receiveHead();

    const key = switch (request.upgradeRequested()) {
        .websocket => |key| key orelse return badRequest(&request),
        else => return badRequest(&request),
    };

    // Head strings live in the read buffer, which WebSocket reads overwrite.
    var target_buffer: [net.HostName.max_len + ":65535".len]u8 = undefined;
    const path = std.mem.cutScalar(u8, request.head.target, '?') orelse .{ request.head.target, "" };
    const requested = std.mem.trimStart(u8, path[0], "/");
    if (requested.len > target_buffer.len) return badRequest(&request);
    const target = target_buffer[0..requested.len];
    @memcpy(target, requested);

    if (!allow.permits(target)) {
        log.warn("{f} target rejected: {s}", .{ peer, target });
        return request.respond("Unauthorized", .{ .status = .unauthorized, .keep_alive = false });
    }

    var headers: [1]std.http.Header = undefined;
    var websocket = try request.respondWebSocket(.{
        .key = key,
        .extra_headers = if (subprotocol(&request)) |offered| blk: {
            headers[0] = .{ .name = "sec-websocket-protocol", .value = offered };
            break :blk &headers;
        } else &.{},
    });
    try websocket.flush();

    const address = try resolveIp4(io, target);
    const upstream = try address.connect(io, .{ .mode = .stream });
    defer upstream.close(io);
    setNoDelay(upstream);
    log.info("{f} connection accepted: {s} ({f})", .{ peer, target, address });

    try relay(io, &websocket, upstream);
    log.info("{f} connection closed: {s}", .{ peer, target });
}

fn badRequest(request: *std.http.Server.Request) !void {
    return request.respond("Bad Request", .{ .status = .bad_request, .keep_alive = false });
}

fn subprotocol(request: *const std.http.Server.Request) ?[]const u8 {
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "sec-websocket-protocol")) continue;
        var offered = std.mem.splitScalar(u8, header.value, ',');
        const first = std.mem.trim(u8, offered.first(), " \t");
        return if (first.len > 0) first else null;
    }
    return null;
}

fn resolveIp4(io: Io, target: []const u8) !net.IpAddress {
    const host, const port_text = std.mem.cutScalarLast(u8, target, ':') orelse return error.InvalidTarget;
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidTarget;
    if (net.IpAddress.parseIp4(host, port)) |address| return address else |_| {}

    var results: [16]net.HostName.LookupResult = undefined;
    var queue: Io.Queue(net.HostName.LookupResult) = .init(&results);
    const name = net.HostName.init(host) catch return error.InvalidTarget;
    try name.lookup(io, &queue, .{ .port = port, .family = .ip4 });
    while (queue.getOne(io)) |result| switch (result) {
        .address => |address| return address,
        .canonical_name => {},
    } else |err| switch (err) {
        error.Canceled => |e| return e,
        error.Closed => return error.NoIpv4Address,
    }
}

/// Relays bytes verbatim until either side goes away.
fn relay(io: Io, websocket: *WebSocket, upstream: net.Stream) !void {
    var upstream_in: [relay_buffer_len]u8 = undefined;
    var upstream_out: [relay_buffer_len]u8 = undefined;
    var upstream_reader = upstream.reader(io, &upstream_in);
    var upstream_writer = upstream.writer(io, &upstream_out);

    var finished: [2]Direction = undefined;
    var directions: Io.Select(Direction) = .init(io, &finished);
    defer directions.cancelDiscard();

    try directions.concurrent(.to_upstream, toUpstream, .{ io, websocket, upstream, &upstream_writer.interface });
    try directions.concurrent(.to_client, toClient, .{ websocket, &upstream_reader.interface });

    return switch (try directions.await()) {
        inline else => |outcome| outcome,
    };
}

const Direction = union(enum) {
    to_upstream: @typeInfo(@TypeOf(toUpstream)).@"fn".return_type.?,
    to_client: @typeInfo(@TypeOf(toClient)).@"fn".return_type.?,
};

fn toUpstream(io: Io, websocket: *WebSocket, upstream: net.Stream, writer: *Io.Writer) !void {
    while (true) {
        const message = websocket.readSmallMessage() catch |err| switch (err) {
            error.ConnectionClose => break,
            else => |e| return e,
        };
        switch (message.opcode) {
            .binary, .text => {
                try writer.writeAll(message.data);
                try writer.flush();
            },
            else => {},
        }
    }
    try upstream.shutdown(io, .send);
}

fn toClient(websocket: *WebSocket, reader: *Io.Reader) !void {
    while (true) {
        reader.fillMore() catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        const data = reader.buffered();
        if (data.len == 0) continue;
        try websocket.writeMessage(data, .binary);
        reader.tossBuffered();
    }
    try websocket.writeMessage("", .connection_close);
}

fn setNoDelay(stream: net.Stream) void {
    const enable: c_int = 1;
    posix.setsockopt(stream.socket.handle, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&enable)) catch {};
}

fn peerAddress(stream: net.Stream) net.IpAddress {
    var storage: Io.Threaded.PosixAddress = undefined;
    var len: posix.socklen_t = @sizeOf(Io.Threaded.PosixAddress);
    posix.getpeername(stream.socket.handle, &storage.any, &len) catch return .{ .ip4 = .unspecified(0) };
    return Io.Threaded.addressFromPosix(&storage);
}

const testing = std.testing;

test "allow list matches exact targets" {
    const allow: AllowList = .{ .list = " 10.0.0.1:6900, ,10.0.0.1:5121" };

    try testing.expect(!allow.isEmpty());
    try testing.expect(allow.permits("10.0.0.1:6900"));
    try testing.expect(allow.permits("10.0.0.1:5121"));
    try testing.expect(!allow.permits("10.0.0.1:6121"));
}

test "empty allow list permits everything" {
    const allow: AllowList = .{ .list = " , " };

    try testing.expect(allow.isEmpty());
    try testing.expect(allow.permits("anything:1"));
}

const TestServer = struct {
    server: net.Server,
    task: Io.Future(Io.Cancelable!void),

    fn port(self: *const TestServer) u16 {
        return self.server.socket.address.getPort();
    }

    fn stop(self: *TestServer) void {
        self.task.cancel(testing.io) catch {};
        self.server.deinit(testing.io);
    }
};

fn listenLocal() !net.Server {
    const address: net.IpAddress = .{ .ip4 = .loopback(0) };
    return address.listen(testing.io, .{});
}

fn startProxy(server: *TestServer, allow: []const u8) !void {
    server.server = try listenLocal();
    server.task = try testing.io.concurrent(serve, .{ testing.io, &server.server, AllowList{ .list = allow } });
}

fn echo(io: Io, server: *net.Server) Io.Cancelable!void {
    const stream = server.accept(io) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return,
    };
    defer stream.close(io);
    var in: [1024]u8 = undefined;
    var reader = stream.reader(io, &in);
    var writer = stream.writer(io, &.{});
    while (true) {
        reader.interface.fillMore() catch return;
        writer.interface.writeAll(reader.interface.buffered()) catch return;
        reader.interface.tossBuffered();
    }
}

fn startEcho(server: *TestServer) !void {
    server.server = try listenLocal();
    server.task = try testing.io.concurrent(echo, .{ testing.io, &server.server });
}

const TestClient = struct {
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    in: [4096]u8,
    out: [4096]u8,

    fn connect(client: *TestClient, proxy_port: u16, target: []const u8, extra_headers: []const u8) !void {
        const address: net.IpAddress = .{ .ip4 = .loopback(proxy_port) };
        client.stream = try address.connect(testing.io, .{ .mode = .stream });
        client.reader = client.stream.reader(testing.io, &client.in);
        client.writer = client.stream.writer(testing.io, &client.out);
        try client.writer.interface.print(
            "GET /{s} HTTP/1.1\r\n" ++
                "host: localhost\r\n" ++
                "upgrade: websocket\r\n" ++
                "connection: upgrade\r\n" ++
                "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
                "sec-websocket-version: 13\r\n" ++
                "{s}\r\n",
            .{ target, extra_headers },
        );
        try client.writer.interface.flush();
    }

    /// Returns the response head, valid until the next read.
    fn readHead(client: *TestClient) ![]const u8 {
        const r = &client.reader.interface;
        while (true) {
            if (std.mem.find(u8, r.buffered(), "\r\n\r\n")) |end| return r.take(end + 4);
            try r.fillMore();
        }
    }

    fn send(client: *TestClient, opcode: WebSocket.Opcode, payload: []const u8) !void {
        const w = &client.writer.interface;
        std.debug.assert(payload.len <= 125);
        try w.writeByte(0x80 | @as(u8, @intFromEnum(opcode)));
        try w.writeByte(0x80 | @as(u8, @intCast(payload.len)));
        const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 };
        try w.writeAll(&mask);
        for (payload, 0..) |byte, i| try w.writeByte(byte ^ mask[i % 4]);
        try w.flush();
    }

    const Frame = struct { opcode: WebSocket.Opcode, payload: []const u8 };

    fn receive(client: *TestClient) !Frame {
        const r = &client.reader.interface;
        const header = try r.takeArray(2);
        const len = header[1] & 0x7f;
        std.debug.assert(len <= 125);
        return .{ .opcode = @enumFromInt(@as(u4, @truncate(header[0]))), .payload = try r.take(len) };
    }

    fn close(client: *TestClient) void {
        client.stream.close(testing.io);
    }
};

test "rejects target outside allow list" {
    var proxy_server: TestServer = undefined;
    try startProxy(&proxy_server, "127.0.0.1:1");
    defer proxy_server.stop();

    var client: TestClient = undefined;
    try client.connect(proxy_server.port(), "127.0.0.1:9", "");
    defer client.close();

    try testing.expectStringStartsWith(try client.readHead(), "HTTP/1.1 401 ");
}

test "relays binary in both directions" {
    var echo_server: TestServer = undefined;
    try startEcho(&echo_server);
    defer echo_server.stop();
    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{echo_server.port()});

    var proxy_server: TestServer = undefined;
    try startProxy(&proxy_server, target);
    defer proxy_server.stop();

    var client: TestClient = undefined;
    try client.connect(proxy_server.port(), target, "");
    defer client.close();
    try testing.expectStringStartsWith(try client.readHead(), "HTTP/1.1 101 ");

    const payload = [_]u8{ 0x00, 0x64, 0xff, 0x0a, 0x1b };
    try client.send(.binary, &payload);
    const frame = try client.receive();

    try testing.expectEqual(WebSocket.Opcode.binary, frame.opcode);
    try testing.expectEqualSlices(u8, &payload, frame.payload);
}

test "permits any target without an allow list" {
    var echo_server: TestServer = undefined;
    try startEcho(&echo_server);
    defer echo_server.stop();
    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{echo_server.port()});

    var proxy_server: TestServer = undefined;
    try startProxy(&proxy_server, "");
    defer proxy_server.stop();

    var client: TestClient = undefined;
    try client.connect(proxy_server.port(), target, "");
    defer client.close();
    _ = try client.readHead();

    try client.send(.binary, &.{0x42});
    try testing.expectEqualSlices(u8, &.{0x42}, (try client.receive()).payload);
}

fn acceptAndClose(io: Io, server: *net.Server) Io.Cancelable!void {
    const stream = server.accept(io) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return,
    };
    stream.close(io);
}

test "closing the tcp side closes the websocket" {
    var target_server: TestServer = .{ .server = try listenLocal(), .task = undefined };
    target_server.task = try testing.io.concurrent(acceptAndClose, .{ testing.io, &target_server.server });
    defer target_server.stop();
    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{target_server.port()});

    var proxy_server: TestServer = undefined;
    try startProxy(&proxy_server, target);
    defer proxy_server.stop();

    var client: TestClient = undefined;
    try client.connect(proxy_server.port(), target, "");
    defer client.close();
    _ = try client.readHead();

    try testing.expectEqual(WebSocket.Opcode.connection_close, (try client.receive()).opcode);
    try testing.expectError(error.EndOfStream, client.reader.interface.takeByte());
}

fn readAll(io: Io, server: *net.Server, received: *[64]u8) Io.Cancelable![]u8 {
    const stream = server.accept(io) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return &.{},
    };
    defer stream.close(io);
    var in: [64]u8 = undefined;
    var reader = stream.reader(io, &in);
    const len = reader.interface.readSliceShort(received) catch return &.{};
    return received[0..len];
}

test "closing the websocket closes the tcp side" {
    var server = try listenLocal();
    defer server.deinit(testing.io);
    var received: [64]u8 = undefined;
    var target_task = try testing.io.concurrent(readAll, .{ testing.io, &server, &received });
    defer _ = target_task.cancel(testing.io) catch {};
    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{server.socket.address.getPort()});

    var proxy_server: TestServer = undefined;
    try startProxy(&proxy_server, target);
    defer proxy_server.stop();

    var client: TestClient = undefined;
    try client.connect(proxy_server.port(), target, "");
    defer client.close();
    _ = try client.readHead();

    try client.send(.binary, "hello");
    try client.send(.connection_close, "");

    try testing.expectEqualStrings("hello", try target_task.await(testing.io));
}

test "echoes the requested subprotocol" {
    var echo_server: TestServer = undefined;
    try startEcho(&echo_server);
    defer echo_server.stop();
    var target_buffer: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buffer, "127.0.0.1:{d}", .{echo_server.port()});

    var proxy_server: TestServer = undefined;
    try startProxy(&proxy_server, target);
    defer proxy_server.stop();

    var client: TestClient = undefined;
    try client.connect(proxy_server.port(), target, "sec-websocket-protocol: binary, base64\r\n");
    defer client.close();

    try testing.expect(std.mem.find(u8, try client.readHead(), "\r\nsec-websocket-protocol: binary\r\n") != null);
}
