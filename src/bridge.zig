const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("termios.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("pthread.h");
    @cInclude("time.h");
});

const Timespec = extern struct {
    tv_sec: isize,
    tv_nsec: isize,
};

fn sleepNs(ns: u64) void {
    var req = Timespec{
        .tv_sec = @intCast(ns / std.time.ns_per_s),
        .tv_nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = c.nanosleep(@ptrCast(&req), null);
}

const Mutex = struct {
    inner: c.pthread_mutex_t = std.mem.zeroes(c.pthread_mutex_t),

    fn lock(self: *Mutex) void {
        _ = c.pthread_mutex_lock(&self.inner);
    }

    fn unlock(self: *Mutex) void {
        _ = c.pthread_mutex_unlock(&self.inner);
    }
};

const TCP_PORT: u16 = 9000;
const BAUD: u32 = 115200;
const SERIAL = "/dev/ttyUSB0";
const CODE_MAX = 256;

const index_html = @embedFile("index.html");

const SharedState = struct {
    mutex: Mutex = .{},
    code: [CODE_MAX]u8 = undefined,
    code_len: usize = 0,
    seq: u64 = 0,

    fn update(self: *SharedState, data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(data.len, CODE_MAX);
        @memcpy(self.code[0..n], data[0..n]);
        self.code_len = n;
        self.seq +%= 1;
    }

    fn currentSeq(self: *SharedState) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.seq;
    }

    fn readSince(self: *SharedState, buf: []u8, last_seq: *u64) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.code_len == 0) return null;
        if (self.seq == last_seq.*) return null;
        const n = @min(self.code_len, buf.len);
        @memcpy(buf[0..n], self.code[0..n]);
        last_seq.* = self.seq;
        return buf[0..n];
    }

    fn get(self: *SharedState, buf: []u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.code_len == 0) return null;
        const n = @min(self.code_len, buf.len);
        @memcpy(buf[0..n], self.code[0..n]);
        return buf[0..n];
    }

    fn readNew(self: *SharedState, prev: []u8, prev_len: *usize) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.code_len == 0) return null;
        if (prev_len.* == self.code_len and std.mem.eql(u8, prev[0..prev_len.*], self.code[0..self.code_len]))
            return null;
        const n = @min(self.code_len, prev.len);
        @memcpy(prev[0..n], self.code[0..n]);
        prev_len.* = self.code_len;
        return prev[0..prev_len.*];
    }
};

