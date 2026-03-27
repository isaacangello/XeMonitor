const std = @import("std");
const xemonitor = @import("xemonitor");
const zig_serial = @import("serial");
const builtin = @import("builtin");

fn commandSucceeded(argv: []const []const u8) bool {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const term = child.spawnAndWait() catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

const TrayIcon = struct {
    child: ?std.process.Child = null,

    fn start(self: *TrayIcon) !void {
        switch (builtin.os.tag) {
            .linux => {
                if (!commandSucceeded(&.{ "which", "yad" })) {
                    std.debug.print("[warn] tray icon disabled: install 'yad' to enable tray support on Linux.\n", .{});
                    return;
                }

                var child = std.process.Child.init(&.{
                    "yad",
                    "--notification",
                    "--image=input-keyboard",
                    "--text=XeMonitor running",
                }, std.heap.page_allocator);
                child.stdin_behavior = .Ignore;
                child.stdout_behavior = .Ignore;
                child.stderr_behavior = .Ignore;

                try child.spawn();
                self.child = child;
                std.debug.print("[info] tray icon enabled (linux/yad).\n", .{});
            },
            .windows => {
                if (!commandSucceeded(&.{ "powershell", "-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()" })) {
                    std.debug.print("[warn] tray icon disabled: 'powershell' not found.\n", .{});
                    return;
                }

                var child = std.process.Child.init(&.{
                    "powershell",
                    "-NoProfile",
                    "-WindowStyle",
                    "Hidden",
                    "-Command",
                    "Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; $n = New-Object System.Windows.Forms.NotifyIcon; $n.Icon = [System.Drawing.SystemIcons]::Application; $n.Text = 'XeMonitor running'; $n.Visible = $true; while ($true) { Start-Sleep -Seconds 3600 }",
                }, std.heap.page_allocator);
                child.stdin_behavior = .Ignore;
                child.stdout_behavior = .Ignore;
                child.stderr_behavior = .Ignore;

                try child.spawn();
                self.child = child;
                std.debug.print("[info] tray icon enabled (windows/powershell).\n", .{});
            },
            else => {
                std.debug.print("[warn] tray icon disabled: unsupported OS '{s}'.\n", .{@tagName(builtin.os.tag)});
            },
        }
    }

    fn stop(self: *TrayIcon) void {
        if (self.child) |*child| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            self.child = null;
        }
    }
};

fn runCommand(argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = try child.spawnAndWait();
}

const KeyboardInjector = enum {
    windows_powershell,
    linux_wayland_ydotool,
    linux_x11_xdotool,
};

fn simulateKeyboardInput(text: []const u8, injector: KeyboardInjector) !void {
    if (text.len == 0) return;

    switch (injector) {
        .windows_powershell => {
            try runCommand(&.{
                "powershell",
                "-NoProfile",
                "-Command",
                "param([string]$t) Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Clipboard]::SetText($t); [System.Windows.Forms.SendKeys]::SendWait('^v')",
                "-t",
                text,
            });
        },
        .linux_wayland_ydotool => {
            try runCommand(&.{ "ydotool", "type", text });
        },
        .linux_x11_xdotool => {
            try runCommand(&.{ "xdotool", "type", "--clearmodifiers", text });
        },
    }
}

fn simulateEnter(injector: KeyboardInjector) !void {
    switch (injector) {
        .windows_powershell => {
            try runCommand(&.{
                "powershell",
                "-NoProfile",
                "-Command",
                "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')",
            });
        },
        .linux_wayland_ydotool => {
            try runCommand(&.{ "ydotool", "key", "28:1", "28:0" });
        },
        .linux_x11_xdotool => {
            try runCommand(&.{ "xdotool", "key", "Return" });
        },
    }
}

