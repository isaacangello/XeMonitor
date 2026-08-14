const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const SDLBackend = @import("sdl3-backend");
const tray_mod = @import("tray.zig");
const paths = @import("paths.zig");

const os = builtin.os.tag;

const APP_NAME = "XeMonitor";
const CONFIG_FILE = paths.GUI_CONFIG_FILE;
const DEFAULT_LOG = paths.LOG_FILE;

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

fn readPidFile(io: std.Io) ?u32 {
    var buf: [32]u8 = undefined;
    const data = gui_cfg_dir.dir.readFile(io, GUI_PID_FILE, &buf) catch return null;
    const s = std.mem.trim(u8, data, " \t\r\n");
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn pidAlive(pid: u32) bool {
    if (os != .linux) return false;
    const r = std.posix.kill(@intCast(pid), @enumFromInt(0));
    return !std.meta.isError(r);
}

fn writePidFile(io: std.Io) void {
    var f = gui_cfg_dir.dir.createFile(io, GUI_PID_FILE, .{}) catch return;
    defer f.close(io);
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}\n", .{std.os.linux.getpid()}) catch return;
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
                    _ = std.posix.kill(@intCast(old_pid), std.posix.SIG.TERM) catch {};
                    sleepMs(500);
                    _ = std.posix.kill(@intCast(old_pid), std.posix.SIG.KILL) catch {};
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
};

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
    }
}

fn saveConfig(gpa: std.mem.Allocator, io: std.Io, path: []const u8, cfg: *const Config) void {
    const data = std.fmt.allocPrint(gpa,
        "tcp_host={s}\ntcp_port={d}\nserver_mode={s}\nbridge_path={s}\nclient_path={s}\nlog_path={s}\nauto_start={s}\ntray_enabled={s}\n",
        .{ cfg.tcp_host, cfg.tcp_port, cfg.server_mode, cfg.bridge_path, cfg.client_path, cfg.log_path, @as([]const u8, if (cfg.auto_start) "true" else "false"), @as([]const u8, if (cfg.tray_enabled) "true" else "false") },
    ) catch return;
    defer gpa.free(data);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch {};
}

// ---------- managed child process ----------