fn usage() void {
    std.debug.print(
        \\XeMonitor Bridge
        \\
        \\Usage:
        \\  bridge                       raw TCP server (default port 9000)
        \\  bridge -s <url>              HTTP server (e.g. http://0.0.0.0:8080)
        \\  bridge -h                    show this help
        \\
        \\Examples:
        \\  bridge
        \\  bridge -s http://0.0.0.0:8080
        \\
    , .{});
}

fn configureSerial(fd: c_int) void {
    var t: c.struct_termios = undefined;
    _ = c.tcgetattr(fd, &t);

    {
        const mask = @as(c_uint, c.BRKINT) | @as(c_uint, c.INPCK) | @as(c_uint, c.ISTRIP) | @as(c_uint, c.IXON) | @as(c_uint, c.IXOFF) | @as(c_uint, c.IXANY) | @as(c_uint, c.IGNBRK) | @as(c_uint, c.INLCR) | @as(c_uint, c.IGNCR) | @as(c_uint, c.ICRNL);
        t.c_iflag &= ~mask;
    }
    t.c_oflag &= ~@as(c_uint, c.OPOST);
    {
        const mask = @as(c_uint, c.CSIZE) | @as(c_uint, c.PARENB) | @as(c_uint, c.CSTOPB) | @as(c_uint, c.CRTSCTS);
        t.c_cflag &= ~mask;
    }
    t.c_cflag |= @as(c_uint, c.CS8) | @as(c_uint, c.CREAD) | @as(c_uint, c.CLOCAL);
    {
        const mask = @as(c_uint, c.ICANON) | @as(c_uint, c.ECHO) | @as(c_uint, c.ECHOE) | @as(c_uint, c.ECHOK) | @as(c_uint, c.ECHONL) | @as(c_uint, c.ISIG) | @as(c_uint, c.IEXTEN);
        t.c_lflag &= ~mask;
    }

    t.c_cc[c.VMIN] = 1;
    t.c_cc[c.VTIME] = 0;

    _ = c.cfsetispeed(&t, BAUD);
    _ = c.cfsetospeed(&t, BAUD);

    _ = c.tcsetattr(fd, c.TCSAFLUSH, &t);
    _ = c.tcflush(fd, c.TCIOFLUSH);
}

fn openSerial() c_int {
    std.debug.print("[bridge] opening {s}...\n", .{SERIAL});
    const fd = c.open(SERIAL, c.O_RDWR | c.O_NOCTTY);
    if (fd < 0) {
        std.debug.print("[bridge] failed to open serial\n", .{});
        return -1;
    }
    std.debug.print("[bridge] configuring serial {d} 8N1...\n", .{BAUD});
    configureSerial(fd);
    return fd;
}

fn serialReaderTask(state: *SharedState) void {
    while (true) {
        const fd = openSerial();
        if (fd < 0) {
            std.debug.print("[bridge] serial unavailable, retrying in 2s...\n", .{});
            sleepNs(2 * std.time.ns_per_s);
            continue;
        }

        var buf: [4096]u8 = undefined;
        var failed = false;
        while (true) {
            const n = c.read(fd, &buf, buf.len);
            if (n <= 0) {
                std.debug.print("[bridge] serial read error or end of stream\n", .{});
                failed = true;
                break;
            }
            state.update(buf[0..@as(usize, @intCast(n))]);
        }
        _ = c.close(fd);
        if (failed) sleepNs(500 * std.time.ns_per_ms);
    }
}

// ---- raw TCP mode (default) ----

const SockAddrIn = extern struct {
    sin_family: u16 = c.AF_INET,
    sin_port: u16 = undefined,
    sin_addr: extern struct { s_addr: u32 } = .{ .s_addr = 0 },
    sin_zero: [8]u8 = [_]u8{0} ** 8,
};

fn listenOn(host: []const u8, port: u16) !c_int {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;

    const opt: c_int = 1;
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, &opt, @sizeOf(c_int));

    var addr = SockAddrIn{ .sin_port = std.mem.nativeToBig(u16, port) };
    if (host.len > 0 and !std.mem.eql(u8, host, "0.0.0.0")) {
        var host_buf: [128]u8 = undefined;
        const host_z = std.fmt.bufPrintZ(&host_buf, "{s}", .{host}) catch unreachable;
        if (c.inet_pton(c.AF_INET, host_z.ptr, &addr.sin_addr.s_addr) != 1) {
            _ = c.close(fd);
            return error.InvalidHost;
        }
    }

    if (c.bind(fd, @ptrCast(&addr), @sizeOf(SockAddrIn)) < 0) {
        _ = c.close(fd);
        return error.BindFailed;
    }
    if (c.listen(fd, 128) < 0) {
        _ = c.close(fd);
        return error.ListenFailed;
    }
    return fd;
}

fn handleTcpConnection(fd: c_int, state: *SharedState) void {
    defer _ = c.close(fd);

    var last_seq: u64 = state.currentSeq();
    var buf: [CODE_MAX]u8 = undefined;

    while (true) {
        if (state.readSince(&buf, &last_seq)) |data| {
            if (c.write(fd, data.ptr, data.len) < 0) break;
        }
        sleepNs(20 * std.time.ns_per_ms);
    }
}

fn runTcpMode() !void {
    std.debug.print("[bridge] starting TCP server on 0.0.0.0:{d}...\n", .{TCP_PORT});
    const fd = try listenOn("0.0.0.0", TCP_PORT);
    defer _ = c.close(fd);

    var state = SharedState{};
    const reader_thread = try std.Thread.spawn(.{}, serialReaderTask, .{&state});
    reader_thread.detach();

    while (true) {
        const client = c.accept(fd, null, null);
        if (client < 0) {
            std.debug.print("[bridge] accept error\n", .{});
            sleepNs(std.time.ns_per_s);
            continue;
        }
        std.debug.print("[bridge] client connected\n", .{});

        const thread = std.Thread.spawn(.{}, handleTcpConnection, .{ client, &state }) catch |err| {
            std.debug.print("[bridge] failed to spawn handler: {}\n", .{err});
            _ = c.close(client);
            continue;
        };
        thread.detach();
    }
}

