const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const SDLBackend = @import("sdl3-backend");
const tray_mod = @import("tray.zig");
const paths = @import("paths.zig");
const i18n = @import("i18n.zig");
const build_options = @import("build_options");

const os = builtin.os.tag;

const APP_NAME = "XeMonitor";
const APP_TITLE = "XeMonitor " ++ build_options.version;
const CONFIG_FILE = paths.GUI_CONFIG_FILE;
/// Nome-base legado; o log atual é datado (xemonitor-YYYY-MM-DD.log).
const DEFAULT_LOG = "xemonitor.log";

const ns_per_s = std.time.ns_per_s;

const GUI_PID_FILE = paths.GUI_PID_FILE;

var gui_cfg_dir: paths.ConfigDir = undefined;

fn sleepMs(ms: u64) void {
    if (os != .linux) return;
    var req = std.os.linux.timespec{
        .sec = @intCast(@divTrunc(@as(i128, ms) * std.time.ns_per_ms, std.time.ns_per_s)),
        .nsec = @intCast((ms * std.time.ns_per_ms) % std.time.ns_per_s),
    };
    _ = std.os.linux.nanosleep(&req, null);
}

fn getCurrentPid() u32 {
    return if (comptime os == .windows)
        std.os.windows.GetCurrentProcessId()
    else
        @intCast(std.os.linux.getpid());
}

fn readPidFile(io: std.Io) ?u32 {
    var buf: [32]u8 = undefined;
    const data = gui_cfg_dir.dir.readFile(io, GUI_PID_FILE, &buf) catch return null;
    const s = std.mem.trim(u8, data, " \t\r\n");
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn pidAlive(pid: u32) bool {
    if (os != .linux) return false;
    const r = std.posix.kill(@as(std.posix.pid_t, @intCast(pid)), @enumFromInt(0));
    return !std.meta.isError(r);
}

fn writePidFile(io: std.Io) void {
    var f = gui_cfg_dir.dir.createFile(io, GUI_PID_FILE, .{}) catch return;
    defer f.close(io);
    var buf: [32]u8 = undefined;
    const pid: u32 = @intCast(getCurrentPid());
    const s = std.fmt.bufPrint(&buf, "{d}\n", .{pid}) catch return;
    var wbuf: [32]u8 = undefined;
    var w = f.writer(io, &wbuf);
    w.interface.writeAll(s) catch {};
    w.interface.flush() catch {};
}

fn removePidFile(io: std.Io) void {
    gui_cfg_dir.dir.deleteFile(io, GUI_PID_FILE) catch {};
}

// kwin --replace: se outra instancia viva existir, mata e assume; com
// replace=false, sai com erro em vez de duplicar.
fn enforceSingleInstance(io: std.Io, replace: bool) void {
    if (readPidFile(io)) |old_pid| {
        if (pidAlive(old_pid)) {
            if (replace) {
                if (os == .linux) {
                    std.debug.print("xemonitor-gui: substituindo instancia antiga (PID {d})\n", .{old_pid});
                    _ = std.posix.kill(@as(std.posix.pid_t, @intCast(old_pid)), std.posix.SIG.TERM) catch {};
                    sleepMs(500);
                    _ = std.posix.kill(@as(std.posix.pid_t, @intCast(old_pid)), std.posix.SIG.KILL) catch {};
                    sleepMs(200);
                }
            } else {
                std.debug.print("xemonitor-gui ja esta rodando (PID {d}). Use --replace para substituir.\n", .{old_pid});
                std.process.exit(1);
            }
        }
    }
    writePidFile(io);
}

// ---------- config ----------

const Config = struct {
    tcp_host: []u8,
    tcp_port: u16,
    server_mode: []u8,
    bridge_path: []u8,
    client_path: []u8,
    log_path: []u8,
    auto_start: bool,
    tray_enabled: bool,
    lang: []u8,
};

// Detecta qual unit do bridge esta realmente rodando (Linux). Pode ajudar a
// reconciliar configuracoes antigas (e.g., server_mode=systemd-system mas so
// ha unit de usuario ativo). Retorna o nome canonico do server_mode a usar.
fn detectActiveServerMode(gpa: std.mem.Allocator, io: std.Io) []const u8 {
    // So faz sentido no Linux.
    if (os != .linux) return "subprocess";

    const system_active = runCommand(gpa, io, &.{ "systemctl", "is-active", "xemonitor-bridge" }).ok;
    const user_active = runCommand(gpa, io, &.{ "systemctl", "--user", "is-active", "xemonitor-bridge" }).ok;

    if (system_active and !user_active) return "systemd-system";
    if (user_active and !system_active) return "systemd-user";
    if (system_active and user_active) {
        // Conflito: os dois estao ativos. System ganha (padrao do install.sh
        // v0.8.0+), mas logamos o problema.
        std.debug.print("[gui] warning: system E user units ativos; usando systemd-system. Desabilite um.\n", .{});
        return "systemd-system";
    }
    return "systemd-system";
}

fn defaultConfig(gpa: std.mem.Allocator) Config {
    return .{
        .tcp_host = gpa.dupe(u8, "127.0.0.1") catch "",
        .tcp_port = 9000,
        .server_mode = gpa.dupe(u8, "subprocess") catch "",
        .bridge_path = gpa.dupe(u8, "") catch "",
        .client_path = gpa.dupe(u8, "") catch "",
        .log_path = gpa.dupe(u8, DEFAULT_LOG) catch "",
        .auto_start = false,
        .tray_enabled = true,
        .lang = gpa.dupe(u8, "us") catch "",
    };
}

fn loadConfig(gpa: std.mem.Allocator, io: std.Io, path: []const u8) Config {
    var cfg = defaultConfig(gpa);
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, std.Io.Limit.limited(64 * 1024)) catch return cfg;
    defer gpa.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\"");
        setField(gpa, &cfg, key, value);
    }
    return cfg;
}

fn setField(gpa: std.mem.Allocator, cfg: *Config, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "tcp_host")) {
        gpa.free(cfg.tcp_host);
        cfg.tcp_host = gpa.dupe(u8, value) catch return;
    } else if (std.mem.eql(u8, key, "tcp_port")) {
        cfg.tcp_port = std.fmt.parseInt(u16, value, 10) catch cfg.tcp_port;
    } else if (std.mem.eql(u8, key, "server_mode")) {
        gpa.free(cfg.server_mode);
        cfg.server_mode = gpa.dupe(u8, value) catch return;
    } else if (std.mem.eql(u8, key, "bridge_path")) {
        gpa.free(cfg.bridge_path);
        cfg.bridge_path = gpa.dupe(u8, value) catch return;
    } else if (std.mem.eql(u8, key, "client_path")) {
        gpa.free(cfg.client_path);
        cfg.client_path = gpa.dupe(u8, value) catch return;
    } else if (std.mem.eql(u8, key, "log_path")) {
        gpa.free(cfg.log_path);
        cfg.log_path = gpa.dupe(u8, value) catch return;
    } else if (std.mem.eql(u8, key, "auto_start")) {
        cfg.auto_start = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "tray_enabled")) {
        cfg.tray_enabled = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
    } else if (std.mem.eql(u8, key, "lang")) {
        gpa.free(cfg.lang);
        cfg.lang = gpa.dupe(u8, value) catch return;
    }
}

fn saveConfig(gpa: std.mem.Allocator, io: std.Io, path: []const u8, cfg: *const Config) void {
    const data = std.fmt.allocPrint(gpa,
        "tcp_host={s}\ntcp_port={d}\nserver_mode={s}\nbridge_path={s}\nclient_path={s}\nlog_path={s}\nauto_start={s}\ntray_enabled={s}\nlang={s}\n",
        .{ cfg.tcp_host, cfg.tcp_port, cfg.server_mode, cfg.bridge_path, cfg.client_path, cfg.log_path, @as([]const u8, if (cfg.auto_start) "true" else "false"), @as([]const u8, if (cfg.tray_enabled) "true" else "false"), cfg.lang },
    ) catch return;
    defer gpa.free(data);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch {};
}

// ---------- managed child process ----------

