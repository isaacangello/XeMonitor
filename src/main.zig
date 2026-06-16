const std = @import("std");
const xemonitor = @import("xemonitor");
const zig_serial = @import("serial");
const builtin = @import("builtin");
const c = if (builtin.os.tag == .windows) @cImport({
    @cInclude("libserialport.h");
}) else struct {};
const reconnect_interval_ns: u64 = 2 * std.time.ns_per_s;
const default_port_name = if (builtin.os.tag == .windows) "COM1" else "/dev/ttyUSB0";

const winapi_available = builtin.os.tag == .windows;
const w = if (winapi_available) struct {
    const windows = std.os.windows;

    const DCBFlags = packed struct(u32) {
        fBinary: u1,
        fParity: u1,
        fOutxCtsFlow: u1,
        fOutxDsrFlow: u1,
        fDtrControl: u2,
        fDsrSensitivity: u1,
        fTXContinueOnXoff: u1,
        fOutX: u1,
        fInX: u1,
        fErrorChar: u1,
        fNull: u1,
        fRtsControl: u2,
        fAbortOnError: u1,
        fDummy: u17,
    };

    const DCB = extern struct {
        DCBlength: windows.DWORD,
        BaudRate: windows.DWORD,
        flags: u32,
        wReserved: windows.WORD,
        XonLim: windows.WORD,
        XoffLim: windows.WORD,
        ByteSize: windows.BYTE,
        Parity: windows.BYTE,
        StopBits: windows.BYTE,
        XonChar: u8,
        XoffChar: u8,
        ErrorChar: u8,
        EofChar: u8,
        EvtChar: u8,
        wReserved1: windows.WORD,
    };

    const COMMTIMEOUTS = extern struct {
        ReadIntervalTimeout: windows.DWORD,
        ReadTotalTimeoutMultiplier: windows.DWORD,
        ReadTotalTimeoutConstant: windows.DWORD,
        WriteTotalTimeoutMultiplier: windows.DWORD,
        WriteTotalTimeoutConstant: windows.DWORD,
    };

    extern "kernel32" fn CreateFileA(
        lpFileName: windows.LPCSTR,
        dwDesiredAccess: windows.DWORD,
        dwShareMode: windows.DWORD,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: windows.DWORD,
        dwFlagsAndAttributes: windows.DWORD,
        hTemplateFile: ?windows.HANDLE,
    ) callconv(.winapi) windows.HANDLE;

    extern "kernel32" fn CloseHandle(
        hObject: windows.HANDLE,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn GetCommState(
        hFile: windows.HANDLE,
        lpDCB: *DCB,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn SetCommState(
        hFile: windows.HANDLE,
        lpDCB: *DCB,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn SetCommTimeouts(
        hFile: windows.HANDLE,
        lpCommTimeouts: *COMMTIMEOUTS,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn GetLastError() callconv(.winapi) windows.DWORD;

    extern "kernel32" fn PurgeComm(
        hFile: windows.HANDLE,
        dwFlags: windows.DWORD,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn SetupComm(
        hFile: windows.HANDLE,
        dwInQueue: windows.DWORD,
        dwOutQueue: windows.DWORD,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn BuildCommDCBA(
        lpDef: windows.LPCSTR,
        lpDCB: *DCB,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn Sleep(
        dwMilliseconds: windows.DWORD,
    ) callconv(.winapi) void;

    extern "kernel32" fn CreateMutexA(
        lpMutexAttributes: ?*anyopaque,
        bInitialOwner: windows.BOOL,
        lpName: windows.LPCSTR,
    ) callconv(.winapi) windows.HANDLE;

    const ERROR_ALREADY_EXISTS: windows.DWORD = 183;
} else struct {};

var log_file: ?std.fs.File = null;
var log_mutex: std.Thread.Mutex = .{};

fn logPrint(comptime fmt: []const u8, args: anytype) void {
    log_mutex.lock();
    defer log_mutex.unlock();
    std.debug.print(fmt, args);
    if (log_file) |f| {
        var buf: [4096]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, fmt, args) catch return;
        _ = f.write(out) catch {};
    }
}

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
    use_winapi: bool = false,
    tcp_addr: ?[]u8 = null,
    use_stdin: bool = false,
    no_tray: bool = false,
    kill_existing: bool = false,
};

fn printUsage() void {
    logPrint(
        \\Usage:
        \\  xemonitor [--port <PORT>]
        \\  xemonitor [-p <PORT>]
        \\  xemonitor <PORT>
        \\  xemonitor --winapi      (use native Win32 serial API on Windows)
        \\  xemonitor --tcp <HOST:PORT>  (read from TCP instead of serial)
        \\  xemonitor --stdin           (read from stdin)
        \\  xemonitor --no-tray         (disable system tray icon)
        \\  xemonitor --kill            (terminate a running instance)
        \\
        \\Examples:
        \\  xemonitor --port COM4
        \\  xemonitor COM4
        \\  xemonitor --winapi
        \\  xemonitor --tcp 127.0.0.1:9000
        \\  wsl python3 src/bridge.py | xemonitor --stdin
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

        if (std.mem.eql(u8, arg, "--winapi")) {
            if (!winapi_available) {
                logPrint("[error] --winapi is only supported on Windows.\n", .{});
                return error.InvalidArgument;
            }
            options.use_winapi = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--tcp")) {
            if (i + 1 >= args.len) return error.MissingTcpValue;
            if (options.tcp_addr != null) return error.DuplicateTcpArgument;
            i += 1;
            options.tcp_addr = try allocator.dupe(u8, args[i]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--stdin")) {
            options.use_stdin = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--no-tray")) {
            options.no_tray = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--kill")) {
            options.kill_existing = true;
            continue;
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
                    logPrint("[warn] tray icon disabled: install 'yad' to enable tray support on Linux.\n", .{});
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
                logPrint("[info] tray icon enabled (linux/yad).\n", .{});
            },
            .windows => {
                if (!commandSucceeded(&.{ "powershell", "-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()" })) {
                    logPrint("[warn] tray icon disabled: 'powershell' not found.\n", .{});
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
                logPrint("[info] tray icon enabled (windows/powershell).\n", .{});
            },
            else => {
                logPrint("[warn] tray icon disabled: unsupported OS '{s}'.\n", .{@tagName(builtin.os.tag)});
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
    if (containsIgnoreCase(info.description, "ch34")) score += 4;
    if (containsIgnoreCase(info.description, "serial")) score += 2;
    if (containsIgnoreCase(info.manufacturer, "wch")) score += 2;
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
            logPrint("[probe] serial candidate='{s}', manufacturer='{s}', description='{s}', vid=0x{x:0>4}, pid=0x{x:0>4}, score={d}\n", .{
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
            logPrint("[probe] serial fallback candidate='{s}' ({s})\n", .{ port.file_name, port.display_name });
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
    winapi: if (winapi_available) std.os.windows.HANDLE else void,
    file: std.fs.File,
    tcp: std.net.Stream,
    std_in: void,

    fn close(self: *SerialConnection) void {
        switch (self.*) {
            .windows => |port| {
                _ = c.sp_close(port);
                c.sp_free_port(port);
            },
            .winapi => |handle| {
                if (winapi_available) _ = w.CloseHandle(handle);
            },
            .file => |f| f.close(),
            .tcp => |s| s.close(),
            .std_in => {},
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
            .winapi => |handle| {
                if (!winapi_available) return error.SerialReadFailed;
                var byte: [1]u8 = undefined;
                const bytes_read = std.os.windows.ReadFile(handle, &byte, null) catch {
                    return error.SerialReadFailed;
                };
                if (bytes_read == 0) return error.EndOfStream;
                return byte[0];
            },
            .file => |f| {
                var byte: [1]u8 = undefined;
                const read_len = try f.read(&byte);
                if (read_len == 0) return error.EndOfStream;
                return byte[0];
            },
            .tcp => |s| {
                var byte: [1]u8 = undefined;
                const read_len = try s.read(&byte);
                if (read_len == 0) return error.EndOfStream;
                return byte[0];
            },
            .std_in => {
                var stdin_buf: [1]u8 = undefined;
                const read_len = try std.fs.File.stdin().read(&stdin_buf);
                if (read_len == 0) return error.EndOfStream;
                return stdin_buf[0];
            },
        }
    }
};

fn openAndConfigureSerialWinapi(port_name: []const u8, baud_rate: u32) !SerialConnection {
    const allocator = std.heap.page_allocator;
    const path = if (std.mem.startsWith(u8, port_name, "\\\\.\\"))
        try allocator.dupeZ(u8, port_name)
    else blk: {
        const fmt = try std.fmt.allocPrint(allocator, "\\\\.\\{s}", .{port_name});
        defer allocator.free(fmt);
        break :blk try allocator.dupeZ(u8, fmt);
    };
    defer allocator.free(path);

    const handle = w.CreateFileA(
        path,
        w.windows.GENERIC_READ | w.windows.GENERIC_WRITE,
        0,
        null,
        w.windows.OPEN_EXISTING,
        w.windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == w.windows.INVALID_HANDLE_VALUE) {
        const err_code = w.GetLastError();
        return switch (err_code) {
            2, 3 => error.FileNotFound,
            5 => error.AccessDenied,
            else => error.Unexpected,
        };
    }
    errdefer _ = w.CloseHandle(handle);

    w.Sleep(100);
    _ = w.PurgeComm(handle, 0x0002 | 0x0004 | 0x0008 | 0x0010);
    _ = w.SetupComm(handle, 4096, 4096);

    var dcb: w.DCB = undefined;
    dcb.DCBlength = @sizeOf(w.DCB);
    const mode_fmt = try std.fmt.allocPrint(allocator, "baud={d} parity=N data=8 stop=1", .{baud_rate});
    defer allocator.free(mode_fmt);
    const mode_z = try allocator.dupeZ(u8, mode_fmt);
    defer allocator.free(mode_z);

    if (w.BuildCommDCBA(mode_z, &dcb) == 0) {
        logPrint("[debug] BuildCommDCBA failed, last error={d}\n", .{w.GetLastError()});
        _ = w.CloseHandle(handle);
        return error.InvalidArgument;
    }

    dcb.DCBlength = @sizeOf(w.DCB);
    dcb.XonLim = 0;
    dcb.XoffLim = 0;
    dcb.XonChar = 0;
    dcb.XoffChar = 0;
    dcb.ErrorChar = 0;
    dcb.EofChar = 0;
    dcb.EvtChar = 0;
    dcb.wReserved1 = 0;

    logPrint("[debug] DCB size={d}, trying SetCommState (baud={d})...\n", .{ @sizeOf(w.DCB), baud_rate });

    if (w.SetCommState(handle, &dcb) == 0) {
        const err = w.GetLastError();
        logPrint("[debug] SetCommState failed, last error={d}\n", .{err});

        logPrint("[debug] retrying with DTR/RTS disabled...\n", .{});
        const flags: u32 = @bitCast(w.DCBFlags{
            .fBinary = 1,
            .fParity = 0,
            .fOutxCtsFlow = 0,
            .fOutxDsrFlow = 0,
            .fDtrControl = 0,
            .fDsrSensitivity = 0,
            .fTXContinueOnXoff = 0,
            .fOutX = 0,
            .fInX = 0,
            .fErrorChar = 0,
            .fNull = 0,
            .fRtsControl = 0,
            .fAbortOnError = 0,
            .fDummy = 0,
        });
        dcb.flags = flags;
        dcb.DCBlength = @sizeOf(w.DCB);
        w.Sleep(100);

        if (w.SetCommState(handle, &dcb) == 0) {
            logPrint("[debug] SetCommState (no DTR/RTS) failed too, last error={d}\n", .{w.GetLastError()});
            _ = w.CloseHandle(handle);
            return error.InvalidArgument;
        }
    }

    var timeouts: w.COMMTIMEOUTS = .{
        .ReadIntervalTimeout = 1,
        .ReadTotalTimeoutMultiplier = 0,
        .ReadTotalTimeoutConstant = 1000,
        .WriteTotalTimeoutMultiplier = 0,
        .WriteTotalTimeoutConstant = 0,
    };
    if (w.SetCommTimeouts(handle, &timeouts) == 0) {
        logPrint("[debug] SetCommTimeouts failed, last error={d}\n", .{w.GetLastError()});
        _ = w.CloseHandle(handle);
        return error.InvalidArgument;
    }

    return .{ .winapi = handle };
}

fn connectTcp(addr: []const u8) !SerialConnection {
    const colon_pos = std.mem.indexOfScalar(u8, addr, ':') orelse return error.InvalidAddress;
    const host = addr[0..colon_pos];
    const port_str = addr[colon_pos + 1 ..];
    const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;

    const address = try std.net.Address.parseIp(host, port);
    const stream = try std.net.tcpConnectToAddress(address);
    logPrint("[info] connected to TCP {s}:{d}\n", .{ host, port });
    return .{ .tcp = stream };
}

fn openAndConfigureSerial(port_name: []const u8, baud_rate: u32, use_winapi: bool) !SerialConnection {
    if (builtin.os.tag == .windows) {
        if (use_winapi) return openAndConfigureSerialWinapi(port_name, baud_rate);

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
    log_file = std.fs.cwd().createFile("xemonitor.log", .{ .truncate = false }) catch null;
    defer if (log_file) |f| f.close();
    logPrint("[info] log file: xemonitor.log\n", .{});

    const cli = parseCliOptions(std.heap.page_allocator) catch |err| switch (err) {
        error.HelpRequested => return 0,
        else => {
            logPrint("[error] invalid arguments: {}\n", .{err});
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
                logPrint("[warn] invalid XEMONITOR_BAUD='{s}', using default 115200.\n", .{v});
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

    if (cli.kill_existing) {
        if (builtin.os.tag == .windows) {
            logPrint("[info] killing running xemonitor instances...\n", .{});
            var child = std.process.Child.init(&.{ "taskkill", "/F", "/IM", "xemonitor.exe" }, std.heap.page_allocator);
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;
            child.spawn() catch |err| {
                logPrint("[warn] taskkill failed: {}\n", .{err});
            };
        } else {
            logPrint("[info] killing running xemonitor instances...\n", .{});
            var child = std.process.Child.init(&.{ "pkill", "-9", "xemonitor" }, std.heap.page_allocator);
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;
            child.spawn() catch |err| {
                logPrint("[warn] pkill failed: {}\n", .{err});
            };
        }
        return 0;
    }

    if (winapi_available) {
        const mutex = w.CreateMutexA(null, 1, "Global\\XeMonitor");
        if (w.GetLastError() == w.ERROR_ALREADY_EXISTS) {
            logPrint("[error] another instance of xemonitor is already running.\n", .{});
            _ = w.CloseHandle(mutex);
            return 1;
        }
    }

    logPrint("serial baud rate={d}\n", .{baud_rate});
    if (winapi_available and cli.use_winapi) {
        logPrint("serial backend=winapi (native)\n", .{});
    } else if (builtin.os.tag == .windows) {
        logPrint("serial backend=libserialport\n", .{});
    }
    logPrint("platform={s}, keyboard injector={s}\n", .{
        if (builtin.os.tag == .windows) "windows" else if (is_wayland) "linux-wayland" else "linux-x11/unknown",
        switch (injector) {
            .windows_powershell => "powershell+sendkeys",
            .linux_wayland_ydotool => "ydotool",
            .linux_x11_xdotool => "xdotool",
        },
    });

    var tray = TrayIcon{};
    if (!cli.no_tray) {
        try tray.start();
    }
    defer if (!cli.no_tray) tray.stop();

    var did_report_missing_port = false;
    var last_selected_port: ?[]u8 = null;
    var last_selected_source: ?PortSource = null;
    defer if (last_selected_port) |v| std.heap.page_allocator.free(v);

    if (cli.use_stdin) {
        logPrint("[info] stdin mode: reading from standard input.\n", .{});
        var scan_buffer: [512]u8 = undefined;
        var normalized_buffer: [512]u8 = undefined;
        var scan_len: usize = 0;

        while (true) {
            const b = blk: {
                var byte: [1]u8 = undefined;
                const read_len = std.fs.File.stdin().read(&byte) catch |err| {
                    logPrint("\n[warn] stdin read failed: {}\n", .{err});
                    return 1;
                };
                if (read_len == 0) {
                    logPrint("[info] stdin closed.\n", .{});
                    return 0;
                }
                break :blk byte[0];
            };
            logPrint("{c}", .{b});

            if (b == '\r' or b == '\n') {
                const raw_payload = scan_buffer[0..scan_len];
                const payload = stripInterleavedSeparator(raw_payload, &normalized_buffer);
                if (payload.len != raw_payload.len) {
                    logPrint("\n[info] interleaved '3' removed: '{s}' -> '{s}'\n", .{ raw_payload, payload });
                }
                simulateKeyboardInput(payload, injector) catch |err| {
                    logPrint("\n[error] failed to inject text: {}\n", .{err});
                };
                simulateEnter(injector) catch |err| {
                    logPrint("\n[error] failed to inject enter: {}\n", .{err});
                };
                scan_len = 0;
                continue;
            }

            if (b < 0x20 or b == 0x7f) continue;
            if (scan_len >= scan_buffer.len) {
                logPrint("\n[warn] scanner payload too long, buffer reset\n", .{});
                scan_len = 0;
                continue;
            }
            scan_buffer[scan_len] = b;
            scan_len += 1;
        }
    } else if (cli.tcp_addr) |tcp_addr| {
        logPrint("[info] TCP mode: connecting to {s}\n", .{tcp_addr});
        while (true) {
            var serial = connectTcp(tcp_addr) catch |err| {
                logPrint("[warn] TCP connect failed: {}. retrying in 2s...\n", .{err});
                sleepBeforeRetry();
                continue;
            };
            defer serial.close();

            var scan_buffer: [512]u8 = undefined;
            var normalized_buffer: [512]u8 = undefined;
            var scan_len: usize = 0;

            while (true) {
                const b = serial.readByte() catch |err| {
                    logPrint("\n[warn] TCP read failed: {}. reconnecting...\n", .{err});
                    break;
                };
                logPrint("{c}", .{b});

                if (b == '\r' or b == '\n') {
                    const raw_payload = scan_buffer[0..scan_len];
                    const payload = stripInterleavedSeparator(raw_payload, &normalized_buffer);

                    if (payload.len != raw_payload.len) {
                        logPrint("\n[info] interleaved '3' removed: '{s}' -> '{s}'\n", .{ raw_payload, payload });
                    }

                    simulateKeyboardInput(payload, injector) catch |err| {
                        logPrint("\n[error] failed to inject text: {}\n", .{err});
                    };
                    simulateEnter(injector) catch |err| {
                        logPrint("\n[error] failed to inject enter: {}\n", .{err});
                    };
                    scan_len = 0;
                    continue;
                }

                if (b < 0x20 or b == 0x7f) continue;

                if (scan_len >= scan_buffer.len) {
                    logPrint("\n[warn] scanner payload too long, buffer reset\n", .{});
                    scan_len = 0;
                    continue;
                }

                scan_buffer[scan_len] = b;
                scan_len += 1;
            }

            sleepBeforeRetry();
        }
    } else {
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
                logPrint("the serial port '{s}' selected (source={s}).\n", .{
                    port_choice.name,
                    portSourceLabel(port_choice.source),
                });
            }

            var serial = openAndConfigureSerial(port_choice.name, baud_rate, cli.use_winapi) catch |err| switch (err) {
                error.FileNotFound => {
                    if (!did_report_missing_port) {
                        logPrint("[warn] serial port '{s}' (source={s}) not found. retrying selection every 2s...\n", .{
                            port_choice.name,
                            portSourceLabel(port_choice.source),
                        });
                        if (builtin.os.tag == .windows) {
                            logPrint("[hint] Set XEMONITOR_PORT (example: COM3). You can also set XEMONITOR_BAUD.\n", .{});
                            if (!cli.use_winapi) {
                                logPrint("[hint] Try --winapi flag for native Win32 serial API (may fix access issues).\n", .{});
                            }
                        }
                        did_report_missing_port = true;
                    }
                    sleepBeforeRetry();
                    continue;
                },
                else => {
                    logPrint("[warn] failed to open/configure serial port '{s}' (source={s}, baud={d}): {}. retrying in 2s...\n", .{
                        port_choice.name,
                        portSourceLabel(port_choice.source),
                        baud_rate,
                        err,
                    });
                    if (builtin.os.tag == .windows and !cli.use_winapi) {
                        logPrint("[hint] Try --winapi flag for native Win32 serial API (may fix access issues).\n", .{});
                    }
                    sleepBeforeRetry();
                    continue;
                },
            };
            defer serial.close();

            if (did_report_missing_port) {
                logPrint("[info] serial port '{s}' is now available.\n", .{port_choice.name});
                did_report_missing_port = false;
            }

            var scan_buffer: [512]u8 = undefined;
            var normalized_buffer: [512]u8 = undefined;
            var scan_len: usize = 0;

            while (true) {
                const b = serial.readByte() catch |err| {
                    logPrint("\n[warn] serial read failed on '{s}': {}. reconnecting...\n", .{ port_choice.name, err });
                    break;
                };
                logPrint("{c}", .{b});

                if (b == '\r' or b == '\n') {
                    const raw_payload = scan_buffer[0..scan_len];
                    const payload = stripInterleavedSeparator(raw_payload, &normalized_buffer);

                    if (payload.len != raw_payload.len) {
                        logPrint("\n[info] interleaved '3' removed: '{s}' -> '{s}'\n", .{ raw_payload, payload });
                    }

                    simulateKeyboardInput(payload, injector) catch |err| {
                        logPrint("\n[error] failed to inject text: {}\n", .{err});
                    };
                    simulateEnter(injector) catch |err| {
                        logPrint("\n[error] failed to inject enter: {}\n", .{err});
                    };
                    scan_len = 0;
                    continue;
                }

                if (b < 0x20 or b == 0x7f) continue;

                if (scan_len >= scan_buffer.len) {
                    logPrint("\n[warn] scanner payload too long, buffer reset\n", .{});
                    scan_len = 0;
                    continue;
                }

                scan_buffer[scan_len] = b;
                scan_len += 1;
            }

            sleepBeforeRetry();
        }
    }

    return 0;
}
