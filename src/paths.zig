// XeMonitor — resolução do diretório central de config/log.
//
// Convenção (documentada no AGENTS.md / README):
//   Linux   -> $XDG_CONFIG_HOME/xemonitor  (padrão: $HOME/.config/xemonitor)
//   Windows -> %APPDATA%\xemonitor        (fallback: %LOCALAPPDATA%\xemonitor)
//   Override de teste -> env XEMONITOR_CONFIG_DIR
// Se o diretório não puder ser determinado/criado, usa o cwd (comportamento antigo).
const std = @import("std");
const builtin = @import("builtin");

pub const APP_DIR_NAME = "xemonitor";
/// Prefixo do arquivo de log datado: xemonitor-YYYY-MM-DD.log
pub const LOG_PREFIX = "xemonitor-";
pub const GUI_CONFIG_FILE = "xemonitor-gui.conf";
pub const CLIENT_PID_FILE = "xemonitor.pid";
pub const GUI_PID_FILE = "xemonitor-gui.pid";
pub const TRAY_PID_FILE = "xemonitor_tray.pid";

/// Monta o nome do arquivo de log datado a partir de uma data "YYYY-MM-DD".
pub fn datedLogName(buf: []u8, date: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}.log", .{ LOG_PREFIX, date }) catch buf[0..0];
}

pub const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';

pub const ConfigDir = struct {
    /// Handle aberto no diretório (ou no cwd em caso de fallback).
    dir: std.Io.Dir,
    /// Caminho absoluto do diretório (para exibir em logs/status). Sem barra final.
    path: []u8,
    /// true => `dir`/`path` pertencem a nós e devem ser liberados em `deinit`.
    owned: bool = true,

    pub fn deinit(self: *ConfigDir, gpa: std.mem.Allocator, io: std.Io) void {
        if (self.owned) {
            self.dir.close(io);
            gpa.free(self.path);
        }
    }
};

pub fn joinPath(gpa: std.mem.Allocator, base: []const u8, sub: []const u8) ?[]u8 {
    if (base.len == 0) return gpa.dupe(u8, sub) catch null;
    if (base[base.len - 1] == sep) {
        return std.fmt.allocPrint(gpa, "{s}{s}", .{ base, sub }) catch null;
    }
    return std.fmt.allocPrint(gpa, "{s}{c}{s}", .{ base, sep, sub }) catch null;
}

/// Resolve e abre (criando se preciso) o diretório de config do app.
pub fn openConfigDir(
    gpa: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    io: std.Io,
) ConfigDir {
    var path: ?[]u8 = null;

    if (environ_map.get("XEMONITOR_CONFIG_DIR")) |override| {
        path = joinPath(gpa, override, APP_DIR_NAME);
    } else if (comptime builtin.os.tag == .windows) {
        if (environ_map.get("APPDATA")) |a| {
            path = joinPath(gpa, a, APP_DIR_NAME);
        } else if (environ_map.get("LOCALAPPDATA")) |a| {
            path = joinPath(gpa, a, APP_DIR_NAME);
        }
    } else {
        if (environ_map.get("XDG_CONFIG_HOME")) |xdg| {
            path = joinPath(gpa, xdg, APP_DIR_NAME);
        } else if (environ_map.get("HOME")) |home| {
            path = std.fmt.allocPrint(gpa, "{s}/.config/{s}", .{ home, APP_DIR_NAME }) catch null;
        }
    }

    const p = path orelse return ConfigDir{ .dir = std.Io.Dir.cwd(), .path = gpa.dupe(u8, APP_DIR_NAME) catch "", .owned = false };

    const cwd = std.Io.Dir.cwd();
    if (cwd.openDir(io, p, .{})) |d| {
        return ConfigDir{ .dir = d, .path = p, .owned = true };
    } else |_| {
        cwd.createDirPath(io, p) catch {
            return ConfigDir{ .dir = cwd, .path = p, .owned = false };
        };
        if (cwd.openDir(io, p, .{})) |d| {
            return ConfigDir{ .dir = d, .path = p, .owned = true };
        } else |_| {
            return ConfigDir{ .dir = cwd, .path = p, .owned = false };
        }
    }
}