const ManagedProc = struct {
    mutex: std.Io.Mutex = .init,
    child: ?std.process.Child = null,
    child_pid: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_exit: u8 = 0,

    // Optional stderr line capture (set before start()).
    capture_stderr: bool = false,
    alloc: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    q_mutex: std.Io.Mutex = .init,
    line_q: std.ArrayList([]u8) = .empty,
    q_stopping: bool = false,

    const WaitCtx = struct {
        proc: *ManagedProc,
        io: std.Io,
    };

    const StderrCtx = struct {
        proc: *ManagedProc,
        io: std.Io,
    };

    fn waiter(ctx: WaitCtx) void {
        ctx.proc.mutex.lock(ctx.io) catch {};
        if (ctx.proc.child) |*ch| {
            const term = ch.wait(ctx.io) catch null;
            if (term) |t| {
                if (t == .exited) ctx.proc.last_exit = t.exited;
            }
        }
        ctx.proc.child = null;
        ctx.proc.child_pid.store(0, .seq_cst);
        ctx.proc.mutex.unlock(ctx.io);
        ctx.proc.running.store(false, .seq_cst);
    }

    fn start(self: *ManagedProc, io: std.Io, argv: []const []const u8) !void {
        self.stop(io);
        self.io = io;
        const stderr_pipe: std.process.SpawnOptions.StdIo = if (self.capture_stderr) .pipe else .inherit;
        const child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = stderr_pipe,
            .create_no_window = true,
        });
        self.mutex.lock(io) catch {};
        self.child = child;
        const pid: u32 = if (comptime os == .windows) blk: {
            const h = child.id orelse break :blk 0;
            break :blk @intCast(@intFromPtr(h));
        } else @intCast(child.id orelse 0);
        self.child_pid.store(pid, .seq_cst);
        self.running.store(true, .seq_cst);
        self.mutex.unlock(io);
        self.q_mutex.lock(io) catch {};
        self.q_stopping = false;
        self.q_mutex.unlock(io);
        if (self.capture_stderr) {
            const t0 = std.Thread.spawn(.{}, stderrReader, .{StderrCtx{ .proc = self, .io = io }}) catch {
                self.stop(io);
                return error.ThreadSpawnFailed;
            };
            t0.detach();
        }
        const t = std.Thread.spawn(.{}, waiter, .{WaitCtx{ .proc = self, .io = io }}) catch {
            self.stop(io);
            return error.ThreadSpawnFailed;
        };
        t.detach();
    }

    fn stop(self: *ManagedProc, io: std.Io) void {
        self.q_mutex.lock(io) catch {};
        self.q_stopping = true;
        self.q_mutex.unlock(io);
        // The waiter thread holds `mutex` while blocked in `ch.wait` for a live
        // child, so locking `mutex` before signalling the child would deadlock
        // (the child would never receive SIGTERM). Signal by pid directly first:
        // SIGTERM, then a SIGKILL fallback so stop() can never hang.
        if (comptime os != .windows) {
            const pid = self.child_pid.load(.seq_cst);
            if (pid != 0) {
                _ = std.posix.kill(@as(std.posix.pid_t, @intCast(pid)), .TERM) catch {};
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(500), .awake) catch {};
                _ = std.posix.kill(@as(std.posix.pid_t, @intCast(pid)), .KILL) catch {};
            }
        }
        self.mutex.lock(io) catch {};
        if (self.child) |*ch| {
            ch.kill(io);
            self.child = null;
        }
        self.running.store(false, .seq_cst);
        self.mutex.unlock(io);
    }
};

fn enqueueLine(proc: *ManagedProc, io: std.Io, line: []const u8) void {
    const dup = proc.alloc.dupe(u8, line) catch return;
    proc.q_mutex.lock(io) catch {
        proc.alloc.free(dup);
        return;
    };
    if (proc.q_stopping) {
        proc.q_mutex.unlock(io);
        proc.alloc.free(dup);
        return;
    }
    proc.line_q.append(proc.alloc, dup) catch {
        proc.q_mutex.unlock(io);
        proc.alloc.free(dup);
        return;
    };
    proc.q_mutex.unlock(io);
}

fn stderrReader(ctx: ManagedProc.StderrCtx) void {
    const proc = ctx.proc;
    var f: ?std.Io.File = null;
    {
        proc.mutex.lock(ctx.io) catch return;
        if (proc.child) |*ch| f = ch.stderr;
        proc.mutex.unlock(ctx.io);
    }
    if (f == null) return;
    var scratch: [4096]u8 = undefined;
    var r = f.?.readerStreaming(ctx.io, &scratch);
    var dest: [1024]u8 = undefined;
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(proc.alloc);
    while (true) {
        const amt = r.interface.readSliceShort(dest[0..]) catch break;
        if (amt == 0) break;
        var i: usize = 0;
        while (i < amt) {
            const nl = std.mem.indexOfScalarPos(u8, dest[0..amt], i, '\n') orelse {
                pending.appendSlice(proc.alloc, dest[i..amt]) catch {};
                i = amt;
                break;
            };
            pending.appendSlice(proc.alloc, dest[i..nl]) catch {};
            enqueueLine(proc, ctx.io, pending.items);
            pending.clearRetainingCapacity();
            i = nl + 1;
        }
    }
    if (pending.items.len > 0) enqueueLine(proc, ctx.io, pending.items);
}

// ---------- short-lived command ----------

const CmdResult = struct {
    ok: bool,
    stdout: []u8,
    stderr: []u8,
};

fn runCommand(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) CmdResult {
    const res = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = std.Io.Limit.limited(16 * 1024),
        .stderr_limit = std.Io.Limit.limited(16 * 1024),
    }) catch return .{ .ok = false, .stdout = &.{}, .stderr = &.{} };
    return .{
        .ok = res.term == .exited and res.term.exited == 0,
        .stdout = res.stdout,
        .stderr = res.stderr,
    };
}

/// Roda um comando e descarta a saída, liberando os buffers. Retorna true se
/// o processo saiu com status 0. Usado por threads de fundo (dev check e
/// reparo) para não acumular stdout/stderr alocados.
fn runCommandOk(app: *App, argv: []const []const u8) bool {
    const res = std.process.run(app.gpa, app.io, .{
        .argv = argv,
        .stdout_limit = std.Io.Limit.limited(16 * 1024),
        .stderr_limit = std.Io.Limit.limited(16 * 1024),
    }) catch return false;
    defer app.gpa.free(res.stdout);
    defer app.gpa.free(res.stderr);
    return res.term == .exited and res.term.exited == 0;
}

// Posta uma mensagem formatada a partir de uma thread de fundo (mutex protege
// contra a UI thread). Drenada no main loop por drainAsyncMsg().
fn postAsyncFmt(app: *App, comptime key: []const u8, args: anytype) void {
    const template = i18n.t(key);
    var buf: [256]u8 = undefined;
    const s = i18n.formatInto(&buf, template, args);
    app.async_msg_mutex.lock(app.io) catch return;
    defer app.async_msg_mutex.unlock(app.io);
    app.async_msg_len = @min(s.len, app.async_msg_buf.len);
    @memcpy(app.async_msg_buf[0..app.async_msg_len], s[0..app.async_msg_len]);
    app.async_msg_ready = true;
}

fn drainAsyncMsg(app: *App) void {
    app.async_msg_mutex.lock(app.io) catch return;
    defer app.async_msg_mutex.unlock(app.io);
    if (!app.async_msg_ready) return;
    app.async_msg_ready = false;
    app.msg_len = @min(app.async_msg_len, app.msg_buf.len);
    @memcpy(app.msg_buf[0..app.msg_len], app.async_msg_buf[0..app.msg_len]);
}

/// Localiza o bridge_ctl.bat (scripts) para controlar o bridge no modo WSL.
/// Ordem: dirname(exe)/scripts/bridge_ctl.bat (instalado) →
///        dirname(exe)/../scripts/bridge_ctl.bat (bin/../scripts) →
///        dirname(exe)/../../scripts/bridge_ctl.bat (zig-out/bin) →
///        cwd/scripts/bridge_ctl.bat (dev) →
///        cwd/bridge_ctl.bat (fallback). Retorna o comprimento em `out`.
fn resolveBridgeCtl(gpa: std.mem.Allocator, io: std.Io, out: *[512]u8) usize {
    const sep = std.fs.path.sep;
    if (std.process.executablePathAlloc(io, gpa)) |exe| {
        defer gpa.free(exe);
        if (std.fs.path.dirname(exe)) |exe_dir| {
            const p = std.fmt.bufPrint(out, "{s}{c}scripts{c}bridge_ctl.bat", .{ exe_dir, sep, sep }) catch out[0..0];
            if (p.len > 0 and fileExists(io, p)) return p.len;
        }
        if (std.fs.path.dirname(exe)) |exe_dir| {
            const p = std.fmt.bufPrint(out, "{s}{c}..{c}scripts{c}bridge_ctl.bat", .{ exe_dir, sep, sep, sep }) catch out[0..0];
            if (p.len > 0 and fileExists(io, p)) return p.len;
        }
        if (std.fs.path.dirname(exe)) |exe_dir| {
            const p = std.fmt.bufPrint(out, "{s}{c}..{c}..{c}scripts{c}bridge_ctl.bat", .{ exe_dir, sep, sep, sep, sep }) catch out[0..0];
            if (p.len > 0 and fileExists(io, p)) return p.len;
        }
    } else |_| {}
    {
        const p = std.fmt.bufPrint(out, ".{c}scripts{c}bridge_ctl.bat", .{ sep, sep }) catch out[0..0];
        if (p.len > 0 and fileExists(io, p)) return p.len;
    }
    {
        const p = std.fmt.bufPrint(out, ".{c}bridge_ctl.bat", .{sep}) catch out[0..0];
        if (p.len > 0 and fileExists(io, p)) return p.len;
    }
    out[0] = 0;
    return 0;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

// ---------- network helpers (Zig 0.16: std.Io.net) ----------

fn portIsOpen(io: std.Io, host: []const u8, port: u16) bool {
    var addr_buf: [128]u8 = undefined;
    const addr_str = std.fmt.bufPrint(&addr_buf, "{s}:{d}", .{ host, port }) catch return false;
    const address = std.Io.net.IpAddress.parseLiteral(addr_str) catch return false;
    var stream = address.connect(io, .{ .mode = .stream }) catch return false;
    stream.close(io);
    return true;
}

fn findFreePort(io: std.Io, start: u16) u16 {
    var port = start;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        if (!portIsOpen(io, "127.0.0.1", port)) return port;
        port +%= 1;
    }
    return start;
}

