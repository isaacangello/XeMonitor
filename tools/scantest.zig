const std = @import("std");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/poll.h");
    @cInclude("time.h");
});

const TIOCM_DTR: c_int = 0x002;
const TIOCM_RTS: c_int = 0x004;

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

fn hexStr(data: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (data) |b| {
        n += std.fmt.bufPrint(out[n..], "{x:0>2} ", .{b}) catch return out[0..n];
    }
    return out[0..n];
}

fn printable(data: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (data) |b| {
        const ch: u8 = if (b >= 32 and b < 127) b else '.';
        if (n >= out.len) break;
        out[n] = ch;
        n += 1;
    }
    return out[0..n];
}

pub fn main() !void {
    const args = std.process.argsAlloc(std.heap.page_allocator) catch return;
    var baud_arg: c_uint = 115200;
    var seconds_arg: u64 = 12;
    if (args.len > 1) baud_arg = std.fmt.parseInt(c_uint, args[1], 10) catch baud_arg;
    if (args.len > 2) seconds_arg = std.fmt.parseInt(u64, args[2], 10) catch seconds_arg;
    const argc = std.heap.page_allocator;
    _ = argc;

    std.debug.print("scantest: dev=/dev/ttyUSB0 baud={d} seconds={d}\n", .{ baud_arg, seconds_arg });

    const dev = "/dev/ttyUSB0";
    const fd = c.open(dev, c.O_RDWR | c.O_NOCTTY);
    if (fd < 0) {
        std.debug.print("open failed fd={d}\n", .{fd});
        return;
    }

    var t: c.struct_termios = undefined;
    _ = c.tcgetattr(fd, &t);
    t.c_cflag &= ~@as(c_uint, c.CSIZE);
    t.c_cflag |= c.CS8 | c.CREAD | c.CLOCAL;
    _ = c.cfsetispeed(&t, baud_arg);
    _ = c.cfsetospeed(&t, baud_arg);
    _ = c.tcsetattr(fd, c.TCSAFLUSH, &t);
    _ = c.tcflush(fd, c.TCIOFLUSH);

    const dtr_rts: c_int = TIOCM_DTR | TIOCM_RTS;
    _ = c.ioctl(fd, c.TIOCMBIS, &dtr_rts);
    sleepNs(300 * std.time.ns_per_ms);
    var status: c_int = 0;
    _ = c.ioctl(fd, c.TIOCMGET, &status);
    std.debug.print("TIOCMGET=0x{x} (DTR+CTS+LE+DSR+CAR+RNG)\n", .{@as(u32, @bitCast(status))});
    std.debug.print("Ready. ESCANEIE agora (lendo {d} bytes acumulados por {d}s)...\n", .{ 4096, seconds_arg });

    var buf: [4096]u8 = undefined;
    const start = std.time.milliTimestamp();
    const deadline = start + @as(i64, @intCast(seconds_arg * 1000));
    var hex_buf: [16384]u8 = undefined;
    var pr_buf: [4096]u8 = undefined;

    while (std.time.milliTimestamp() < deadline) {
        // poll p/ leitura não-bloqueante
        var fds: [1]c.struct_pollfd = undefined;
        fds[0].fd = fd;
        fds[0].events = c.POLLIN;
        fds[0].revents = 0;
        const prc = c.poll(&fds, 1, 500);
        if (prc <= 0) continue;
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) continue;
        const data = buf[0..@as(usize, @intCast(n))];
        const hex = hexStr(data, &hex_buf);
        const pr = printable(data, &pr_buf);
        std.debug.print("[{d}] read {d} bytes: '{s}'\n  hex: {s}\n", .{ @as(i64, @intCast(std.time.milliTimestamp() - start)), data.len, pr, hex });
    }

    _ = c.close(fd);
    std.debug.print("done\n", .{});
}
