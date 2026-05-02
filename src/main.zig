const std = @import("std");
const xemonitor = @import("xemonitor");
const zig_serial = @import("serial");
const builtin = @import("builtin");
const c = if (builtin.os.tag == .windows) @cImport({
    @cInclude("libserialport.h");
}) else struct {};
const reconnect_interval_ns: u64 = 2 * std.time.ns_per_s;
const default_port_name = if (builtin.os.tag == .windows) "COM1" else "/dev/ttyUSB0";

const PortSource = enum {
    cli,
    auto,
    env,
    default,
};

const PortChoice = struct {
    name: []u8,
    source: PortSource,
};

fn portSourceLabel(source: PortSource) []const u8 {
    return switch (source) {
        .cli => "cli-arg",
        .auto => "auto-detect",
        .env => "XEMONITOR_PORT",
        .default => "default",
    };
}

const CliOptions = struct {
    port_override: ?[]u8 = null,
};

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  xemonitor [--port <PORT>]
        \\  xemonitor [-p <PORT>]
        \\  xemonitor <PORT>
        \\
        \\Examples:
        \\  xemonitor --port COM4
        \\  xemonitor COM4
        \\
    , .{});
}

fn parseCliOptions(allocator: std.mem.Allocator) !CliOptions {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var options = CliOptions{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return error.HelpRequested;
        }

        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--port")) {
            if (i + 1 >= args.len) return error.MissingPortValue;
            if (options.port_override != null) return error.DuplicatePortArgument;
            i += 1;
            options.port_override = try normalizePortNameOwned(allocator, args[i]);
            continue;
        }

        if (arg.len > 0 and arg[0] == '-') return error.InvalidArgument;
        if (options.port_override != null) return error.DuplicatePortArgument;
        options.port_override = try normalizePortNameOwned(allocator, arg);
    }

    return options;
}

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

fn sleepBeforeRetry() void {
    std.Thread.sleep(reconnect_interval_ns);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
            return true;
        }
    }

    return false;
}

fn normalizePortNameOwned(allocator: std.mem.Allocator, port_name: []const u8) ![]u8 {
    if (builtin.os.tag != .windows) return allocator.dupe(u8, port_name);

    // libserialport on Windows expects COM labels (e.g. COM3).
    const trimmed = std.mem.trim(u8, port_name, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "\\\\.\\")) {
        const without_prefix = trimmed[4..];
        if (without_prefix.len > 0) return allocator.dupe(u8, without_prefix);
    }
    return allocator.dupe(u8, trimmed);
}

fn serialInfoScore(info: zig_serial.PortInformation) u8 {
    var score: u8 = 0;

    if (containsIgnoreCase(info.manufacturer, "honeywell")) score += 8;
    if (containsIgnoreCase(info.description, "xenon")) score += 6;
    if (containsIgnoreCase(info.description, "1900")) score += 4;
    if (containsIgnoreCase(info.friendly_name, "xenon")) score += 3;
    if (containsIgnoreCase(info.friendly_name, "barcode")) score += 2;

    return score;
}

fn detectAutoSerialPort(allocator: std.mem.Allocator) !?[]u8 {
    var best_port: ?[]u8 = null;
    var best_score: u8 = 0;
    var fallback_port: ?[]u8 = null;
    errdefer {
        if (best_port) |v| allocator.free(v);
        if (fallback_port) |v| allocator.free(v);
    }

    var info_iter = zig_serial.list_info() catch null;
    if (info_iter) |*iter| {
        defer iter.deinit();

        while (try iter.next()) |info| {
            const score = serialInfoScore(info);
            std.debug.print("[probe] serial candidate='{s}', manufacturer='{s}', description='{s}', vid=0x{x:0>4}, pid=0x{x:0>4}, score={d}\n", .{
                info.system_location,
                info.manufacturer,
                info.description,
                info.vid,
                info.pid,
                score,
            });

            if (fallback_port == null) {
                fallback_port = try allocator.dupe(u8, info.system_location);
            }

            if (score > best_score) {
                if (best_port) |v| allocator.free(v);
                best_port = try allocator.dupe(u8, info.system_location);
                best_score = score;
            }
        }
    }

    if (best_port) |v| {
        if (fallback_port) |f| allocator.free(f);
        return v;
    }
    if (fallback_port) |v| {
        return v;
    }

    var list_iter = zig_serial.list() catch null;
    if (list_iter) |*iter| {
        defer iter.deinit();

        if (try iter.next()) |port| {
            std.debug.print("[probe] serial fallback candidate='{s}' ({s})\n", .{ port.file_name, port.display_name });
            return try allocator.dupe(u8, port.file_name);
        }
    }

    return null;
}