// ---------- app state ----------

const ScanEntry = struct {
    time: []u8,
    code: []u8,
};

/// Resultado do diálogo de confirmação de encerramento.
const ConfirmResult = enum(u8) {
    none,
    yes,
    cancel,
};

const LogLine = struct {
    line: []u8,
};

const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    cfg: Config,

    bridge: ManagedProc = .{},
    client: ManagedProc = .{},

    bridge_port: u16,
    bridge_is_ours: bool,
    started_this_session: bool,

    log_open: bool = false,
    log_lines: std.ArrayList(LogLine),
    scans: std.ArrayList(ScanEntry),

    host_buf: [64]u8,
    port_buf: [8]u8,

    msg_buf: [256]u8 = undefined,
    msg_len: usize = 0,

    status_at: i128 = 0,
    status_buf: [256]u8 = undefined,
    status_len: usize = 0,

    last_scan_time_ns: i128 = 0,
    watchdog_state: u8 = 0,
    usb_warned: bool = false,

    // Operações do bridge_ctl rodam em thread (wsl.exe spawn síncrono
    // congelava a UI). Resultado volta via async_msg (mutex + buffer).
    wsl_op_busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    dev_check_inflight: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    dev_ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    dev_checked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    repair_busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    async_msg_mutex: std.Io.Mutex = .init,
    async_msg_buf: [256]u8 = undefined,
    async_msg_len: usize = 0,
    async_msg_ready: bool = false,

    bridge_ctl_buf: [512]u8 = undefined,
    bridge_ctl_len: usize = 0,

    quit_confirm_open: bool = false,
    quit_confirm_result: ConfirmResult = .none,
    locale: i18n.Locale = .us,

    fn init(gpa: std.mem.Allocator, io: std.Io) App {
        const path = paths.joinPath(gpa, gui_cfg_dir.path, CONFIG_FILE) orelse (gpa.dupe(u8, CONFIG_FILE) catch CONFIG_FILE);
        var cfg = loadConfig(gpa, io, path);
        const locale = i18n.Locale.fromString(cfg.lang);
        i18n.setLocale(locale);

        // Reconciliacao no Linux: se o server_mode lido do conf nao bate com
        // o unit que esta realmente rodando, ajustamos. Isso evita a
        // inconsistencia documentada no .checkpoint.md onde rodar
        // run_xemonitor.sh (user unit) e depois o install (system unit)
        // deixa o GUI falando com o unit errado.
        if (os == .linux and !std.mem.eql(u8, cfg.server_mode, "subprocess")) {
            const detected = detectActiveServerMode(gpa, io);
            if (!std.mem.eql(u8, detected, cfg.server_mode)) {
                std.debug.print("[gui] server_mode: conf='{s}' detectado='{s}' -> usando '{s}'\n", .{ cfg.server_mode, detected, detected });
                gpa.free(cfg.server_mode);
                cfg.server_mode = gpa.dupe(u8, detected) catch cfg.server_mode;
            }
        }

        var host_buf = [_]u8{0} ** 64;
        const hn = @min(cfg.tcp_host.len, host_buf.len - 1);
        @memcpy(host_buf[0..hn], cfg.tcp_host[0..hn]);
        host_buf[hn] = 0;

        var port_buf = [_]u8{0} ** 8;
        if (std.fmt.bufPrint(&port_buf, "{d}", .{cfg.tcp_port})) |p| {
            port_buf[p.len] = 0;
        } else |_| {}

        var bridge_ctl_buf = [_]u8{0} ** 512;
        const bridge_ctl_len = resolveBridgeCtl(gpa, io, &bridge_ctl_buf);

        return .{
            .gpa = gpa,
            .io = io,
            .config_path = path,
            .cfg = cfg,
            .bridge_port = cfg.tcp_port,
            .bridge_is_ours = false,
            .started_this_session = false,
            .log_lines = .empty,
            .scans = .empty,
            .host_buf = host_buf,
            .port_buf = port_buf,
            .locale = locale,
            .bridge_ctl_buf = bridge_ctl_buf,
            .bridge_ctl_len = bridge_ctl_len,
        };
    }

    fn deinit(self: *App) void {
        stopBridge(self);
        stopClient(self);
        for (self.log_lines.items) |ll| self.gpa.free(ll.line);
        self.log_lines.deinit(self.gpa);
        for (self.scans.items) |s| {
            self.gpa.free(s.time);
            self.gpa.free(s.code);
        }
        self.scans.deinit(self.gpa);
        self.gpa.free(self.config_path);
        self.gpa.free(self.cfg.tcp_host);
        self.gpa.free(self.cfg.server_mode);
        self.gpa.free(self.cfg.bridge_path);
        self.gpa.free(self.cfg.client_path);
        self.gpa.free(self.cfg.log_path);
        self.gpa.free(self.cfg.lang);
    }

    fn nowNs(self: *App) i128 {
        return std.Io.Timestamp.now(self.io, .real).nanoseconds;
    }

    fn setMsg(self: *App, comptime key: []const u8, args: anytype) void {
        const template = i18n.t(key);
        const s = i18n.formatInto(&self.msg_buf, template, args);
        if (s.len == 0) {
            const fallback = i18n.t("msg_fmt_error");
            if (fallback.len > self.msg_buf.len) return;
            @memcpy(self.msg_buf[0..fallback.len], fallback);
            self.msg_len = fallback.len;
            return;
        }
        self.msg_len = s.len;
    }

    fn setCfgHostPort(self: *App) void {
        const host_len = std.mem.indexOfScalar(u8, &self.host_buf, 0) orelse self.host_buf.len;
        const host = self.host_buf[0..host_len];
        self.gpa.free(self.cfg.tcp_host);
        self.cfg.tcp_host = self.gpa.dupe(u8, host) catch return;
        const port_len = std.mem.indexOfScalar(u8, &self.port_buf, 0) orelse self.port_buf.len;
        if (std.fmt.parseInt(u16, self.port_buf[0..port_len], 10)) |p| {
            self.cfg.tcp_port = p;
        } else |_| {}
        saveConfig(self.gpa, self.io, self.config_path, &self.cfg);
    }
};

fn scansLimit() usize {
    return 200;
}
fn logLinesLimit() usize {
    return 500;
}

fn pushScan(app: *App, code: []const u8) void {
    app.last_scan_time_ns = app.nowNs();
    const now_secs: u64 = @intCast(@divTrunc(app.nowNs(), ns_per_s));
    const es = std.time.epoch.EpochSeconds{ .secs = now_secs };
    const ds = es.getDaySeconds();
    var tbuf: [32]u8 = undefined;
    const tstr = std.fmt.bufPrint(
        &tbuf,
        "{d:0>2}:{d:0>2}:{d:0>2}",
        .{ ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() },
    ) catch "00:00:00";
    const tdup = app.gpa.dupe(u8, tstr) catch return;
    const cdup = app.gpa.dupe(u8, code) catch return;
    app.scans.append(app.gpa, .{ .time = tdup, .code = cdup }) catch return;
    while (app.scans.items.len > scansLimit()) {
        const old = app.scans.orderedRemove(0);
        app.gpa.free(old.time);
        app.gpa.free(old.code);
    }
}

fn devCheckWorker(app: *App) void {
    defer app.dev_check_inflight.store(false, .seq_cst);
    const ok = runBridgeCtlOk(app, "dev");
    app.dev_ok.store(ok, .seq_cst);
    app.dev_checked.store(true, .seq_cst);
}