const ManagedProc = struct {
    mutex: std.Io.Mutex = .init,
    child: ?std.process.Child = null,
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

    fn init(gpa: std.mem.Allocator, io: std.Io) App {
        const path = paths.joinPath(gpa, gui_cfg_dir.path, CONFIG_FILE) orelse (gpa.dupe(u8, CONFIG_FILE) catch CONFIG_FILE);
        var cfg = loadConfig(gpa, io, path);

        var host_buf = [_]u8{0} ** 64;
        const hn = @min(cfg.tcp_host.len, host_buf.len - 1);
        @memcpy(host_buf[0..hn], cfg.tcp_host[0..hn]);
        host_buf[hn] = 0;

        var port_buf = [_]u8{0} ** 8;
        if (std.fmt.bufPrint(&port_buf, "{d}", .{cfg.tcp_port})) |p| {
            port_buf[p.len] = 0;
        } else |_| {}

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
    }

    fn nowNs(self: *App) i128 {
        return std.Io.Timestamp.now(self.io, .real).nanoseconds;
    }

    fn setMsg(self: *App, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.msg_buf, fmt, args) catch blk: {
            const m = std.fmt.bufPrint(&self.msg_buf, "erro de formatação", .{}) catch self.msg_buf[0..0];
            break :blk m;
        };
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

// Watchdog leve (roda a cada ~5s no main loop): detecta o caso "cliente
// conectado mas sem scans ha muito tempo" e avisa na barra de status. Usa
// apenas estado em memoria (nao spawna processos).
fn watchdogTick(app: *App) void {
    const client_running = app.client.running.load(.seq_cst);
    const silent_ns: i128 = if (app.last_scan_time_ns > 0)
        app.nowNs() - app.last_scan_time_ns
    else
        0;
    const silent_secs: i128 = if (silent_ns > 0) @divTrunc(silent_ns, ns_per_s) else 0;

    if (client_running and silent_ns > 0 and silent_secs >= 30) {
        if (app.watchdog_state == 0) {
            app.watchdog_state = 1;
            app.setMsg("aviso: conectado, mas sem scans ha {d}s. Verifique o scanner ou use 'Reparar'.", .{silent_secs});
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

fn backfillLog(app: *App) void {
    var buf: [1024]u8 = undefined;
    const is_abs = app.cfg.log_path.len > 0 and (app.cfg.log_path[0] == '/' or
        (app.cfg.log_path.len > 1 and app.cfg.log_path[1] == ':'));
    const path = if (is_abs) app.cfg.log_path
    else std.fmt.bufPrint(&buf, "{s}{c}{s}", .{
        gui_cfg_dir.path,
        paths.sep,
        if (app.cfg.log_path.len > 0) app.cfg.log_path else DEFAULT_LOG,
    }) catch DEFAULT_LOG;
    const data = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, std.Io.Limit.limited(8 * 1024 * 1024)) catch return;
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
    return runCommand(app.gpa, app.io, &.{ "wsl", "-u", "root", "systemctl", "is-active", "xemonitor-bridge" }).ok;
}

// Executa um comando com privilegios de root: pkexec (agente polkit) com
// fallback para um terminal konsole pedindo a senha.
fn runPrivileged(app: *App, argv: []const []const u8) CmdResult {
    var full = app.gpa.alloc([]const u8, argv.len + 1) catch return .{ .ok = false, .stdout = &.{}, .stderr = &.{} };
    full[0] = "pkexec";
    @memcpy(full[1..], argv);
    const res = runCommand(app.gpa, app.io, full);
    app.gpa.free(full);
    if (res.ok) return res;

    const joined = std.mem.join(app.gpa, " ", argv) catch return res;
    defer app.gpa.free(joined);
    const line = std.fmt.allocPrint(app.gpa, "{s} ; echo ; echo 'pressione Enter para fechar' ; read", .{joined}) catch return res;
    defer app.gpa.free(line);
    _ = runCommand(app.gpa, app.io, &.{ "konsole", "--hide-menubar", "--hide-tabbar", "--geometry=560x220", "-e", "bash", "-c", line });
    return .{ .ok = false, .stdout = &.{}, .stderr = &.{} };
}

fn systemdAction(app: *App, scope: []const u8, action: []const u8) void {
    const is_user = scope.len > 0;
    if (!is_user and runSystemdStatus(app, "")) {
        // Servico de sistema ja esta no estado desejado (start com ativo /
        // stop com parado) — evita prompt pkexec desnecessario.
        if (std.mem.eql(u8, action, "start")) {
            app.setMsg("bridge: systemd ja estava ativo", .{});
            return;
        }
    }
    const argv: []const []const u8 = if (is_user)
        &.{ "systemctl", "--user", action, "xemonitor-bridge" }
    else
        &.{ "systemctl", action, "xemonitor-bridge" };
    const res = if (is_user) runCommand(app.gpa, app.io, argv) else runPrivileged(app, argv);
    if (res.ok) {
        app.setMsg("bridge: systemd {s} ok", .{action});
    } else {
        app.setMsg("bridge: systemd {s} falhou ({s})", .{ action, @as([]const u8, res.stderr) });
    }
}

fn wslAction(app: *App, action: []const u8) void {
    const res = runCommand(app.gpa, app.io, &.{ "wsl", "-u", "root", "systemctl", action, "xemonitor-bridge" });
    if (res.ok) {
        app.setMsg("bridge: wsl {s} ok", .{action});
    } else {
        app.setMsg("bridge: wsl {s} falhou", .{action});
    }
}

fn startBridge(app: *App) void {
    if (isMode(app, "subprocess")) {
        app.bridge_port = findFreePort(app.io, app.cfg.tcp_port);
        const port_str = std.fmt.allocPrint(app.gpa, "{d}", .{app.bridge_port}) catch {
            app.setMsg("falha ao formatar porta", .{});
            return;
        };
        defer app.gpa.free(port_str);
        const argv: []const []const u8 = if (app.cfg.bridge_path.len > 0)
            &.{ app.cfg.bridge_path, "--tcp-port", port_str }
        else
            &.{ "xemonitor-bridge", "--tcp-port", port_str };
        app.bridge.start(app.io, argv) catch |err| {
            app.setMsg("falha ao iniciar bridge: {s}", .{@errorName(err)});
            return;
        };
        app.bridge_is_ours = true;
        app.started_this_session = true;
        app.setMsg("bridge subprocesso iniciado na porta {d}", .{app.bridge_port});
    } else if (isMode(app, "systemd-user")) {
        systemdAction(app, "--user", "start");
    } else if (isMode(app, "systemd-system")) {
        systemdAction(app, "", "start");
    } else if (isMode(app, "wsl")) {
        wslAction(app, "start");
    } else {
        app.setMsg("modo de servidor desconhecido: {s}", .{app.cfg.server_mode});
    }
}

fn stopBridge(app: *App) void {
    if (isMode(app, "subprocess")) {
        app.bridge.stop(app.io);
        app.bridge_is_ours = false;
        app.setMsg("bridge subprocesso parado", .{});
    } else if (isMode(app, "systemd-user")) {
        systemdAction(app, "--user", "stop");
    } else if (isMode(app, "systemd-system")) {
        systemdAction(app, "", "stop");
    } else if (isMode(app, "wsl")) {
        wslAction(app, "stop");
    } else {
        app.setMsg("modo de servidor desconhecido: {s}", .{app.cfg.server_mode});
    }
}

fn computeBridgeStatus(app: *App) []const u8 {
    if (isMode(app, "subprocess")) {
        if (app.bridge.running.load(.seq_cst)) {
            return std.fmt.bufPrint(&app.status_buf, "rodando (subprocesso, porta {d})", .{app.bridge_port}) catch "rodando";
        }
        return "parado";
    }
    if (isMode(app, "systemd-user") and os == .linux) {
        return if (runSystemdStatus(app, "--user")) "rodando (systemd user)" else "parado (systemd user)";
    }
    if (isMode(app, "systemd-system") and os == .linux) {
        return if (runSystemdStatus(app, "")) "rodando (systemd)" else "parado (systemd)";
    }
    if (isMode(app, "wsl") and os == .windows) {
        return if (runWslStatus(app)) "rodando (WSL)" else "parado (WSL)";
    }
    return "modo desconhecido";
}

fn refreshStatus(app: *App) void {
    const now = std.Io.Timestamp.now(app.io, .awake).nanoseconds;
    if (now - app.status_at < std.time.ns_per_ms * 1000) return;
    app.status_at = now;
    const s = computeBridgeStatus(app);
    app.status_len = @min(s.len, app.status_buf.len - 1);
    @memcpy(app.status_buf[0..app.status_len], s[0..app.status_len]);
}

fn killStaleClient(app: *App) void {
    if (os != .linux) return;
    // -x: casa apenas o processo do cliente (comm "xemonitor"), sem atingir
    // o proprio GUI ("xemonitor-gui") nem o bridge ("xemonitor-bridge").
    const res = runCommand(app.gpa, app.io, &.{ "pkill", "-9", "-x", "xemonitor" });
    if (res.ok) app.setMsg("cliente anterior encerrado", .{});
    std.Io.Dir.cwd().deleteFile(app.io, "xemonitor.pid") catch {};
}

fn startClient(app: *App) void {
    killStaleClient(app);
    const port: u16 = if (app.bridge_is_ours and app.bridge.running.load(.seq_cst)) app.bridge_port else app.cfg.tcp_port;
    const addr = std.fmt.allocPrint(app.gpa, "{s}:{d}", .{ app.cfg.tcp_host, port }) catch {
        app.setMsg("falha ao formatar endereço", .{});
        return;
    };
    defer app.gpa.free(addr);
    const argv: []const []const u8 = if (app.cfg.client_path.len > 0)
        &.{ app.cfg.client_path, "--tcp", addr }
    else
        &.{ "xemonitor", "--tcp", addr };
    app.client.start(app.io, argv) catch |err| {
        app.setMsg("falha ao iniciar cliente: {s}", .{@errorName(err)});
        return;
    };
    app.setMsg("cliente conectando em {s}", .{addr});
}

fn stopClient(app: *App) void {
    app.client.stop(app.io);
    app.setMsg("cliente parado", .{});
}

// ---------- UI ----------

fn renderServerPanel(app: *App) void {
    dvui.label(@src(), "Servidor (bridge)", .{}, .{ .font = .theme(.heading) });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 4, .h = 4 } });
    defer row.deinit();
    dvui.labelNoFmt(@src(), "Status: ", .{}, .{});
    dvui.labelNoFmt(@src(), app.status_buf[0..app.status_len], .{}, .{});

    var row2 = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row2.deinit();
    if (dvui.button(@src(), "Iniciar", .{}, .{})) startBridge(app);
    if (dvui.button(@src(), "Parar", .{}, .{})) stopBridge(app);
    dvui.labelNoFmt(@src(), "  modo: ", .{}, .{});
    dvui.labelNoFmt(@src(), app.cfg.server_mode, .{}, .{});
    dvui.labelNoFmt(@src(), "  porta cfg: ", .{}, .{});
    dvui.labelNoFmt(@src(), app.port_buf[0..portBufLen(app)], .{}, .{});
}