// ---- HTTP mode (-s flag) ----

fn sendHttpOk(fd: c_int, content_type: []const u8, body: []const u8) void {
    var buf: [4096]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf,
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: {s}\r\n\r\n{s}",
        .{ body.len, content_type, body },
    ) catch return;
    _ = c.write(fd, resp.ptr, resp.len);
}

fn sendHttpNoContent(fd: c_int) void {
    _ = c.write(fd, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n", 43);
}

fn handleSse(fd: c_int, state: *SharedState) void {
    const header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n";
    _ = c.write(fd, header.ptr, header.len);

    var prev: [CODE_MAX]u8 = undefined;
    var prev_len: usize = 0;

    while (true) {
        if (state.readNew(&prev, &prev_len)) |data| {
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "data: {s}\n\n", .{data}) catch continue;
            if (c.write(fd, msg.ptr, msg.len) < 0) break;
        }
        sleepNs(50 * std.time.ns_per_ms);
    }
}

fn handleLatest(fd: c_int, state: *SharedState) void {
    var buf: [CODE_MAX]u8 = undefined;
    if (state.get(&buf)) |data| {
        sendHttpOk(fd, "text/plain", data);
    } else {
        sendHttpNoContent(fd);
    }
}

fn handleIndex(fd: c_int) void {
    sendHttpOk(fd, "text/html; charset=utf-8", index_html);
}

fn parseHttpPath(request: []const u8) ?[]const u8 {
    const line_end = std.mem.indexOfScalar(u8, request, '\r') orelse return null;
    const first_line = request[0..line_end];
    const method_end = std.mem.indexOfScalar(u8, first_line, ' ') orelse return null;
    const path_end = std.mem.indexOfScalarPos(u8, first_line, method_end + 1, ' ') orelse return null;
    return first_line[method_end + 1 .. path_end];
}

fn handleHttpConnection(fd: c_int, state: *SharedState) void {
    defer _ = c.close(fd);

    var buf: [8192]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return;

    const path = parseHttpPath(buf[0..@as(usize, @intCast(n))]) orelse return;

    if (std.mem.eql(u8, path, "/stream")) {
        handleSse(fd, state);
    } else if (std.mem.eql(u8, path, "/latest")) {
        handleLatest(fd, state);
    } else if (std.mem.eql(u8, path, "/health")) {
        sendHttpOk(fd, "text/plain", "OK");
    } else {
        handleIndex(fd);
    }
}

fn runHttpMode(host: []const u8, port: u16) !void {
    std.debug.print("[bridge] starting HTTP server on {s}:{d}...\n", .{ host, port });

    var state = SharedState{};

    const reader_thread = try std.Thread.spawn(.{}, serialReaderTask, .{&state});
    reader_thread.detach();

    const fd = try listenOn(host, port);
    defer _ = c.close(fd);

    while (true) {
        const client = c.accept(fd, null, null);
        if (client < 0) {
            std.debug.print("[bridge] accept error\n", .{});
            sleepNs(std.time.ns_per_s);
            continue;
        }

        const thread = std.Thread.spawn(.{}, handleHttpConnection, .{ client, &state }) catch |err| {
            std.debug.print("[bridge] failed to spawn handler: {}\n", .{err});
            _ = c.close(client);
            continue;
        };
        thread.detach();
    }
}

// ---- CLI ----

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    defer init.arena.allocator().free(args);

    var serve_mode = false;
    var serve_addr: []const u8 = "http://0.0.0.0:8080";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            usage();
            return 0;
        }
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--serve")) {
            serve_mode = true;
            if (i + 1 < args.len) {
                i += 1;
                serve_addr = args[i];
            }
            continue;
        }
        usage();
        return 1;
    }

    if (serve_mode) {
        const addr_str = if (std.mem.startsWith(u8, serve_addr, "http://"))
            serve_addr[7..]
        else if (std.mem.startsWith(u8, serve_addr, "https://"))
            serve_addr[8..]
        else
            serve_addr;

        const colon = std.mem.indexOfScalar(u8, addr_str, ':') orelse {
            std.debug.print("[bridge] invalid address '{s}'; expected host:port\n", .{serve_addr});
            return 1;
        };
        const host = addr_str[0..colon];
        const port_str = addr_str[colon + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch {
            std.debug.print("[bridge] invalid port '{s}'\n", .{port_str});
            return 1;
        };

        runHttpMode(host, port) catch {
            std.debug.print("[bridge] could not start HTTP server on '{s}'\n", .{host});
            return 1;
        };
    } else {
        try runTcpMode();
    }

    return 0;
}