// Watchdog leve (roda a cada ~5s no main loop): detecta o caso "cliente
// conectado mas sem scans ha muito tempo" e avisa na barra de status. Usa
// apenas estado em memoria (nao spawna processos).
fn watchdogTick(app: *App) void {
    const client_running = app.client.running.load(.seq_cst);

    // Aviso do scanner USB-Serial (CH340): no modo WSL, verifica se o
    // /dev/ttyUSB0 existe no WSL. Sem scanner conectado, nada funciona —
    // feedback claro para o usuario (fio a fio com o setup_usb.bat).
    // O check do device roda em thread (wsl.exe spawn síncrono no main
    // loop congelava a UI); o resultado chega via atomics.
    if (client_running and isMode(app, "wsl") and os == .windows) {
        if (!app.dev_check_inflight.load(.seq_cst)) {
            app.dev_check_inflight.store(true, .seq_cst);
            const t = std.Thread.spawn(.{}, devCheckWorker, .{app}) catch |err| {
                app.dev_check_inflight.store(false, .seq_cst);
                postAsyncFmt(app, "msg_client_start_failed", .{@errorName(err)});
                return;
            };
            t.detach();
        }
        if (app.dev_checked.load(.seq_cst)) {
            const dev_ok = app.dev_ok.load(.seq_cst);
            if (!dev_ok and !app.usb_warned) {
                app.usb_warned = true;
                app.setMsg("msg_usb_serial_missing", .{});
            } else if (dev_ok and app.usb_warned) {
                app.usb_warned = false;
                app.setMsg("msg_usb_serial_found", .{});
            }
        }
    }

    const silent_ns: i128 = if (app.last_scan_time_ns > 0)
        app.nowNs() - app.last_scan_time_ns
    else
        0;
    const silent_secs: i128 = if (silent_ns > 0) @divTrunc(silent_ns, ns_per_s) else 0;

    if (client_running and silent_ns > 0 and silent_secs >= 30) {
        if (app.watchdog_state == 0) {
            app.watchdog_state = 1;
            app.setMsg("msg_no_scans_warn", .{silent_secs});
        }
    } else if (silent_ns == 0 or silent_secs < 30) {
        app.watchdog_state = 0;
    }
}

fn pushLogLine(app: *App, line: []const u8) void {
    const dup = app.gpa.dupe(u8, line) catch return;
    app.log_lines.append(app.gpa, .{ .line = dup }) catch return;
    while (app.log_lines.items.len > logLinesLimit()) {
        const old = app.log_lines.orderedRemove(0);
        app.gpa.free(old.line);
    }
}

fn extractScan(line: []const u8) ?[]const u8 {
    const q0 = std.mem.indexOfScalar(u8, line, '\'') orelse return null;
    const q1 = std.mem.indexOfScalarPos(u8, line, q0 + 1, '\'') orelse return null;
    return line[q0 + 1 .. q1];
}

fn drainClientLines(app: *App) void {
    const proc = &app.client;
    proc.q_mutex.lock(app.io) catch return;
    var drained = proc.line_q;
    proc.line_q = .empty;
    proc.q_mutex.unlock(app.io);
    for (drained.items) |line| {
        pushLogLine(app, line);
        if (std.mem.indexOf(u8, line, "[scan]") != null) {
            if (extractScan(line)) |code| pushScan(app, code);
        }
        app.gpa.free(line);
    }
    drained.deinit(app.gpa);
}

/// Data de hoje em "YYYY-MM-DD" (usada para o arquivo de log datado).
fn todayDateStr(io: std.Io, buf: *[10]u8) []const u8 {
    const now_ns = std.Io.Timestamp.now(io, .real).nanoseconds;
    const secs: u64 = @intCast(@divTrunc(now_ns, ns_per_s));
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, @intCast(year_day.year)),
        @as(u32, @intCast(month_day.month.numeric())),
        @as(u32, @intCast(month_day.day_index + 1)),
    }) catch buf[0..0];
}

fn readFileOrNull(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, std.Io.Limit.limited(8 * 1024 * 1024)) catch return null;
}

fn backfillLog(app: *App) void {
    var buf: [1024]u8 = undefined;
    const is_abs = app.cfg.log_path.len > 0 and (app.cfg.log_path[0] == '/' or
        (app.cfg.log_path.len > 1 and app.cfg.log_path[1] == ':'));
    const base_path = if (is_abs) app.cfg.log_path
    else std.fmt.bufPrint(&buf, "{s}{c}{s}", .{
        gui_cfg_dir.path,
        paths.sep,
        if (app.cfg.log_path.len > 0) app.cfg.log_path else DEFAULT_LOG,
    }) catch DEFAULT_LOG;

    // Log atual é datado (xemonitor-YYYY-MM-DD.log); usa o legado como fallback.
    var date_buf: [10]u8 = undefined;
    const date = todayDateStr(app.io, &date_buf);
    var dated_buf: [1024]u8 = undefined;
    const last_sep = std.mem.lastIndexOfAny(u8, base_path, "/\\");
    const dir = if (last_sep) |i| base_path[0 .. i + 1] else "";
    const dated_path = std.fmt.bufPrint(&dated_buf, "{s}{s}{s}.log", .{ dir, paths.LOG_PREFIX, date }) catch base_path;
    const data = readFileOrNull(app.io, app.gpa, dated_path) orelse
        readFileOrNull(app.io, app.gpa, base_path) orelse return;
    defer app.gpa.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        pushLogLine(app, line);
        if (std.mem.indexOf(u8, line, "[scan]") != null) {
            if (extractScan(line)) |code| pushScan(app, code);
        }
    }
}

// ---------- process control ----------

fn isMode(app: *App, mode: []const u8) bool {
    return std.mem.eql(u8, app.cfg.server_mode, mode);
}

fn runSystemdStatus(app: *App, scope: []const u8) bool {
    const argv: []const []const u8 = if (scope.len > 0)
        &.{ "systemctl", "--user", "is-active", "xemonitor-bridge" }
    else
        &.{ "systemctl", "is-active", "xemonitor-bridge" };
    return runCommand(app.gpa, app.io, argv).ok;
}

fn runWslStatus(app: *App) bool {
    return runBridgeCtl(app, "status").ok;
}

// Detecta um askpass disponível (programa que mostra prompt de senha e
// devolve via stdout). Ordem de preferência: ksshaskpass (KDE) > zenity
// (GTK) > yad > gnome-passwd > terminal (xterm/konsole/gnome-terminal)
// rodando `sudo -v` num subshell. Retorna null se nenhum disponível.
//
// SUDO_ASKPASS: se o binário existir, `sudo -A` o invoca passando o prompt
// como argv[1]; o askpass escreve a senha em stdout; sudo consome.
// Ref: https://man.archlinux.org/man/sudo.8#SUDO_ASKPASS
fn findAskpass(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    const candidates = [_][]const u8{
        "ksshaskpass", "zenity", "yad", "gnome-passwd",
    };
    for (candidates) |name| {
        const probe = std.fmt.allocPrint(gpa, "command -v {s} >/dev/null 2>&1", .{name}) catch continue;
        const res = runCommand(gpa, io, &.{ "bash", "-c", probe });
        gpa.free(probe);
        if (res.ok) {
            // Resolve o path completo via `which`.
            const which_res = runCommand(gpa, io, &.{ "which", name });
            defer gpa.free(which_res.stdout);
            defer gpa.free(which_res.stderr);
            if (which_res.ok and which_res.stdout.len > 0) {
                const trimmed = std.mem.trim(u8, which_res.stdout, " \t\r\n");
                if (trimmed.len > 0) return gpa.dupe(u8, trimmed) catch null;
            }
            return gpa.dupe(u8, name) catch null;
        }
    }
    // Terminal-based fallback: abrir konsole/xterm/gnome-terminal rodando sudo -v.
    const terminals = [_][]const u8{ "konsole", "xterm", "gnome-terminal", "alacritty", "foot" };
    for (terminals) |name| {
        const probe = std.fmt.allocPrint(gpa, "command -v {s} >/dev/null 2>&1", .{name}) catch continue;
        const res = runCommand(gpa, io, &.{ "bash", "-c", probe });
        gpa.free(probe);
        if (res.ok) return gpa.dupe(u8, name) catch null;
    }
    return null;
}