fn portBufLen(app: *App) usize {
    return std.mem.indexOfScalar(u8, &app.port_buf, 0) orelse app.port_buf.len;
}

fn hostBufLen(app: *App) usize {
    return std.mem.indexOfScalar(u8, &app.host_buf, 0) orelse app.host_buf.len;
}

fn renderClientPanel(app: *App) void {
    dvui.label(@src(), "Cliente (xemonitor)", .{}, .{ .font = .theme(.heading) });

    dvui.label(@src(), "Destino (host:porta)", .{}, .{ .color_text = .gray });
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 4, .h = 4 } });
    defer row.deinit();
    var te_host = dvui.textEntry(@src(), .{ .text = .{ .buffer = &app.host_buf } }, .{ .max_size_content = .width(160) });
    te_host.deinit();
    dvui.labelNoFmt(@src(), "  :  ", .{}, .{});
    var te_port = dvui.textEntry(@src(), .{ .text = .{ .buffer = &app.port_buf } }, .{ .max_size_content = .width(60) });
    te_port.deinit();

    var row2 = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row2.deinit();
    const running = app.client.running.load(.seq_cst);
    dvui.labelNoFmt(@src(), "Status: ", .{}, .{});
    dvui.labelNoFmt(@src(), if (running) "rodando" else "parado", .{}, .{});
    if (dvui.button(@src(), "Iniciar", .{}, .{})) {
        app.setCfgHostPort();
        startClient(app);
    }
    if (dvui.button(@src(), "Parar", .{}, .{})) stopClient(app);
    if (dvui.button(@src(), "Log", .{}, .{})) app.log_open = true;
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
    const argv: []const []const u8 = &.{
        "zenity", "--file-selection", "--save",
        "--title=Exportar scans (XeMonitor)",
        "--filename=xemonitor-scans.txt",
    };
    const res = runCommand(app.gpa, app.io, argv);
    if (!res.ok or res.stdout.len == 0) {
        app.setMsg("export cancelado", .{});
        return;
    }
    const path = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (path.len == 0) {
        app.setMsg("export cancelado", .{});
        return;
    }
    std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = payload }) catch |err| {
        app.setMsg("erro ao gravar {s}: {s}", .{ path, @errorName(err) });
        return;
    };
    app.setMsg("exportado {d} scans: {s}", .{ app.scans.items.len, path });
}