fn resolvePortChoice(allocator: std.mem.Allocator, cli_port: ?[]const u8) !PortChoice {
    if (cli_port) |port| {
        return .{
            .name = try allocator.dupe(u8, port),
            .source = .cli,
        };
    }

    const env_port = std.process.getEnvVarOwned(allocator, "XEMONITOR_PORT") catch null;
    if (env_port) |port| {
        defer allocator.free(port);
        return .{
            .name = try normalizePortNameOwned(allocator, port),
            .source = .env,
        };
    }

    if (try detectAutoSerialPort(allocator)) |auto_port| {
        return .{
            .name = auto_port,
            .source = .auto,
        };
    }

    return .{
        .name = try allocator.dupe(u8, default_port_name),
        .source = .default,
    };
}

const SerialConnection = union(enum) {
    windows: *c.struct_sp_port,
    file: std.fs.File,

    fn close(self: *SerialConnection) void {
        switch (self.*) {
            .windows => |port| {
                _ = c.sp_close(port);
                c.sp_free_port(port);
            },
            .file => |f| f.close(),
        }
    }

    fn readByte(self: *SerialConnection) !u8 {
        switch (self.*) {
            .windows => |port| {
                var byte: [1]u8 = undefined;
                while (true) {
                    const rc = c.sp_blocking_read(port, &byte, 1, 1_000);
                    if (rc == 1) return byte[0];
                    if (rc == 0) continue;
                    return error.SerialReadFailed;
                }
            },
            .file => |f| {
                var byte: [1]u8 = undefined;
                const read_len = try f.read(&byte);
                if (read_len == 0) return error.EndOfStream;
                return byte[0];
            },
        }
    }
};