// Executa um comando com privilegios de root via askpass (sem depender de
// polkit/pkexec). Ordem:
//   1) SUDO_ASKPASS=<askpass> sudo -A <argv>  (sem prompt, askpass grafico)
//   2) konsole/xterm/gnome-terminal -e "sudo <argv>"  (terminal spawned)
//   3) mensagem de instrucao + return ok=false
fn runPrivileged(app: *App, argv: []const []const u8) CmdResult {
    const gpa = app.gpa;
    const io = app.io;

    if (findAskpass(gpa, io)) |askpass| {
        defer gpa.free(askpass);

        // Tenta detectar se o askpass e grafico (nao-terminal) ou terminal.
        const is_terminal_askpass =
            std.mem.eql(u8, std.fs.path.basename(askpass), "konsole") or
            std.mem.eql(u8, std.fs.path.basename(askpass), "xterm") or
            std.mem.eql(u8, std.fs.path.basename(askpass), "gnome-terminal") or
            std.mem.eql(u8, std.fs.path.basename(askpass), "alacritty") or
            std.mem.eql(u8, std.fs.path.basename(askpass), "foot");

        if (!is_terminal_askpass) {
            // SUDO_ASKPASS: askpass grafico; sudo -A nao mostra prompt no TTY.
            // Passamos o env via `env SUDO_ASKPASS=...` (POSIX).
            const joined_cmd = std.mem.join(gpa, " ", argv) catch return .{ .ok = false, .stdout = &.{}, .stderr = &.{} };
            defer gpa.free(joined_cmd);
            const shell_cmd = std.fmt.allocPrint(gpa, "SUDO_ASKPASS='{s}' sudo -A {s}", .{ askpass, joined_cmd }) catch return .{ .ok = false, .stdout = &.{}, .stderr = &.{} };
            defer gpa.free(shell_cmd);
            const res = runCommand(gpa, io, &.{ "bash", "-c", shell_cmd });
            if (res.ok) return res;
            return res;
        }

        // Terminal spawned: sudo direto (sem -A); o terminal mostra o prompt.
        const joined = std.mem.join(gpa, " ", argv) catch return .{ .ok = false, .stdout = &.{}, .stderr = &.{} };
        defer gpa.free(joined);
        const cmd = std.fmt.allocPrint(gpa, "sudo {s}", .{joined}) catch return .{ .ok = false, .stdout = &.{}, .stderr = &.{} };
        defer gpa.free(cmd);
        // Spawna o terminal e nao bloqueia (nowait pattern via thread).
        _ = runCommand(gpa, io, &.{ askpass, "-e", "bash", "-c", cmd });
        // Consideramos ok=true (o terminal vai lidar); o caller vai validar
        // com portIsOpen / systemctl is-active depois.
        return .{ .ok = true, .stdout = &.{}, .stderr = &.{} };
    }

    // Nenhum askpass: instrui o usuario a rodar sudo manualmente.
    const joined = std.mem.join(gpa, " ", argv) catch return .{ .ok = false, .stdout = &.{}, .stderr = &.{} };
    defer gpa.free(joined);
    const line = std.fmt.allocPrint(gpa, "{s} ; echo ; echo '{s}' ; read", .{ joined, i18n.t("press_enter") }) catch return .{ .ok = false, .stdout = &.{}, .stderr = &.{} };
    defer gpa.free(line);
    _ = runCommand(gpa, io, &.{ "konsole", "--hide-menubar", "--hide-tabbar", "--geometry=560x220", "-e", "bash", "-c", line });
    return .{ .ok = false, .stdout = &.{}, .stderr = &.{} };
}

fn systemdAction(app: *App, scope: []const u8, action: []const u8) void {
    const is_user = scope.len > 0;
    if (!is_user and runSystemdStatus(app, "")) {
        // Servico de sistema ja esta no estado desejado (start com ativo /
        // stop com parado) — evita prompt pkexec desnecessario.
        if (std.mem.eql(u8, action, "start")) {
            app.setMsg("msg_bridge_active", .{});
            return;
        }
    }
    const argv: []const []const u8 = if (is_user)
        &.{ "systemctl", "--user", action, "xemonitor-bridge" }
    else
        &.{ "systemctl", action, "xemonitor-bridge" };
    const res = if (is_user) runCommand(app.gpa, app.io, argv) else runPrivileged(app, argv);
    if (res.ok) {
        app.setMsg("msg_bridge_ok", .{action});
    } else {
        app.setMsg("msg_bridge_failed", .{ action, @as([]const u8, res.stderr) });
    }
}

const WslCtx = struct {
    app: *App,
    action: []const u8,
};

fn wslAction(app: *App, action: []const u8) void {
    if (os != .windows) {
        const res = runBridgeCtl(app, action);
        if (res.ok) {
            app.setMsg("msg_wsl_ok", .{action});
        } else {
            app.setMsg("msg_wsl_failed", .{action});
        }
        return;
    }
    if (app.wsl_op_busy.load(.seq_cst)) return;
    app.wsl_op_busy.store(true, .seq_cst);
    const t = std.Thread.spawn(.{}, wslActionWorker, .{ WslCtx{ .app = app, .action = action } }) catch {
        app.wsl_op_busy.store(false, .seq_cst);
        return;
    };
    t.detach();
}

fn wslActionWorker(ctx: WslCtx) void {
    defer ctx.app.wsl_op_busy.store(false, .seq_cst);
    const res = runBridgeCtl(ctx.app, ctx.action);
    if (res.ok) {
        postAsyncFmt(ctx.app, "msg_wsl_ok", .{ctx.action});
    } else {
        postAsyncFmt(ctx.app, "msg_wsl_failed", .{ctx.action});
    }
    ctx.app.gpa.free(res.stdout);
    ctx.app.gpa.free(res.stderr);
}

/// Roda o bridge_ctl.bat no Windows (controla o serviço do bridge no WSL,
/// detectando OpenRC/systemd). Em outros SO retorna falha.
fn runBridgeCtl(app: *App, action: []const u8) CmdResult {
    if (app.bridge_ctl_len == 0) return .{ .ok = false, .stdout = &.{}, .stderr = &.{} };
    const ctl = app.bridge_ctl_buf[0..app.bridge_ctl_len];
    return runCommand(app.gpa, app.io, &.{ "cmd", "/c", ctl, action });
}

/// Variante que descarta a saída e libera os buffers (para threads de fundo).
fn runBridgeCtlOk(app: *App, action: []const u8) bool {
    if (app.bridge_ctl_len == 0) return false;
    const ctl = app.bridge_ctl_buf[0..app.bridge_ctl_len];
    return runCommandOk(app, &.{ "cmd", "/c", ctl, action });
}

fn startBridge(app: *App) void {
    if (isMode(app, "subprocess")) {
        app.bridge_port = findFreePort(app.io, app.cfg.tcp_port);
        const port_str = std.fmt.allocPrint(app.gpa, "{d}", .{app.bridge_port}) catch {
            app.setMsg("msg_fmt_port_failed", .{});
            return;
        };
        defer app.gpa.free(port_str);
        const argv: []const []const u8 = if (app.cfg.bridge_path.len > 0)
            &.{ app.cfg.bridge_path, "--tcp-port", port_str }
        else
            &.{ "xemonitor-bridge", "--tcp-port", port_str };
        app.bridge.start(app.io, argv) catch |err| {
            app.setMsg("msg_bridge_start_failed", .{@errorName(err)});
            return;
        };
        app.bridge_is_ours = true;
        app.started_this_session = true;
        app.setMsg("msg_bridge_subprocess_started", .{app.bridge_port});
    } else if (isMode(app, "systemd-user")) {
        systemdAction(app, "--user", "start");
    } else if (isMode(app, "systemd-system")) {
        systemdAction(app, "", "start");
    } else if (isMode(app, "wsl")) {
        wslAction(app, "start");
    } else {
        app.setMsg("msg_mode_unknown", .{app.cfg.server_mode});
    }
}

fn stopBridge(app: *App) void {
    if (isMode(app, "subprocess")) {
        app.bridge.stop(app.io);
        app.bridge_is_ours = false;
        app.setMsg("msg_bridge_subprocess_stopped", .{});
    } else if (isMode(app, "systemd-user")) {
        systemdAction(app, "--user", "stop");
    } else if (isMode(app, "systemd-system")) {
        systemdAction(app, "", "stop");
    } else if (isMode(app, "wsl")) {
        wslAction(app, "stop");
    } else {
        app.setMsg("msg_mode_unknown", .{app.cfg.server_mode});
    }
}

fn startRepair(app: *App) void {
    if (app.repair_busy.load(.seq_cst)) return;
    if (app.dev_check_inflight.load(.seq_cst)) return;
    app.repair_busy.store(true, .seq_cst);
    const t = std.Thread.spawn(.{}, repairWorker, .{app}) catch {
        app.repair_busy.store(false, .seq_cst);
        return;
    };
    t.detach();
}