// ---- Tests ----

test "SharedState: update and get" {
    var state = SharedState{};
    const data = "1234567890";
    state.update(data);

    var buf: [256]u8 = undefined;
    const result = state.get(&buf);
    try testing.expect(result != null);
    try testing.expectEqualStrings(data, result.?);
}

test "SharedState: readNew detects changes" {
    var state = SharedState{};
    var prev: [256]u8 = undefined;
    var prev_len: usize = 0;

    state.update("first");
    const r1 = state.readNew(&prev, &prev_len);
    try testing.expect(r1 != null);
    try testing.expectEqualStrings("first", r1.?);

    const r2 = state.readNew(&prev, &prev_len);
    try testing.expect(r2 == null);

    state.update("second");
    const r3 = state.readNew(&prev, &prev_len);
    try testing.expect(r3 != null);
    try testing.expectEqualStrings("second", r3.?);
}

test "SharedState: readNew after same data returns null" {
    var state = SharedState{};
    state.update("abc");
    var prev: [256]u8 = undefined;
    var prev_len: usize = 0;
    _ = state.readNew(&prev, &prev_len);
    state.update("abc");
    const r = state.readNew(&prev, &prev_len);
    try testing.expect(r == null);
}

test "SharedState: empty state get returns null" {
    var state = SharedState{};
    var buf: [256]u8 = undefined;
    const r = state.get(&buf);
    try testing.expect(r == null);
}

test "SharedState: update overwrites old data" {
    var state = SharedState{};
    state.update("old");
    state.update("new");
    var buf: [256]u8 = undefined;
    const r = state.get(&buf);
    try testing.expectEqualStrings("new", r.?);
}

test "SharedState: readSince starts from current seq" {
    var state = SharedState{};
    state.update("before-connect");
    var last_seq: u64 = state.currentSeq();

    var buf: [256]u8 = undefined;
    try testing.expect(state.readSince(&buf, &last_seq) == null);

    state.update("after-connect");
    const r = state.readSince(&buf, &last_seq);
    try testing.expect(r != null);
    try testing.expectEqualStrings("after-connect", r.?);
}

test "SharedState: readSince delivers identical repeated data" {
    var state = SharedState{};
    var last_seq: u64 = state.currentSeq();

    var buf: [256]u8 = undefined;
    state.update("1111");
    try testing.expectEqualStrings("1111", state.readSince(&buf, &last_seq).?);

    state.update("1111");
    const r = state.readSince(&buf, &last_seq);
    try testing.expect(r != null);
    try testing.expectEqualStrings("1111", r.?);
}

test "SharedState: readSince with empty state returns null" {
    var state = SharedState{};
    var last_seq: u64 = state.currentSeq();
    var buf: [256]u8 = undefined;
    try testing.expect(state.readSince(&buf, &last_seq) == null);
}

test "parseHttpPath: simple GET" {
    const req = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const path = parseHttpPath(req);
    try testing.expectEqualStrings("/", path.?);
}

test "parseHttpPath: with path" {
    const req = "GET /stream HTTP/1.1\r\n\r\n";
    const path = parseHttpPath(req);
    try testing.expectEqualStrings("/stream", path.?);
}

test "parseHttpPath: with query string" {
    const req = "GET /latest?ts=123 HTTP/1.1\r\n\r\n";
    const path = parseHttpPath(req);
    try testing.expectEqualStrings("/latest?ts=123", path.?);
}

test "parseHttpPath: invalid request" {
    try testing.expect(parseHttpPath("not-http") == null);
    try testing.expect(parseHttpPath("") == null);
}

test "parseHttpPath: POST request" {
    const req = "POST /data HTTP/1.1\r\nContent-Length: 0\r\n\r\n";
    const path = parseHttpPath(req);
    try testing.expectEqualStrings("/data", path.?);
}
