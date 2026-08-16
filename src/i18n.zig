const std = @import("std");

/// Localização do texto da interface. Padrão: inglês ("us");
/// português do Brasil também é suportado.
pub const Locale = enum {
    us,
    pt_br,

    pub fn fromString(s: []const u8) Locale {
        if (std.mem.eql(u8, s, "pt_br")) return .pt_br;
        return .us;
    }

    pub fn toString(self: Locale) []const u8 {
        return switch (self) {
            .us => "us",
            .pt_br => "pt_br",
        };
    }
};

/// Locale ativo. Definido no init (antes de qualquer thread/bandeja) e pode
/// ser trocado pelo seletor de idioma no painel.
var current: Locale = .us;

pub fn setLocale(l: Locale) void {
    current = l;
}

/// Tradução de uma chave para o locale atual. Chave inexistente em qualquer
/// das duas tabelas falha em tempo de compilação (as tabelas devem casar).
pub fn t(comptime key: []const u8) [:0]const u8 {
    return switch (current) {
        .us => @field(us, key),
        .pt_br => @field(pt_br, key),
    };
}

/// Formata um template runtime (apenas placeholders {s} e {d}) em `buf`,
/// preenchendo os args na ordem dos placeholders. Retorna o slice escrito
/// (ou um slice vazio se estourar o buffer).
pub fn formatInto(buf: []u8, template: []const u8, args: anytype) []u8 {
    var pos: usize = 0;
    var ai: usize = 0;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] != '{') {
            if (pos + 1 > buf.len) return buf[0..pos];
            buf[pos] = template[i];
            pos += 1;
            i += 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, template, i + 1, '}') orelse return buf[0..pos];
        i = end + 1;
        if (ai >= std.meta.fields(@TypeOf(args)).len) return buf[0..pos];
        var field_i: usize = 0;
        inline for (std.meta.fields(@TypeOf(args))) |f| {
            if (ai == field_i) {
                const arg = @field(args, f.name);
                if (comptime isInteger(@TypeOf(arg))) {
                    const n: i128 = @intCast(arg);
                    const s = std.fmt.bufPrint(buf[pos..], "{d}", .{n}) catch return buf[0..pos];
                    pos += s.len;
                } else {
                    const s: []const u8 = arg;
                    if (pos + s.len > buf.len) return buf[0..pos];
                    @memcpy(buf[pos..][0..s.len], s);
                    pos += s.len;
                }
            }
            field_i += 1;
        }
        ai += 1;
    }
    return buf[0..pos];
}

fn isInteger(T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .comptime_int => true,
        else => false,
    };
}

const us = .{
    .panel_server = "Server (bridge)",
    .panel_client = "Client (xemonitor)",
    .panel_history = "History (last scans)",
    .label_status = "Status: ",
    .label_mode = "  mode: ",
    .label_port_cfg = "  cfg port: ",
    .label_dest = "Target (host:port)",
    .label_colon_sep = "  :  ",
    .lang_label = "Language: ",
    .btn_start = "Start",
    .btn_stop = "Stop",
    .btn_log = "Log",
    .btn_copy = "Copy",
    .btn_export = "Export file",
    .btn_quit = "Quit",
    .btn_cancel = "Cancel",
    .status_running = "running",
    .status_stopped = "stopped",
    .status_no_scans = "(no scans yet)",
    .status_log_empty = "(log empty)",
    .subtitle = "scanner -> bridge (TCP) -> keyboard injection",
    .status_subprocess = "running (subprocess, port {d})",
    .status_systemd_user_running = "running (systemd user)",
    .status_systemd_user_stopped = "stopped (systemd user)",
    .status_systemd_running = "running (systemd)",
    .status_systemd_stopped = "stopped (systemd)",
    .status_wsl_running = "running (WSL)",
    .status_wsl_stopped = "stopped (WSL)",
    .status_mode_unknown = "unknown mode",
    .msg_no_scans_warn = "warning: connected, but no scans in {d}s. Check the scanner or use 'Repair'.",
    .msg_usb_serial_missing = "IMPORTANT: USB-SERIAL scanner not detected in WSL. Connect the Honeywell 1900 (CH340) and run setup_usb.bat, or use 'Repair'.",
    .msg_usb_serial_found = "USB-Serial scanner detected (/dev/ttyUSB0 in WSL).",
    .msg_bridge_active = "bridge: systemd already active",
    .msg_bridge_ok = "bridge: systemd {s} ok",
    .msg_bridge_failed = "bridge: systemd {s} failed ({s})",
    .msg_wsl_ok = "bridge: wsl {s} ok",
    .msg_wsl_failed = "bridge: wsl {s} failed",
    .msg_fmt_port_failed = "failed to format port",
    .msg_bridge_start_failed = "failed to start bridge: {s}",
    .msg_bridge_subprocess_started = "bridge subprocess started on port {d}",
    .msg_bridge_subprocess_stopped = "bridge subprocess stopped",
    .msg_mode_unknown = "unknown server mode: {s}",
    .msg_old_client_killed = "previous client terminated",
    .msg_fmt_addr_failed = "failed to format address",
    .msg_client_start_failed = "failed to start client: {s}",
    .msg_client_connecting = "client connecting to {s}",
    .msg_client_stopped = "client stopped",
    .msg_export_cancelled = "export cancelled",
    .msg_write_error = "error writing {s}: {s}",
    .msg_exported = "exported {d} scans: {s}",
    .msg_copied = "copied {d} scans to clipboard",
    .msg_copy_failed = "failed to copy to clipboard",
    .msg_no_scans_copy = "no scans to copy",
    .msg_no_scans_export = "no scans to export",
    .msg_fmt_error = "formatting error",
    .dlg_quit_title = "XeMonitor - Quit?",
    .dlg_quit_heading = "Quit XeMonitor?",
    .dlg_quit_body = "The bridge and the client will be stopped.",
    .win_log_title = "XeMonitor - Log",
    .log_heading = "Log (xemonitor)",
    .export_dialog_title = "Export scans (XeMonitor)",
    .press_enter = "press Enter to close",
    .tray_show = "Show window",
    .tray_quit = "Quit",
};