/// Sequência "Reparar" (roda em thread, evita congelar a UI):
/// 1. para o bridge (libera o /dev/ttyUSB0 no WSL);
/// 2. reattach do CH340 via tarefa agendada elevada (sem popup UAC);
/// 3. garante o driver ch341 carregado (bridge_ctl ch341: modprobe + test);
/// 4. espera o /dev/ttyUSB0 voltar (poll de ~15s);
/// 5. reinicia o bridge;
/// 6. mata cliente órfão e relança o cliente.
fn repairWorker(app: *App) void {
    defer app.repair_busy.store(false, .seq_cst);
    postAsyncFmt(app, "msg_repair_start", .{});

    _ = runBridgeCtlOk(app, "stop");

    // Tarefa XeMonitor-USB-Attach roda com RL HIGHEST (autoeleva) e faz o
    // usbipd attach do CH340 ao WSL. Sem popup UAC para o usuário.
    _ = runCommandOk(app, &.{ "schtasks", "/Run", "/TN", "XeMonitor-USB-Attach" });

    // O driver ch341 NAO auto-carrega no Alpine; sem ele /dev/ttyUSB0 nao
    // aparece apos o attach. bridge_ctl ch341 faz modprobe (idempotente) + test.
    _ = runBridgeCtlOk(app, "ch341");

    // Poll do /dev/ttyUSB0 (bridge_ctl dev) até ~15s.
    var dev_ok = false;
    var waited: u8 = 0;
    while (waited < 15) : (waited += 1) {
        std.Io.sleep(app.io, std.Io.Duration.fromMilliseconds(1000), .awake) catch break;
        if (runBridgeCtlOk(app, "dev")) {
            dev_ok = true;
            break;
        }
    }
    if (!dev_ok) {
        postAsyncFmt(app, "msg_repair_usb_failed", .{});
        return;
    }
    postAsyncFmt(app, "msg_repair_usb_ok", .{});

    if (!runBridgeCtlOk(app, "restart")) {
        postAsyncFmt(app, "msg_repair_bridge_failed", .{});
        return;
    }
    postAsyncFmt(app, "msg_repair_bridge_ok", .{});

    // Mata cliente órfão (Windows usa taskkill /F /IM; instância única é
    // garantida por CreateMutexA "Global\XeMonitor" no cliente).
    if (os == .windows) {
        _ = runCommandOk(app, &.{ "taskkill", "/F", "/IM", "xemonitor.exe" });
    }
    if (spawnClient(app)) |addr| {
        defer app.gpa.free(addr);
        postAsyncFmt(app, "msg_repair_done", .{addr});
    } else |err| {
        postAsyncFmt(app, "msg_client_start_failed", .{@errorName(err)});
    }
}

fn computeBridgeStatus(app: *App) []const u8 {
    if (isMode(app, "subprocess")) {
        if (app.bridge.running.load(.seq_cst)) {
            return i18n.formatInto(&app.status_buf, i18n.t("status_subprocess"), .{app.bridge_port});
        }
        return i18n.t("status_stopped");
    }
    if (isMode(app, "systemd-user") and os == .linux) {
        return if (runSystemdStatus(app, "--user")) i18n.t("status_systemd_user_running") else i18n.t("status_systemd_user_stopped");
    }
    if (isMode(app, "systemd-system") and os == .linux) {
        return if (runSystemdStatus(app, "")) i18n.t("status_systemd_running") else i18n.t("status_systemd_stopped");
    }
    if (isMode(app, "wsl") and os == .windows) {
        // Checa a porta TCP 9000 do bridge (rápido, sem spawn de wsl.exe).
        // O spawn síncrono a cada 1s era a causa do Application Hang.
        return if (portIsOpen(app.io, "127.0.0.1", app.cfg.tcp_port)) i18n.t("status_wsl_running") else i18n.t("status_wsl_stopped");
    }
    return i18n.t("status_mode_unknown");
}

fn refreshStatus(app: *App) void {
    const now = std.Io.Timestamp.now(app.io, .awake).nanoseconds;
    if (now - app.status_at < std.time.ns_per_ms * 1000) return;
    app.status_at = now;
    const s = computeBridgeStatus(app);
    app.status_len = @min(s.len, app.status_buf.len - 1);
    // computeBridgeStatus pode gravar direto em status_buf (modo subprocesso);
    // nesse caso o conteudo ja esta no buffer e o memcpy seria um alias.
    if (s.len > 0 and @intFromPtr(s.ptr) == @intFromPtr(&app.status_buf)) return;
    @memcpy(app.status_buf[0..app.status_len], s[0..app.status_len]);
}

fn killStaleClient(app: *App) void {
    if (os != .linux) return;
    // -x: casa apenas o processo do cliente (comm "xemonitor"), sem atingir
    // o proprio GUI ("xemonitor-gui") nem o bridge ("xemonitor-bridge").
    const res = runCommand(app.gpa, app.io, &.{ "pkill", "-9", "-x", "xemonitor" });
    if (res.ok) app.setMsg("msg_old_client_killed", .{});
    std.Io.Dir.cwd().deleteFile(app.io, "xemonitor.pid") catch {};
}

/// Resolve o caminho do cliente e o endereço TCP, e sobe o processo.
/// Retorna o endereço alocado (caller libera com gpa.free). Usado pela UI
/// (setMsg) e pelas threads de reparo (postAsyncFmt).
fn spawnClient(app: *App) ![]const u8 {
    killStaleClient(app);
    const port: u16 = if (app.bridge_is_ours and app.bridge.running.load(.seq_cst)) app.bridge_port else app.cfg.tcp_port;
    const addr = try std.fmt.allocPrint(app.gpa, "{s}:{d}", .{ app.cfg.tcp_host, port });
    errdefer app.gpa.free(addr);
    var sibling_buf: [512]u8 = undefined;
    const client = if (app.cfg.client_path.len > 0)
        app.cfg.client_path
    else if (comptime os == .windows)
        (resolveSibling(gpaOf(app), app.io, "xemonitor.exe", &sibling_buf) orelse "xemonitor")
    else
        "xemonitor";
    const argv: []const []const u8 = &.{ client, "--tcp", addr };
    app.client.start(app.io, argv) catch |err| {
        return err;
    };
    return addr;
}

fn startClient(app: *App) void {
    const addr = spawnClient(app) catch |err| {
        app.setMsg("msg_client_start_failed", .{@errorName(err)});
        return;
    };
    defer app.gpa.free(addr);
    app.setMsg("msg_client_connecting", .{addr});
}

fn gpaOf(app: *App) std.mem.Allocator {
    return app.gpa;
}

/// Localiza `name` no diretório do executável (binário irmão). Retorna slice
/// para `out` ou null. Usado no Windows para achar xemonitor.exe ao lado do
/// xemonitor-gui.exe.
fn resolveSibling(gpa: std.mem.Allocator, io: std.Io, name: []const u8, out: *[512]u8) ?[]const u8 {
    const exe = std.process.executablePathAlloc(io, gpa) catch return null;
    defer gpa.free(exe);
    const exe_dir = std.fs.path.dirname(exe) orelse return null;
    const sep = std.fs.path.sep;
    const p = std.fmt.bufPrint(out, "{s}{c}{s}", .{ exe_dir, sep, name }) catch return null;
    if (fileExists(io, p)) return p;
    return null;
}

fn stopClient(app: *App) void {
    app.client.stop(app.io);
    app.setMsg("msg_client_stopped", .{});
}

// ---------- UI ----------

fn renderServerPanel(app: *App) void {
    dvui.labelNoFmt(@src(), i18n.t("panel_server"), .{}, .{ .font = .theme(.heading) });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 4, .h = 4 } });
    defer row.deinit();
    dvui.labelNoFmt(@src(), i18n.t("label_status"), .{}, .{});
    dvui.labelNoFmt(@src(), app.status_buf[0..app.status_len], .{}, .{});

    var row2 = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row2.deinit();
    if (dvui.button(@src(), i18n.t("btn_start"), .{}, .{})) startBridge(app);
    if (dvui.button(@src(), i18n.t("btn_stop"), .{}, .{})) stopBridge(app);
    if (isMode(app, "wsl") and os == .windows) {
        dvui.labelNoFmt(@src(), "  ", .{}, .{});
        const repairing = app.repair_busy.load(.seq_cst);
        const repair_color: ?dvui.Color = if (repairing) .gray else null;
        if (dvui.button(@src(), i18n.t("btn_repair"), .{}, .{ .color_text = repair_color })) {
            if (!repairing) startRepair(app);
        }
    }
    dvui.labelNoFmt(@src(), i18n.t("label_mode"), .{}, .{});
    dvui.labelNoFmt(@src(), app.cfg.server_mode, .{}, .{});
    dvui.labelNoFmt(@src(), i18n.t("label_port_cfg"), .{}, .{});
    dvui.labelNoFmt(@src(), app.port_buf[0..portBufLen(app)], .{}, .{});
}

fn portBufLen(app: *App) usize {
    return std.mem.indexOfScalar(u8, &app.port_buf, 0) orelse app.port_buf.len;
}

fn hostBufLen(app: *App) usize {
    return std.mem.indexOfScalar(u8, &app.host_buf, 0) orelse app.host_buf.len;
}

fn renderClientPanel(app: *App) void {
    dvui.labelNoFmt(@src(), i18n.t("panel_client"), .{}, .{ .font = .theme(.heading) });

    dvui.labelNoFmt(@src(), i18n.t("label_dest"), .{}, .{ .color_text = .gray });
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 4, .h = 4 } });
    defer row.deinit();
    var te_host = dvui.textEntry(@src(), .{ .text = .{ .buffer = &app.host_buf } }, .{ .max_size_content = .width(160) });
    te_host.deinit();
    dvui.labelNoFmt(@src(), i18n.t("label_colon_sep"), .{}, .{});
    var te_port = dvui.textEntry(@src(), .{ .text = .{ .buffer = &app.port_buf } }, .{ .max_size_content = .width(60) });
    te_port.deinit();

    var row2 = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row2.deinit();
    const running = app.client.running.load(.seq_cst);
    dvui.labelNoFmt(@src(), i18n.t("label_status"), .{}, .{});
    dvui.labelNoFmt(@src(), if (running) i18n.t("status_running") else i18n.t("status_stopped"), .{}, .{});
    if (dvui.button(@src(), i18n.t("btn_start"), .{}, .{})) {
        app.setCfgHostPort();
        startClient(app);
    }
    if (dvui.button(@src(), i18n.t("btn_stop"), .{}, .{})) stopClient(app);
    if (dvui.button(@src(), i18n.t("btn_log"), .{}, .{})) app.log_open = true;
}