fn renderHistoryPanel(app: *App) void {
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 4, .h = 4 } });
        defer row.deinit();
        dvui.label(@src(), "Histórico (últimos scans)", .{}, .{ .font = .theme(.heading) });
        dvui.labelNoFmt(@src(), "", .{}, .{ .expand = .horizontal });
        if (dvui.button(@src(), "Copiar", .{}, .{})) {
            if (scansPayload(app)) |payload| {
                defer app.gpa.free(payload);
                if (copyToClipboard(app, payload)) {
                    app.setMsg("copiado {d} scans para a área de transferência", .{app.scans.items.len});
                } else {
                    app.setMsg("falha ao copiar (wl-copy indisponível?)", .{});
                }
            } else {
                app.setMsg("nenhum scan para copiar", .{});
            }
        }
        if (dvui.button(@src(), "Exportar arquivo", .{}, .{})) {
            if (scansPayload(app)) |payload| {
                defer app.gpa.free(payload);
                exportScansToFile(app, payload);
            } else {
                app.setMsg("nenhum scan para exportar", .{});
            }
        }
    }

    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .margin = .{ .y = 4, .h = 4 } });
    defer box.deinit();
    if (app.scans.items.len == 0) {
        dvui.labelNoFmt(@src(), "(nenhum scan ainda)", .{}, .{});
    }
    for (app.scans.items, 0..) |s, i| {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "[{s}] {s}", .{ s.time, s.code }) catch continue;
        dvui.labelNoFmt(@src(), line, .{}, .{ .id_extra = i });
    }
}

