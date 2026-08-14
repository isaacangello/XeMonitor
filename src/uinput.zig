// Injetor de teclado via /dev/uinput (Linux) — sem dependência de ydotool/xdotool.
// Cria um dispositivo virtual de teclado e emite eventos EV_KEY/EV_SYN.

const std = @import("std");
const linux = std.os.linux;

// ---- ioctls (calculados como _IOC do kernel; UINPUT_IOCTL_BASE = 'U' = 85) ----
// UI_DEV_CREATE/DESTROY sao _IO (direcao NONE); os demais sao _IOW (WRITE).
fn ioc(dir: u32, nr: u32, size: u32) u32 {
    const type_u: u32 = 'U';
    return ((dir & 0x3) << 30) | (type_u << 8) | nr | (size << 16);
}
const UI_DEV_CREATE = ioc(0, 1, 0);
const UI_DEV_DESTROY = ioc(0, 2, 0);
const UI_SET_EVBIT = ioc(1, 100, @sizeOf(c_int));
const UI_SET_KEYBIT = ioc(1, 101, @sizeOf(c_int));
const UI_DEV_SETUP = ioc(1, 3, @sizeOf(UinputSetup));

// ---- linux/input.h ----
const EV_SYN: u16 = 0x00;
const EV_KEY: u16 = 0x01;
const SYN_REPORT: u16 = 0;

const KEY_ESC: u16 = 1;
const KEY_BACKSPACE: u16 = 14;
const KEY_TAB: u16 = 15;
const KEY_ENTER: u16 = 28;
const KEY_LEFTSHIFT: u16 = 42;
const KEY_SPACE: u16 = 57;

const InputEvent = extern struct {
    tv_sec: i64,
    tv_usec: i64,
    type: u16,
    code: u16,
    value: i32,
};

const InputId = extern struct {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
};

const UinputSetup = extern struct {
    id: InputId,
    name: [80]u8,
    ff_effects_max: u32,
};

const KeyPress = struct { key: u16, shift: bool };

const letter_keys = [26]u16{
    30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49,
    24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44,
};

const digit_keys = [10]u16{ 11, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

fn keyForChar(ch: u8) ?KeyPress {
    if (ch >= 'a' and ch <= 'z') return .{ .key = letter_keys[ch - 'a'], .shift = false };
    if (ch >= 'A' and ch <= 'Z') return .{ .key = letter_keys[ch - 'A'], .shift = true };
    if (ch >= '0' and ch <= '9') return .{ .key = digit_keys[ch - '0'], .shift = false };
    return switch (ch) {
        ' ' => .{ .key = KEY_SPACE, .shift = false },
        '`' => .{ .key = 41, .shift = false },
        '~' => .{ .key = 41, .shift = true },
        '-' => .{ .key = 12, .shift = false },
        '_' => .{ .key = 12, .shift = true },
        '=' => .{ .key = 13, .shift = false },
        '+' => .{ .key = 13, .shift = true },
        '[' => .{ .key = 26, .shift = false },
        '{' => .{ .key = 26, .shift = true },
        ']' => .{ .key = 27, .shift = false },
        '}' => .{ .key = 27, .shift = true },
        '\\' => .{ .key = 43, .shift = false },
        '|' => .{ .key = 43, .shift = true },
        ';' => .{ .key = 39, .shift = false },
        ':' => .{ .key = 39, .shift = true },
        '\'' => .{ .key = 40, .shift = false },
        '"' => .{ .key = 40, .shift = true },
        ',' => .{ .key = 51, .shift = false },
        '<' => .{ .key = 51, .shift = true },
        '.' => .{ .key = 52, .shift = false },
        '>' => .{ .key = 52, .shift = true },
        '/' => .{ .key = 53, .shift = false },
        '?' => .{ .key = 53, .shift = true },
        '!' => .{ .key = 2, .shift = true },
        '@' => .{ .key = 3, .shift = true },
        '#' => .{ .key = 4, .shift = true },
        '$' => .{ .key = 5, .shift = true },
        '%' => .{ .key = 6, .shift = true },
        '^' => .{ .key = 7, .shift = true },
        '&' => .{ .key = 8, .shift = true },
        '*' => .{ .key = 9, .shift = true },
        '(' => .{ .key = 10, .shift = true },
        ')' => .{ .key = 11, .shift = true },
        else => null,
    };
}

var g_fd: ?std.posix.fd_t = null;var g_events: [8]InputEvent = undefined;
var g_ev_n: usize = 0;

fn addEvent(ev_type: u16, code: u16, value: i32) void {
    g_events[g_ev_n] = .{
        .tv_sec = 0,
        .tv_usec = 0,
        .type = ev_type,
        .code = code,
        .value = value,
    };
    g_ev_n += 1;
}

fn flushEvents() bool {
    const fd = g_fd orelse return false;
    if (g_ev_n == 0) return true;
    const bytes = std.mem.sliceAsBytes(g_events[0..g_ev_n]);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        if (std.posix.errno(n) != .SUCCESS) return false;
        if (n == 0) return false;
        off += n;
    }
    g_ev_n = 0;
    return true;
}

