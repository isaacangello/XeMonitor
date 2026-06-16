const std = @import("std");
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("termios.h");
});

const TCP_PORT: u16 = 9000;
const BAUD: u32 = 115200;
const SERIAL = "/dev/ttyUSB0";
const CODE_MAX = 256;

const index_html = @embedFile("index.html");

const SharedState = struct {
    mutex: std.Thread.Mutex = .{},
    code: [CODE_MAX]u8 = undefined,
    code_len: usize = 0,

    fn update(self: *SharedState, data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(data.len, CODE_MAX);
        @memcpy(self.code[0..n], data[0..n]);
        self.code_len = n;
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
    const fd = openSerial();
    if (fd < 0) return;
    defer _ = c.close(fd);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) {
            std.debug.print("[bridge] serial read error or end of stream\n", .{});
            break;
        }
        state.update(buf[0..@as(usize, @intCast(n))]);
    }
}

// ---- raw TCP mode (default) ----

fn runTcpMode() !void {
    const fd = openSerial();
    if (fd < 0) return error.SerialOpenFailed;
    defer _ = c.close(fd);

    std.debug.print("[bridge] starting TCP server on 0.0.0.0:{d}...\n", .{TCP_PORT});
    const address = try std.net.Address.parseIp("0.0.0.0", TCP_PORT);
    var server = try std.net.Address.listen(address, .{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("[bridge] waiting for connection...\n", .{});
    const conn = try server.accept();
    defer conn.stream.close();
    std.debug.print("[bridge] connected!\n", .{});

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) {
            std.debug.print("[bridge] end of serial stream\n", .{});
            break;
        }
        _ = c.write(conn.stream.handle, &buf, @as(usize, @intCast(n)));
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
        std.Thread.sleep(50 * std.time.ns_per_ms);
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

fn handleHttpConnection(conn: std.net.Stream, state: *SharedState) void {
    defer conn.close();

    var buf: [8192]u8 = undefined;
    const n = c.read(conn.handle, &buf, buf.len);
    if (n <= 0) return;

    const path = parseHttpPath(buf[0..@as(usize, @intCast(n))]) orelse return;

    if (std.mem.eql(u8, path, "/stream")) {
        handleSse(conn.handle, state);
    } else if (std.mem.eql(u8, path, "/latest")) {
        handleLatest(conn.handle, state);
    } else if (std.mem.eql(u8, path, "/health")) {
        sendHttpOk(conn.handle, "text/plain", "OK");
    } else {
        handleIndex(conn.handle);
    }
}

fn runHttpMode(addr: std.net.Address) !void {
    std.debug.print("[bridge] starting HTTP server on {f}\n", .{addr});

    var state = SharedState{};

    const reader_thread = try std.Thread.spawn(.{}, serialReaderTask, .{&state});
    reader_thread.detach();

    var server = try std.net.Address.listen(addr, .{ .reuse_address = true });
    defer server.deinit();

    while (true) {
        const conn = server.accept() catch |err| {
            std.debug.print("[bridge] accept error: {}\n", .{err});
            std.Thread.sleep(std.time.ns_per_s);
            continue;
        };

        const thread = try std.Thread.spawn(.{}, handleHttpConnection, .{ conn.stream, &state });
        thread.detach();
    }
}

// ---- CLI ----

pub fn main() !u8 {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

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
        var addr_buf: [128]u8 = undefined;
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

        const host_z = try std.fmt.bufPrint(&addr_buf, "{s}", .{host});
        const address = std.net.Address.parseIp(host_z, port) catch {
            std.debug.print("[bridge] could not resolve address '{s}'\n", .{host});
            return 1;
        };

        try runHttpMode(address);
    } else {
        try runTcpMode();
    }

    return 0;
}