// ---------- export scans ----------

fn scansPayload(app: *App) ?[]u8 {
    if (app.scans.items.len == 0) return null;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(app.gpa);
    for (app.scans.items) |s| {
        buf.appendSlice(app.gpa, s.code) catch return null;
        buf.append(app.gpa, '\n') catch return null;
    }
    return buf.toOwnedSlice(app.gpa) catch null;
}

fn copyToClipboard(app: *App, payload: []const u8) bool {
    if (os == .windows) {
        const z = std.heap.c_allocator.dupeZ(u8, payload) catch return false;
        defer std.heap.c_allocator.free(z);
        return SDLBackend.c.SDL_SetClipboardText(z.ptr);
    }
    var child = std.process.spawn(app.io, .{
        .argv = &.{ "wl-copy", "--type", "text/plain" },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch return false;
    var wbuf: [256]u8 = undefined;
    var w = child.stdin.?.writerStreaming(app.io, &wbuf);
    w.interface.writeAll(payload) catch {};
    w.interface.flush() catch {};
    child.stdin.?.close(app.io);
    child.stdin = null;
    const term = child.wait(app.io) catch return false;
    return term == .exited and term.exited == 0;
}

fn exportScansToFile(app: *App, payload: []const u8) void {
    const opts = dvui.native_dialogs.Native.DialogOptions{
        .title = i18n.t("export_dialog_title"),
        .path = "xemonitor-scans.txt",
        .filters = &.{"*.txt"},
        .filter_description = "Text files (*.txt)",
    };
    const path = dvui.dialogNativeFileSave(app.gpa, opts) catch {
        app.setMsg("msg_export_cancelled", .{});
        return;
    };
    if (path == null) {
        app.setMsg("msg_export_cancelled", .{});
        return;
    }
    const p = path.?;
    defer app.gpa.free(p);
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = p, .data = payload }) catch |err| {
        app.setMsg("msg_write_error", .{ p, @errorName(err) });
        return;
    };
    app.setMsg("msg_exported", .{ app.scans.items.len, p });
}

const HistoryState = struct {
    scroll_info: dvui.ScrollInfo = .{},
    user_scroll: dvui.Point = .{},
    last_len: usize = 0,
};

fn renderHistoryPanel(app: *App) void {
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 4, .h = 4 } });
        defer row.deinit();
        dvui.labelNoFmt(@src(), i18n.t("panel_history"), .{}, .{ .font = .theme(.heading) });
        dvui.labelNoFmt(@src(), "", .{}, .{ .expand = .horizontal });
        if (dvui.button(@src(), i18n.t("btn_copy"), .{}, .{})) {
            if (scansPayload(app)) |payload| {
                defer app.gpa.free(payload);
                if (copyToClipboard(app, payload)) {
                    app.setMsg("msg_copied", .{app.scans.items.len});
                } else {
                    app.setMsg("msg_copy_failed", .{});
                }
            } else {
                app.setMsg("msg_no_scans_copy", .{});
            }
        }
        if (dvui.button(@src(), i18n.t("btn_export"), .{}, .{})) {
            if (scansPayload(app)) |payload| {
                defer app.gpa.free(payload);
                exportScansToFile(app, payload);
            } else {
                app.setMsg("msg_no_scans_export", .{});
            }
        }
    }

    const state = dvui.dataGetPtrDefault(null, dvui.parentGet().data().id, "history", HistoryState, .{});
    const stick_to_bottom = state.scroll_info.offsetFromMax(.vertical) <= 0;
    const new_scan = state.last_len != app.scans.items.len;
    state.last_len = app.scans.items.len;

    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &state.scroll_info, .user_scroll = &state.user_scroll }, .{ .expand = .both, .margin = .{ .y = 4, .h = 4 } });

    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .margin = .{ .y = 4, .h = 4 } });
    if (app.scans.items.len == 0) {
        dvui.labelNoFmt(@src(), i18n.t("status_no_scans"), .{}, .{});
    }
    for (app.scans.items, 0..) |s, i| {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "[{s}] {s}", .{ s.time, s.code }) catch continue;
        dvui.labelNoFmt(@src(), line, .{}, .{ .id_extra = i });
    }
    box.deinit();

    // processScrollTo precisa do novo tamanho; cola no fim quando chega scan
    // novo e o usuário já está no final (padrão stick-to-bottom do dvui).
    scroll.deinit();
    if (new_scan and stick_to_bottom and state.user_scroll.y >= 0) {
        state.scroll_info.scrollToOffset(.vertical, std.math.floatMax(f32));
    }
}

fn renderLogWindow(app: *App) void {
    const os_win = dvui.osWindow(
        @src(),
        .{ .title = i18n.t("win_log_title"), .size = .{ .w = 560.0, .h = 420.0 }, .min_size = .{ .w = 320.0, .h = 200.0 } },
        .{ .id_extra = 1, .open_flag = &app.log_open },
    );
    defer os_win.deinit();

    dvui.labelNoFmt(@src(), i18n.t("log_heading"), .{}, .{ .font = .theme(.heading) });
    var scroll = dvui.scrollArea(@src(), .{ .vertical = .auto, .horizontal = .auto, .vertical_bar = .auto, .horizontal_bar = .auto }, .{ .expand = .both, .min_size_content = .{ .w = 0, .h = 200 } });
    defer scroll.deinit();
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer box.deinit();
    if (app.log_lines.items.len == 0) {
        dvui.labelNoFmt(@src(), i18n.t("status_log_empty"), .{}, .{});
    }
    for (app.log_lines.items, 0..) |ll, i| {
        dvui.labelNoFmt(@src(), ll.line, .{}, .{ .id_extra = i });
    }
}

/// Diálogo de confirmação de encerramento (botão "Encerrar" ou bandeja "Sair").
/// Confirmar encerra o GUI; cancelar/fechar mantém rodando.
fn renderConfirmQuitWindow(app: *App) void {
    if (!app.quit_confirm_open) return;
    const win = dvui.osWindow(
        @src(),
        .{ .title = i18n.t("dlg_quit_title"), .size = .{ .w = 340.0, .h = 150.0 }, .min_size = .{ .w = 300.0, .h = 130.0 } },
        .{ .id_extra = 2, .open_flag = &app.quit_confirm_open },
    );
    defer win.deinit();

    dvui.labelNoFmt(@src(), i18n.t("dlg_quit_heading"), .{}, .{ .font = .theme(.heading) });
    dvui.labelNoFmt(@src(), i18n.t("dlg_quit_body"), .{}, .{});
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 12, .h = 4 } });
    defer row.deinit();
    dvui.labelNoFmt(@src(), "", .{}, .{ .expand = .horizontal });
    if (dvui.button(@src(), i18n.t("btn_cancel"), .{}, .{})) app.quit_confirm_result = .cancel;
    if (dvui.button(@src(), i18n.t("btn_quit"), .{}, .{})) app.quit_confirm_result = .yes;
}

fn guiFrame(app: *App) bool {
    refreshStatus(app);
    drainAsyncMsg(app);
    drainClientLines(app);

    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .margin = .{ .x = 8, .y = 8, .w = 8, .h = 8 }, .background = true, .name = "root" });
    defer vbox.deinit();

    // Header: título + idioma + encerrar (bloco explícito para fechar antes do subtitle)
    {
        var header = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer header.deinit();
        dvui.label(@src(), "XeMonitor", .{}, .{ .font = .theme(.title) });
        dvui.labelNoFmt(@src(), "", .{}, .{ .expand = .horizontal });
        dvui.labelNoFmt(@src(), i18n.t("lang_label"), .{}, .{});
        const lang_names = [_][]const u8{ "English", "Português (BR)" };
        var lang_idx: usize = @intFromEnum(app.locale);
        if (dvui.dropdown(@src(), &lang_names, .{ .choice = &lang_idx }, .{}, .{})) {
            app.locale = @enumFromInt(lang_idx);
            i18n.setLocale(app.locale);
            const lang_str = i18n.Locale.toString(app.locale);
            app.gpa.free(app.cfg.lang);
            app.cfg.lang = app.gpa.dupe(u8, lang_str) catch "";
            saveConfig(app.gpa, app.io, app.config_path, &app.cfg);
        }
        if (dvui.button(@src(), i18n.t("btn_quit"), .{}, .{})) {
            app.quit_confirm_open = true;
            app.quit_confirm_result = .none;
        }
    }

    dvui.labelNoFmt(@src(), i18n.t("subtitle"), .{}, .{});

    _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .y = 4, .h = 4 } });

    renderServerPanel(app);
    _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .y = 4, .h = 4 } });
    renderClientPanel(app);
    _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .y = 4, .h = 4 } });
    renderHistoryPanel(app);

    if (app.msg_len > 0) {
        dvui.labelNoFmt(@src(), app.msg_buf[0..app.msg_len], .{}, .{});
    }

    if (app.log_open) renderLogWindow(app);
    renderConfirmQuitWindow(app);

    return true;
}