fn openAndConfigureSerial(port_name: []const u8, baud_rate: u32) !SerialConnection {
    if (builtin.os.tag == .windows) {
        const allocator = std.heap.page_allocator;
        const normalized_name = try normalizePortNameOwned(allocator, port_name);
        defer allocator.free(normalized_name);

        const c_port_name = try allocator.dupeZ(u8, normalized_name);
        defer allocator.free(c_port_name);

        var port: ?*c.struct_sp_port = null;
        if (c.sp_get_port_by_name(c_port_name, &port) != c.SP_OK or port == null) {
            return error.FileNotFound;
        }
        errdefer if (port) |p| c.sp_free_port(p);

        if (c.sp_open(port.?, c.SP_MODE_READ_WRITE) != c.SP_OK) return error.AccessDenied;
        errdefer _ = c.sp_close(port.?);

        if (c.sp_set_baudrate(port.?, @as(c_int, @intCast(baud_rate))) != c.SP_OK) return error.InvalidArgument;
        if (c.sp_set_bits(port.?, 8) != c.SP_OK) return error.InvalidArgument;
        if (c.sp_set_parity(port.?, c.SP_PARITY_NONE) != c.SP_OK) return error.InvalidArgument;
        if (c.sp_set_stopbits(port.?, 1) != c.SP_OK) return error.InvalidArgument;
        if (c.sp_set_flowcontrol(port.?, c.SP_FLOWCONTROL_NONE) != c.SP_OK) return error.InvalidArgument;
        if (c.sp_set_dtr(port.?, c.SP_DTR_ON) != c.SP_OK) return error.InvalidArgument;
        if (c.sp_set_rts(port.?, c.SP_RTS_ON) != c.SP_OK) return error.InvalidArgument;

        return .{ .windows = port.? };
    }

    var serial = blk: {
        if (std.fs.path.isAbsolute(port_name)) {
            break :blk std.fs.openFileAbsolute(port_name, .{ .mode = .read_write });
        }
        break :blk std.fs.cwd().openFile(port_name, .{ .mode = .read_write });
    } catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };

    zig_serial.configureSerialPort(serial, zig_serial.SerialConfig{
        .baud_rate = baud_rate,
        .word_size = .eight,
        .parity = .none,
        .stop_bits = .one,
        .handshake = .none,
    }) catch |err| {
        serial.close();
        return err;
    };

    return .{ .file = serial };
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
    const cli = parseCliOptions(std.heap.page_allocator) catch |err| switch (err) {
        error.HelpRequested => return 0,
        else => {
            std.debug.print("[error] invalid arguments: {}\n", .{err});
            printUsage();
            return 2;
        },
    };
    defer if (cli.port_override) |v| std.heap.page_allocator.free(v);

    const baud_env: ?[]u8 = std.process.getEnvVarOwned(std.heap.page_allocator, "XEMONITOR_BAUD") catch null;
    defer if (baud_env) |v| std.heap.page_allocator.free(v);
    const baud_rate: u32 = blk: {
        if (baud_env) |v| {
            break :blk std.fmt.parseInt(u32, v, 10) catch {
                std.debug.print("[warn] invalid XEMONITOR_BAUD='{s}', using default 115200.\n", .{v});
                break :blk 115_200;
            };
        }
        break :blk 115_200;
    };
    const session_type: ?[]u8 = std.process.getEnvVarOwned(std.heap.page_allocator, "XDG_SESSION_TYPE") catch null;
    defer if (session_type) |v| std.heap.page_allocator.free(v);
    const is_wayland = if (session_type) |v| std.ascii.eqlIgnoreCase(v, "wayland") else false;
    const injector: KeyboardInjector = if (builtin.os.tag == .windows)
        .windows_powershell
    else if (is_wayland)
        .linux_wayland_ydotool
    else
        .linux_x11_xdotool;

    std.debug.print("serial baud rate={d}\n", .{baud_rate});
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

    var did_report_missing_port = false;
    var last_selected_port: ?[]u8 = null;
    var last_selected_source: ?PortSource = null;
    defer if (last_selected_port) |v| std.heap.page_allocator.free(v);

    while (true) {
        const port_choice = try resolvePortChoice(std.heap.page_allocator, cli.port_override);
        defer std.heap.page_allocator.free(port_choice.name);

        const selection_changed = blk: {
            if (last_selected_port == null) break :blk true;
            if (last_selected_source == null or last_selected_source.? != port_choice.source) break :blk true;
            break :blk !std.mem.eql(u8, last_selected_port.?, port_choice.name);
        };
        if (selection_changed) {
            if (last_selected_port) |v| std.heap.page_allocator.free(v);
            last_selected_port = try std.heap.page_allocator.dupe(u8, port_choice.name);
            last_selected_source = port_choice.source;
            did_report_missing_port = false;
            std.debug.print("the serial port '{s}' selected (source={s}).\n", .{
                port_choice.name,
                portSourceLabel(port_choice.source),
            });
        }

        var serial = openAndConfigureSerial(port_choice.name, baud_rate) catch |err| switch (err) {
            error.FileNotFound => {
                if (!did_report_missing_port) {
                    std.debug.print("[warn] serial port '{s}' (source={s}) not found. retrying selection every 2s...\n", .{
                        port_choice.name,
                        portSourceLabel(port_choice.source),
                    });
                    if (builtin.os.tag == .windows) {
                        std.debug.print("[hint] Set XEMONITOR_PORT (example: COM3). You can also set XEMONITOR_BAUD.\n", .{});
                    }
                    did_report_missing_port = true;
                }
                sleepBeforeRetry();
                continue;
            },
            else => {
                std.debug.print("[warn] failed to open/configure serial port '{s}' (source={s}, baud={d}): {}. retrying in 2s...\n", .{
                    port_choice.name,
                    portSourceLabel(port_choice.source),
                    baud_rate,
                    err,
                });
                sleepBeforeRetry();
                continue;
            },
        };
        defer serial.close();

        if (did_report_missing_port) {
            std.debug.print("[info] serial port '{s}' is now available.\n", .{port_choice.name});
            did_report_missing_port = false;
        }

        var scan_buffer: [512]u8 = undefined;
        var normalized_buffer: [512]u8 = undefined;
        var scan_len: usize = 0;

        while (true) {
            const b = serial.readByte() catch |err| {
                std.debug.print("\n[warn] serial read failed on '{s}': {}. reconnecting...\n", .{ port_choice.name, err });
                break;
            };
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

        sleepBeforeRetry();
    }

    return 0;
}