fn emitKey(key: u16) bool {
    addEvent(EV_KEY, key, 1);
    addEvent(EV_SYN, SYN_REPORT, 0);
    addEvent(EV_KEY, key, 0);
    addEvent(EV_SYN, SYN_REPORT, 0);
    return flushEvents();
}

fn emitShifted(key: u16) bool {
    addEvent(EV_KEY, KEY_LEFTSHIFT, 1);
    addEvent(EV_SYN, SYN_REPORT, 0);
    addEvent(EV_KEY, key, 1);
    addEvent(EV_SYN, SYN_REPORT, 0);
    addEvent(EV_KEY, key, 0);
    addEvent(EV_SYN, SYN_REPORT, 0);
    addEvent(EV_KEY, KEY_LEFTSHIFT, 0);
    addEvent(EV_SYN, SYN_REPORT, 0);
    return flushEvents();
}

/// Abre /dev/uinput e registra o dispositivo de teclado.
pub fn init() !void {
    if (g_fd != null) return;

    const rc = linux.open("/dev/uinput", .{ .ACCMODE = .WRONLY, .NONBLOCK = true }, 0);
    if (std.posix.errno(rc) != .SUCCESS) return error.UinputOpen;
    const fd: std.posix.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);

    if (!ioctlOk(fd, UI_SET_EVBIT, EV_KEY) or !ioctlOk(fd, UI_SET_EVBIT, EV_SYN)) {
        return error.UinputIoctl;
    }

    for (letter_keys) |k| {
        if (!ioctlOk(fd, UI_SET_KEYBIT, k)) return error.UinputIoctl;
    }
    for (digit_keys) |k| {
        if (!ioctlOk(fd, UI_SET_KEYBIT, k)) return error.UinputIoctl;
    }
    for ([_]u16{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 26, 27, 39, 40, 41, 43, 51, 52, 53, KEY_SPACE, KEY_ENTER, KEY_TAB, KEY_BACKSPACE, KEY_ESC, KEY_LEFTSHIFT }) |k| {
        if (!ioctlOk(fd, UI_SET_KEYBIT, k)) return error.UinputIoctl;
    }

    var setup = std.mem.zeroes(UinputSetup);
    setup.id.bustype = 0x11; // BUS_USB
    setup.id.vendor = 0xfeed;
    setup.id.product = 0x0001;
    setup.id.version = 1;
    @memcpy(setup.name[0..9], "xemonitor");
    if (!ioctlOkPtr(fd, UI_DEV_SETUP, @intFromPtr(&setup))) {
        return error.UinputIoctl;
    }
    if (!ioctlOk(fd, UI_DEV_CREATE, 0)) {
        return error.UinputIoctl;
    }

    g_fd = fd;
}

fn ioctlOk(fd: std.posix.fd_t, request: u32, arg: u32) bool {
    const rc = linux.ioctl(fd, request, arg);
    return std.posix.errno(rc) == .SUCCESS;
}

fn ioctlOkPtr(fd: std.posix.fd_t, request: u32, arg: usize) bool {
    const rc = linux.ioctl(fd, request, arg);
    return std.posix.errno(rc) == .SUCCESS;
}

pub fn deinit() void {
    if (g_fd) |fd| {
        _ = linux.ioctl(fd, UI_DEV_DESTROY, 0);
        _ = linux.close(fd);
        g_fd = null;
    }
}

/// Digita texto. Caracteres fora do layout US básico são ignorados.
pub fn typeText(text: []const u8) !void {
    try init();
    for (text) |ch| {
        if (ch == '\n' or ch == '\r') {
            if (!emitKey(KEY_ENTER)) return error.UinputWrite;
            continue;
        }
        if (ch == '\t') {
            if (!emitKey(KEY_TAB)) return error.UinputWrite;
            continue;
        }
        if (ch == 0x7f or ch == 0x08) {
            if (!emitKey(KEY_BACKSPACE)) return error.UinputWrite;
            continue;
        }
        if (ch == 0x1b) {
            if (!emitKey(KEY_ESC)) return error.UinputWrite;
            continue;
        }
        const kp = keyForChar(ch) orelse continue;
        const ok = if (kp.shift) emitShifted(kp.key) else emitKey(kp.key);
        if (!ok) return error.UinputWrite;
    }
}

pub fn pressEnter() !void {
    try init();
    if (!emitKey(KEY_ENTER)) return error.UinputWrite;
}