fn renderLogWindow(app: *App) void {
    const os_win = dvui.osWindow(
        @src(),
        .{ .title = "XeMonitor - Log", .size = .{ .w = 560.0, .h = 420.0 }, .min_size = .{ .w = 320.0, .h = 200.0 } },
        .{ .id_extra = 1, .open_flag = &app.log_open },
    );
    defer os_win.deinit();

    dvui.label(@src(), "Log (xemonitor)", .{}, .{ .font = .theme(.heading) });
    var scroll = dvui.scrollArea(@src(), .{ .vertical = .auto, .horizontal = .auto, .vertical_bar = .auto, .horizontal_bar = .auto }, .{ .expand = .both, .min_size_content = .{ .w = 0, .h = 200 } });
    defer scroll.deinit();
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer box.deinit();
    if (app.log_lines.items.len == 0) {
        dvui.labelNoFmt(@src(), "(log vazio)", .{}, .{});
    }
    for (app.log_lines.items, 0..) |ll, i| {
        dvui.labelNoFmt(@src(), ll.line, .{}, .{ .id_extra = i });
    }
}

fn guiFrame(app: *App) bool {
    refreshStatus(app);
    drainClientLines(app);

    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .margin = .{ .x = 8, .y = 8, .w = 8, .h = 8 }, .background = true, .name = "root" });
    defer vbox.deinit();

    dvui.label(@src(), "XeMonitor", .{}, .{ .font = .theme(.title) });
    dvui.labelNoFmt(@src(), "scanner -> bridge (TCP) -> injeção de teclado", .{}, .{});

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

// Desenha o icone da janela (barras do codigo de barras) e aplica via
// SDL_SetWindowIcon. Funciona em X11/Windows/macOS; no Wayland o icone do
// painel vem do arquivo .desktop (assets/xemonitor.desktop -> Icon=xemonitor).
fn setWindowIcon(backend: *SDLBackend) void {
    const W: i32 = 64;
    const H: i32 = 64;
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
        .title = "XeMonitor",
    });
    defer backend.deinit();
    setWindowIcon(&backend);

    var window_open = true;
    var win = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{
        .theme = switch (backend.preferredColorScheme() orelse .light) {
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

    if (app.cfg.auto_start) {
        startBridge(&app);
        startClient(&app);
    }

    var interrupted = false;
    var last_watchdog_at: i128 = 0;
    main_loop: while (true) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);
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
        if (tray.takeQuitRequest()) {
            window_open = false;
        }

        // closing via window "X": hide to tray if available, otherwise quit
        if (!window_open) {
            if (tray_active and !tray.takeQuitRequest()) {
                window_open = true;
                hideAppWindow(&backend);
                hidden = true;
            } else {
                break :main_loop;
            }
        }

        const keep = guiFrame(&app);
        if (!keep) break :main_loop;

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