fn showAppWindow(backend: *SDLBackend) void {
    _ = SDLBackend.c.SDL_ShowWindow(backend.window);
    _ = SDLBackend.c.SDL_RaiseWindow(backend.window);
}

fn hideAppWindow(backend: *SDLBackend) void {
    _ = SDLBackend.c.SDL_HideWindow(backend.window);
}

fn windowIsHidden(backend: *SDLBackend) bool {
    const flags = SDLBackend.c.SDL_GetWindowFlags(backend.window);
    return (flags & SDLBackend.c.SDL_WINDOW_HIDDEN) != 0 or
        (flags & SDLBackend.c.SDL_WINDOW_MINIMIZED) != 0;
}

// Aplica o icone da janela (PNG embutido, com fallback procedural) via
// SDL_SetWindowIcon. Funciona em X11/Windows/macOS; no Wayland o icone do
// painel vem do arquivo .desktop (assets/xemonitor.desktop -> Icon=xemonitor).
fn setWindowIcon(backend: *SDLBackend) void {
    const png = @import("png.zig");
    const W: i32 = 64;
    const H: i32 = 64;
    var rgba: [64 * 64 * 4]u8 = undefined;
    if (png.rgba().len != 0) {
        png.resize(png.rgba(), png.width, png.height, &rgba, 64, 64, .rgba);
        const surf = SDLBackend.c.SDL_CreateSurfaceFrom(W, H, SDLBackend.c.SDL_PIXELFORMAT_RGBA32, &rgba, W * 4) orelse return;
        defer SDLBackend.c.SDL_DestroySurface(surf);
        _ = SDLBackend.c.SDL_SetWindowIcon(backend.window, surf);
        return;
    }

    const surf = SDLBackend.c.SDL_CreateSurface(W, H, SDLBackend.c.SDL_PIXELFORMAT_RGBA32) orelse return;
    defer SDLBackend.c.SDL_DestroySurface(surf);

    const details = SDLBackend.c.SDL_GetPixelFormatDetails(SDLBackend.c.SDL_PIXELFORMAT_RGBA32) orelse return;
    const white = SDLBackend.c.SDL_MapRGBA(details, null, 255, 255, 255, 255);
    const dark = SDLBackend.c.SDL_MapRGBA(details, null, 24, 28, 42, 255);

    const bg = SDLBackend.c.SDL_Rect{ .x = 0, .y = 0, .w = W, .h = H };
    _ = SDLBackend.c.SDL_FillSurfaceRect(surf, &bg, white);

    const bars = [_]struct { x: i32, w: i32 }{
        .{ .x = 10, .w = 4 },
        .{ .x = 16, .w = 2 },
        .{ .x = 20, .w = 5 },
        .{ .x = 27, .w = 2 },
        .{ .x = 31, .w = 4 },
        .{ .x = 37, .w = 2 },
        .{ .x = 41, .w = 5 },
        .{ .x = 48, .w = 2 },
        .{ .x = 52, .w = 3 },
    };
    for (bars) |b| {
        const r = SDLBackend.c.SDL_Rect{ .x = b.x, .y = 10, .w = b.w, .h = H - 20 };
        _ = SDLBackend.c.SDL_FillSurfaceRect(surf, &r, dark);
    }
    _ = SDLBackend.c.SDL_SetWindowIcon(backend.window, surf);
}

// ---------- main ----------

pub fn main(init: std.process.Init) !u8 {
    if (comptime os == .windows) {
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }

    var replace = true;
    {
        const args = try init.minimal.args.toSlice(init.arena.allocator());
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--no-replace")) replace = false;
            if (std.mem.eql(u8, arg, "--replace")) replace = true;
        }
    }
    gui_cfg_dir = paths.openConfigDir(init.arena.allocator(), init.environ_map, init.io);
    enforceSingleInstance(init.io, replace);
    defer removePidFile(init.io);

    var backend = try SDLBackend.initWindow(.{
        .io = init.io,
        .environ_map = init.environ_map,
        .size = .{ .w = 880.0, .h = 660.0 },
        .min_size = .{ .w = 420.0, .h = 360.0 },
        .vsync = true,
        .title = APP_TITLE,
    });
    defer backend.deinit();
    setWindowIcon(&backend);

var window_open = true;
    var theme_scheme = backend.preferredColorScheme();
    var win = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{
        .theme = switch (theme_scheme orelse .light) {
            .light => dvui.Theme.builtin.adwaita_light,
            .dark => dvui.Theme.builtin.adwaita_dark,
        },
        .open_flag = &window_open,
    });
    defer win.deinit();

    var app = App.init(init.gpa, init.io);
    app.client.capture_stderr = true;
    app.client.alloc = init.gpa;
    backfillLog(&app);
    defer app.deinit();

    var tray: tray_mod.Tray = .{};
    var tray_active = false;
    if (app.cfg.tray_enabled) {
        tray_active = tray.start();
    }
    defer tray.stop();

    var hidden = false;
    var quit_pending = false;
    var quit_was_hidden = false;

    if (app.cfg.auto_start) {
        startBridge(&app);
        startClient(&app);
    }

    var interrupted = false;
    var last_watchdog_at: i128 = 0;
    main_loop: while (true) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);

        // Tema claro/escuro: reaplica quando o sistema muda (SDL3 emite
        // SDL_EVENT_SYSTEM_THEME_CHANGED e atualiza SDL_GetSystemTheme).
        const cur_scheme = backend.preferredColorScheme();
        if (cur_scheme != theme_scheme) {
            theme_scheme = cur_scheme;
            win.themeSet(switch (cur_scheme orelse .light) {
                .light => dvui.Theme.builtin.adwaita_light,
                .dark => dvui.Theme.builtin.adwaita_dark,
            });
        }

        try backend.addAllEvents(&win);

        if (tray.takeShowRequest()) {
            if (hidden) showAppWindow(&backend);
            hidden = false;
        }
        if (tray.takeToggleRequest()) {
            if (windowIsHidden(&backend)) {
                showAppWindow(&backend);
                hidden = false;
            } else {
                hideAppWindow(&backend);
                hidden = true;
            }
        }
        // bandeja "Sair": pede confirmação (mostra a janela se estiver oculta).
        // Sem bandeja, encerra direto.
        if (tray.takeQuitRequest()) {
            if (tray_active) {
                quit_pending = true;
                if (hidden) {
                    quit_was_hidden = true;
                    showAppWindow(&backend);
                    hidden = false;
                }
                app.quit_confirm_open = true;
                app.quit_confirm_result = .none;
            } else {
                break :main_loop;
            }
        }

        // fechar pela "X": oculta no tray (se houver); senão encerra.
        if (!window_open) {
            if (quit_pending) {
                window_open = true; // mantém vivo enquanto o diálogo está aberto
            } else if (tray_active) {
                window_open = true;
                hideAppWindow(&backend);
                hidden = true;
            } else {
                break :main_loop;
            }
        }

        const keep = guiFrame(&app);
        if (!keep) break :main_loop;

        // fechado pela "X" do próprio diálogo = cancelar
        if (quit_pending and !app.quit_confirm_open and app.quit_confirm_result == .none) {
            app.quit_confirm_result = .cancel;
        }

        switch (app.quit_confirm_result) {
            .yes => break :main_loop,
            .cancel => {
                app.quit_confirm_result = .none;
                app.quit_confirm_open = false;
                quit_pending = false;
                if (quit_was_hidden and !windowIsHidden(&backend)) {
                    hideAppWindow(&backend);
                    hidden = true;
                }
                quit_was_hidden = false;
            },
            .none => {},
        }

        if (app.nowNs() - last_watchdog_at >= 5 * ns_per_s) {
            last_watchdog_at = app.nowNs();
            watchdogTick(&app);
        }

        const end_micros = try win.end(.{});
        const wait_event_micros = win.waitTime(end_micros);
        // waitTime() retorna maxInt(u32) quando ocioso -> SDL_WaitEvent(null)
        // bloqueia para sempre e o main loop nunca processa os pedidos da
        // bandeja (D-Bus chega em outra thread). Acordar periodicamente
        // garante o poll dos atomics.
        const poll_micros: u32 = 250_000;
        interrupted = try backend.waitEventTimeout(@min(wait_event_micros, poll_micros));
    }

    saveConfig(app.gpa, app.io, app.config_path, &app.cfg);
    return 0;
}