fn stripInterleavedSeparator(raw: []const u8, out: []u8) []const u8 {
    if (raw.len < 3 or raw.len % 2 == 0) {
        std.mem.copyForwards(u8, out[0..raw.len], raw);
        return out[0..raw.len];
    }

    const sep = raw[1];
    if (!std.ascii.isDigit(raw[0])) {
        std.mem.copyForwards(u8, out[0..raw.len], raw);
        return out[0..raw.len];
    }

    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (i % 2 == 0) {
            if (!std.ascii.isDigit(raw[i])) {
                std.mem.copyForwards(u8, out[0..raw.len], raw);
                return out[0..raw.len];
            }
        } else if (raw[i] != sep) {
            std.mem.copyForwards(u8, out[0..raw.len], raw);
            return out[0..raw.len];
        }
    }

    if (sep != '3') {
        std.mem.copyForwards(u8, out[0..raw.len], raw);
        return out[0..raw.len];
    }

    var out_len: usize = 0;
    i = 0;
    while (i < raw.len) : (i += 2) {
        out[out_len] = raw[i];
        out_len += 1;
    }
    return out[0..out_len];
}

pub fn main() !u8 {
    const port_name = if (builtin.os.tag == .windows) "\\\\.\\COM1" else "/dev/ttyUSB0";
    const session_type: ?[]u8 = std.process.getEnvVarOwned(std.heap.page_allocator, "XDG_SESSION_TYPE") catch null;
    defer if (session_type) |v| std.heap.page_allocator.free(v);
    const is_wayland = if (session_type) |v| std.ascii.eqlIgnoreCase(v, "wayland") else false;
    const injector: KeyboardInjector = if (builtin.os.tag == .windows)
        .windows_powershell
    else if (is_wayland)
            .linux_wayland_ydotool
        else
            .linux_x11_xdotool;

    std.debug.print("the serial port '{s}' selected .\n", .{port_name});
    std.debug.print("platform={s}, keyboard injector={s}\n", .{
        if (builtin.os.tag == .windows) "windows" else if (is_wayland) "linux-wayland" else "linux-x11/unknown",
        switch (injector) {
            .windows_powershell => "powershell+sendkeys",
            .linux_wayland_ydotool => "ydotool",
            .linux_x11_xdotool => "xdotool",
        },
    });

    var tray = TrayIcon{};
    try tray.start();
    defer tray.stop();

    var serial = std.fs.cwd().openFile(port_name, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Invalid config: the serial port '{s}' does not exist.\n", .{port_name});
            return 1;
        },
        else => return err,
    };
    defer serial.close();

    try zig_serial.configureSerialPort(serial, zig_serial.SerialConfig{
        .baud_rate = 115_200,
        .word_size = .eight,
        .parity = .none,
        .stop_bits = .one,
        .handshake = .none,
    });

    // NOTE: everything is written directly to the serial port so there is no
    // need to flush (because there is no buffering).
    var writer = serial.writer(&.{});

    var r_buf: [128]u8 = undefined;
    var reader = serial.reader(&r_buf);

    try writer.interface.writeAll("Hello, World!\r\n");

    var scan_buffer: [512]u8 = undefined;
    var normalized_buffer: [512]u8 = undefined;
    var scan_len: usize = 0;

    while (true) {
        const b = try reader.interface.takeByte();
        std.debug.print("{c}", .{b});

        if (b == '\r' or b == '\n') {
            const raw_payload = scan_buffer[0..scan_len];
            const payload = stripInterleavedSeparator(raw_payload, &normalized_buffer);

            if (payload.len != raw_payload.len) {
                std.debug.print("\n[info] interleaved '3' removed: '{s}' -> '{s}'\n", .{ raw_payload, payload });
            }

            simulateKeyboardInput(payload, injector) catch |err| {
                std.debug.print("\n[error] failed to inject text: {}\n", .{err});
            };
            simulateEnter(injector) catch |err| {
                std.debug.print("\n[error] failed to inject enter: {}\n", .{err});
            };
            scan_len = 0;
            continue;
        }

        if (b < 0x20 or b == 0x7f) continue;

        if (scan_len >= scan_buffer.len) {
            std.debug.print("\n[warn] scanner payload too long, buffer reset\n", .{});
            scan_len = 0;
            continue;
        }

        scan_buffer[scan_len] = b;
        scan_len += 1;
    }

    return 0;
}
