const std = @import("std");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("time.h");
});

const TIOCM_DTR: c_int = 0x002;
const TIOCM_RTS: c_int = 0x004;
const TIOCM_CTS: c_int = 0x020;
const TIOCM_LE: c_int = 0x001;
const TIOCM_DSR: c_int = 0x100;
const TIOCM_CAR: c_int = 0x040;
const TIOCM_RNG: c_int = 0x080;

pub fn main() void {
    const dev = "/dev/ttyUSB0";
    const fd = c.open(dev, c.O_RDWR | c.O_NOCTTY);
    if (fd < 0) {
        std.debug.print("open failed fd={d}\n", .{fd});
        return;
    }
    std.debug.print("opened {s} fd={d}\n", .{ dev, fd });

    var status: c_int = 0;
    _ = c.ioctl(fd, c.TIOCMGET, &status);
    std.debug.print("initial TIOCMGET=0x{x}\n", .{@as(u32, @bitCast(status))});

    const mask: c_int = TIOCM_DTR | TIOCM_RTS;
    const rc = c.ioctl(fd, c.TIOCMBIS, &mask);
    std.debug.print("TIOCMBIS DTR|RTS rc={d} (0=ok)\n", .{rc});

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        sleepNs(500 * std.time.ns_per_ms);
        status = 0;
        _ = c.ioctl(fd, c.TIOCMGET, &status);
        std.debug.print("  t+{d}00ms TIOCMGET=0x{x} (DTR={d} RTS={d})\n", .{
            (i + 1) * 5,
            @as(u32, @bitCast(status)),
            @intFromBool((status & TIOCM_DTR) != 0),
            @intFromBool((status & TIOCM_RTS) != 0),
        });
    }

    _ = c.close(fd);
}

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