const pt_br = .{
    .panel_server = "Servidor (bridge)",
    .panel_client = "Cliente (xemonitor)",
    .panel_history = "Histórico (últimos scans)",
    .label_status = "Status: ",
    .label_mode = "  modo: ",
    .label_port_cfg = "  porta cfg: ",
    .label_dest = "Destino (host:porta)",
    .label_colon_sep = "  :  ",
    .lang_label = "Idioma: ",
    .btn_start = "Iniciar",
    .btn_stop = "Parar",
    .btn_log = "Log",
    .btn_copy = "Copiar",
    .btn_export = "Exportar arquivo",
    .btn_quit = "Encerrar",
    .btn_cancel = "Cancelar",
    .status_running = "rodando",
    .status_stopped = "parado",
    .status_no_scans = "(nenhum scan ainda)",
    .status_log_empty = "(log vazio)",
    .subtitle = "scanner -> bridge (TCP) -> injeção de teclado",
    .status_subprocess = "rodando (subprocesso, porta {d})",
    .status_systemd_user_running = "rodando (systemd user)",
    .status_systemd_user_stopped = "parado (systemd user)",
    .status_systemd_running = "rodando (systemd)",
    .status_systemd_stopped = "parado (systemd)",
    .status_wsl_running = "rodando (WSL)",
    .status_wsl_stopped = "parado (WSL)",
    .status_mode_unknown = "modo desconhecido",
    .msg_no_scans_warn = "aviso: conectado, mas sem scans ha {d}s. Verifique o scanner ou use 'Reparar'.",
    .msg_usb_serial_missing = "IMPORTANTE: scanner USB-SERIAL nao detectado no WSL. Conecte o Honeywell 1900 (CH340) e rode setup_usb.bat, ou use 'Reparar'.",
    .msg_usb_serial_found = "Scanner USB-Serial detectado (/dev/ttyUSB0 no WSL).",
    .msg_bridge_active = "bridge: systemd ja estava ativo",
    .msg_bridge_ok = "bridge: systemd {s} ok",
    .msg_bridge_failed = "bridge: systemd {s} falhou ({s})",
    .msg_wsl_ok = "bridge: wsl {s} ok",
    .msg_wsl_failed = "bridge: wsl {s} falhou",
    .msg_fmt_port_failed = "falha ao formatar porta",
    .msg_bridge_start_failed = "falha ao iniciar bridge: {s}",
    .msg_bridge_subprocess_started = "bridge subprocesso iniciado na porta {d}",
    .msg_bridge_subprocess_stopped = "bridge subprocesso parado",
    .msg_mode_unknown = "modo de servidor desconhecido: {s}",
    .msg_old_client_killed = "cliente anterior encerrado",
    .msg_fmt_addr_failed = "falha ao formatar endereço",
    .msg_client_start_failed = "falha ao iniciar cliente: {s}",
    .msg_client_connecting = "cliente conectando em {s}",
    .msg_client_stopped = "cliente parado",
    .msg_export_cancelled = "export cancelado",
    .msg_write_error = "erro ao gravar {s}: {s}",
    .msg_exported = "exportado {d} scans: {s}",
    .msg_copied = "copiado {d} scans para a área de transferência",
    .msg_copy_failed = "falha ao copiar para a área de transferência",
    .msg_no_scans_copy = "nenhum scan para copiar",
    .msg_no_scans_export = "nenhum scan para exportar",
    .msg_fmt_error = "erro de formatação",
    .dlg_quit_title = "XeMonitor - Encerrar?",
    .dlg_quit_heading = "Encerrar o XeMonitor?",
    .dlg_quit_body = "O bridge e o cliente serão parados.",
    .win_log_title = "XeMonitor - Log",
    .log_heading = "Log (xemonitor)",
    .export_dialog_title = "Exportar scans (XeMonitor)",
    .press_enter = "pressione Enter para fechar",
    .tray_show = "Mostrar janela",
    .tray_quit = "Sair",
};
