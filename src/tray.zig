const std = @import("std");
const builtin = @import("builtin");
const os = builtin.os.tag;

/// System tray integration without orphan subprocesses.
/// - Windows: Shell_NotifyIconW on a dedicated message-only window.
/// - Linux: StatusNotifierItem over libdbus (session bus), with a minimal
///   com.canonical.dbusmenu on /Menu.
///
/// The GUI main loop polls `takeShowRequest()` / `takeQuitRequest()` every
/// frame; callbacks are never invoked from the tray thread to avoid
/// non-atomic UI mutation.

pub const Tray = struct {
    show_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    toggle_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    quit_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    fn requestShow(self: *Tray) void {
        self.show_requested.store(true, .seq_cst);
    }

    fn requestToggle(self: *Tray) void {
        self.toggle_requested.store(true, .seq_cst);
    }

    fn requestQuit(self: *Tray) void {
        self.quit_requested.store(true, .seq_cst);
    }

    pub fn takeShowRequest(self: *Tray) bool {
        return self.show_requested.swap(false, .seq_cst);
    }

    pub fn takeToggleRequest(self: *Tray) bool {
        return self.toggle_requested.swap(false, .seq_cst);
    }

    pub fn takeQuitRequest(self: *Tray) bool {
        return self.quit_requested.swap(false, .seq_cst);
    }

    /// Spawns the tray thread. On Linux the thread connects to the session
    /// bus and registers the StatusNotifierItem; on Windows it creates the
    /// message-only window. Returns true if the tray is expected to work.
    pub fn start(self: *Tray) bool {
        if (comptime os == .linux) {
            self.thread = std.Thread.spawn(.{}, linuxTrayMain, .{self}) catch return false;
            return true;
        } else if (comptime os == .windows) {
            self.thread = std.Thread.spawn(.{}, windowsTrayMain, .{self}) catch return false;
            return true;
        } else {
            return false;
        }
    }

    pub fn stop(self: *Tray) void {
        self.stop_flag.store(true, .seq_cst);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    // ------------------------------------------------------------------
    // Windows: Shell_NotifyIconW
    // ------------------------------------------------------------------

    fn windowsTrayMain(self: *Tray) void {
        windows.init(self) catch {};
        while (!self.stop_flag.load(.seq_cst)) {
            var msg: windows.MSG = undefined;
            const r = windows.GetMessageW(&msg, null, 0, 0);
            if (r == 0 or r == -1) break;
            _ = windows.TranslateMessage(&msg);
            _ = windows.DispatchMessageW(&msg);
        }
        windows.deinit();
    }

    // ------------------------------------------------------------------
    // Linux: StatusNotifierItem over libdbus
    // ------------------------------------------------------------------

    fn linuxTrayMain(self: *Tray) void {
        linux.run(self);
    }
};

const windows = if (os == .windows) struct {
    const windows_api = std.os.windows;

    const WM_USER: u32 = 0x0400;
    const WM_TRAYCALLBACK = WM_USER + 1;
    const WM_COMMAND: u32 = 0x0111;
    const WM_DESTROY: u32 = 0x0002;
    const WM_LBUTTONUP: u32 = 0x0202;
    const WM_LBUTTONDBLCLK: u32 = 0x0203;
    const WM_RBUTTONUP: u32 = 0x0205;

    const NIM_ADD: u32 = 0;
    const NIM_DELETE: u32 = 2;
    const NIF_MESSAGE: u32 = 1;
    const NIF_ICON: u32 = 2;
    const NIF_TIP: u32 = 4;

    const MF_STRING: u32 = 0;
    const TPM_RIGHTBUTTON: u32 = 2;
    const TPM_RETURNCMD: u32 = 0x100;

    const ID_SHOW: u32 = 1;
    const ID_QUIT: u32 = 2;

    const IDI_APPLICATION: usize = 32512;
    const HWND_MESSAGE: ?*anyopaque = @ptrFromInt(@as(usize, 0xfffffffffffffffd));

    const MSG = extern struct {
        hwnd: ?*anyopaque,
        message: u32,
        wParam: usize,
        lParam: isize,
        time: u32,
        pt: windows_api.POINT,
    };

    const BITMAPINFOHEADER = extern struct {
        biSize: u32,
        biWidth: i32,
        biHeight: i32,
        biPlanes: u16,
        biBitCount: u16,
        biCompression: u32,
        biSizeImage: u32,
        biXPelsPerMeter: i32,
        biYPelsPerMeter: i32,
        biClrUsed: u32,
        biClrImportant: u32,
    };

    const BITMAPINFO = extern struct {
        bmiHeader: BITMAPINFOHEADER,
        bmiColors: [1]u32,
    };

    const ICONINFO = extern struct {
        fIcon: c_int,
        xHotspot: u32,
        yHotspot: u32,
        hbmMask: ?*anyopaque,
        hbmColor: ?*anyopaque,
    };

    const POINT = extern struct { x: i32, y: i32 };

    const WNDCLASSEXW = extern struct {
        cbSize: u32,
        style: u32,
        lpfnWndProc: ?*const fn (?*anyopaque, u32, usize, isize) callconv(.winapi) isize,
        cbClsExtra: c_int,
        cbWndExtra: c_int,
        hInstance: ?*anyopaque,
        hIcon: ?*anyopaque,
        hCursor: ?*anyopaque,
        hbrBackground: ?*anyopaque,
        lpszMenuName: ?[*:0]const u16,
        lpszClassName: ?[*:0]const u16,
        hIconSm: ?*anyopaque,
    };

    const NOTIFYICONDATAW = extern struct {
        cbSize: u32,
        hWnd: ?*anyopaque,
        uID: u32,
        uFlags: u32,
        uCallbackMessage: u32,
        hIcon: ?*anyopaque,
        szTip: [128]u16,
        dwState: u32,
        dwStateMask: u32,
        szInfo: [256]u16,
        uTimeoutOrVersion: u32,
        szInfoTitle: [64]u16,
        dwInfoFlags: u32,
        guidItem: [16]u8,
        hBalloonIcon: ?*anyopaque,
    };

    extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "gdi32" fn CreateDIBSection(hdc: ?*anyopaque, pbmi: *const BITMAPINFO, usage: u32, ppvBits: ?*?*anyopaque, hSection: ?*anyopaque, offset: u32) callconv(.winapi) ?*anyopaque;
    extern "gdi32" fn DeleteObject(ho: ?*anyopaque) callconv(.winapi) i32;
    extern "user32" fn CreateIconIndirect(piconinfo: *const ICONINFO) callconv(.winapi) ?*anyopaque;
    extern "user32" fn DestroyIcon(hIcon: ?*anyopaque) callconv(.winapi) i32;
    extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) u16;
    extern "user32" fn CreateWindowExW(
        dwExStyle: u32,
        lpClassName: [*:0]const u16,
        lpWindowName: [*:0]const u16,
        dwStyle: u32,
        x: c_int,
        y: c_int,
        nWidth: c_int,
        nHeight: c_int,
        hWndParent: ?*anyopaque,
        hMenu: ?*anyopaque,
        hInstance: ?*anyopaque,
        lpParam: ?*anyopaque,
    ) callconv(.winapi) ?*anyopaque;
    extern "user32" fn DefWindowProcW(hWnd: ?*anyopaque, msg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize;
    extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?*anyopaque, wMsgFilterMin: u32, wMsgFilterMax: u32) callconv(.winapi) c_int;
    extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) i32;
    extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) isize;
    extern "user32" fn PostQuitMessage(nExitCode: c_int) callconv(.winapi) void;
    extern "user32" fn LoadIconW(hInstance: ?*anyopaque, lpIconName: usize) callconv(.winapi) ?*anyopaque;
    extern "user32" fn CreatePopupMenu() callconv(.winapi) ?*anyopaque;
    extern "user32" fn AppendMenuW(hMenu: ?*anyopaque, uFlags: u32, uIDNewItem: usize, lpNewItem: [*:0]const u16) callconv(.winapi) i32;
    extern "user32" fn TrackPopupMenu(hMenu: ?*anyopaque, uFlags: u32, x: c_int, y: c_int, nReserved: c_int, hWnd: ?*anyopaque, prcRect: ?*anyopaque) callconv(.winapi) i32;
    extern "user32" fn DestroyMenu(hMenu: ?*anyopaque) callconv(.winapi) i32;
    extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) i32;
    extern "shell32" fn Shell_NotifyIconW(dwMessage: u32, lpData: *const NOTIFYICONDATAW) callconv(.winapi) i32;

    var g_self: ?*Tray = null;
    var g_hwnd: ?*anyopaque = null;
    var g_class_name: [64]u16 = undefined;
    var g_nid: NOTIFYICONDATAW = undefined;
    var g_custom_icon: bool = false;

    fn createBarcodeIcon() ?*anyopaque {
        const icon = @import("icon.zig");
        const size: i32 = 24;
        var bgra: [24 * 24 * 4]u8 = undefined;
        icon.barcodeBgra(&bgra, 24, icon.white);
        var bi = std.mem.zeroes(BITMAPINFO);
        bi.bmiHeader.biSize = @sizeOf(BITMAPINFOHEADER);
        bi.bmiHeader.biWidth = size;
        bi.bmiHeader.biHeight = -size;
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 32;
        bi.bmiHeader.biCompression = 0;
        var bits: ?*anyopaque = null;
        const hbm = CreateDIBSection(null, &bi, 0, &bits, null, 0) orelse return null;
        if (bits) |raw| {
            @memcpy(@as([*]u8, @ptrCast(raw))[0..bgra.len], &bgra);
        }
        const info = ICONINFO{ .fIcon = 1, .xHotspot = 0, .yHotspot = 0, .hbmMask = null, .hbmColor = hbm };
        const hicon = CreateIconIndirect(&info);
        _ = DeleteObject(hbm);
        return hicon;
    }

    fn wstr(buf: []u16, s: []const u8) [*:0]const u16 {
        const n = std.unicode.utf8ToUtf16Le(buf, s) catch 0;
        buf[n] = 0;
        return buf[0..n :0];
    }

    fn trayWndProc(hwnd: ?*anyopaque, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
        switch (msg) {
            WM_TRAYCALLBACK => {
                if (g_self) |t| {
                    switch (lparam) {
                        WM_LBUTTONUP, WM_LBUTTONDBLCLK => t.requestToggle(),
                        WM_RBUTTONUP => showMenu(t),
                        else => {},
                    }
                }
                return 0;
            },
            WM_COMMAND => {
                if (g_self) |t| {
                    const id: u32 = @intCast(wparam & 0xffff);
                    switch (id) {
                        ID_SHOW => t.requestShow(),
                        ID_QUIT => t.requestQuit(),
                        else => {},
                    }
                }
                return 0;
            },
            WM_DESTROY => {
                PostQuitMessage(0);
                return 0;
            },
            else => return DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    fn showMenu(t: *Tray) void {
        const h_menu = CreatePopupMenu() orelse return;
        _ = AppendMenuW(h_menu, MF_STRING, ID_SHOW, wstr(&classBuf, "Mostrar janela"));
        _ = AppendMenuW(h_menu, MF_STRING, ID_QUIT, wstr(&classBuf2, "Sair"));
        var pt: POINT = undefined;
        _ = GetCursorPos(&pt);
        const cmd = TrackPopupMenu(h_menu, TPM_RIGHTBUTTON | TPM_RETURNCMD, pt.x, pt.y, 0, g_hwnd, null);
        _ = DestroyMenu(h_menu);
        switch (cmd) {
            1 => t.requestShow(),
            2 => t.requestQuit(),
            else => {},
        }
    }

    var classBuf: [128]u16 = undefined;
    var classBuf2: [128]u16 = undefined;

    fn init(self: *Tray) !void {
        g_self = self;
        const h_instance = GetModuleHandleW(null) orelse return error.NoInstance;
        const class_z = wstr(&g_class_name, "XeMonitorTrayWnd");

        const wc = WNDCLASSEXW{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = trayWndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = h_instance,
            .hIcon = LoadIconW(null, IDI_APPLICATION),
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_z,
            .hIconSm = null,
        };
        _ = RegisterClassExW(&wc);

        g_hwnd = CreateWindowExW(
            0,
            class_z,
            wstr(&classBuf, "XeMonitor"),
            0,
            0,
            0,
            0,
            0,
            HWND_MESSAGE,
            null,
            h_instance,
            null,
        ) orelse return error.NoWindow;

        g_nid = std.mem.zeroes(NOTIFYICONDATAW);
        g_nid.cbSize = @sizeOf(NOTIFYICONDATAW);
        g_nid.hWnd = g_hwnd;
        g_nid.uID = 1;
        g_nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
        g_nid.uCallbackMessage = WM_TRAYCALLBACK;
        g_nid.hIcon = if (createBarcodeIcon()) |hi| blk: {
            g_custom_icon = true;
            break :blk hi;
        } else LoadIconW(null, IDI_APPLICATION);
        const tip = wstr(&classBuf, "XeMonitor");
        @memcpy(g_nid.szTip[0..tip.len], tip[0..tip.len]);
        _ = Shell_NotifyIconW(NIM_ADD, &g_nid);
    }

    fn deinit() void {
        if (g_nid.hWnd != null) _ = Shell_NotifyIconW(NIM_DELETE, &g_nid);
        if (g_custom_icon and g_nid.hIcon != null) _ = DestroyIcon(g_nid.hIcon);
        g_nid.hWnd = null;
    }
} else struct {};
const linux = if (os == .linux) struct {
    const c = @cImport({
        @cInclude("dbus/dbus.h");
    });
    const icon = @import("icon.zig");

    const item_path = "/StatusNotifierItem";
    const menu_path = "/Menu";

    const item_iface = "org.kde.StatusNotifierItem";
    const props_iface = "org.freedesktop.DBus.Properties";
    const menu_iface = "com.canonical.dbusmenu";

    const ICON_PIX_SIZE: i32 = 24;
    var g_icon_argb: [ICON_PIX_SIZE * ICON_PIX_SIZE * 4]u8 = undefined;
    var g_icon_dark: bool = true;

    const MENU_SHOW: i32 = 1;
    const MENU_QUIT: i32 = 2;

    const ErrBuf = struct {
        bytes: [64]u8 align(8) = undefined,
        fn ptr(self: *ErrBuf) *c.DBusError {
            return @ptrCast(@alignCast(&self.bytes));
        }
    };

    var g_tray: ?*Tray = null;
    var g_conn: ?*c.DBusConnection = null;

    fn appendBasic(iter: *c.DBusMessageIter, comptime t: c_int, value: anytype) void {
        _ = c.dbus_message_iter_append_basic(iter, t, @ptrCast(&value));
    }

    fn getBasicStr(iter: *c.DBusMessageIter) [*:0]const u8 {
        var p: ?*anyopaque = null;
        c.dbus_message_iter_get_basic(iter, @ptrCast(&p));
        return @ptrCast(@alignCast(p));
    }

    fn registerObject(path: []const u8) bool {
        const conn = g_conn orelse return false;
        var err_buf = ErrBuf{};
        const err = err_buf.ptr();
        c.dbus_error_init(err);
        const path_z: [*:0]const u8 = @ptrCast(@alignCast(path.ptr));
        const ok = c.dbus_connection_try_register_object_path(conn, path_z, &g_vtable, null, err);
        c.dbus_error_free(err);
        return ok != 0;
    }

    fn sendReply(conn: ?*c.DBusConnection, msg: ?*c.DBusMessage) void {
        const reply = c.dbus_message_new_method_return(msg) orelse return;
        _ = c.dbus_connection_send(conn, reply, null);
        c.dbus_message_unref(reply);
    }

    fn redrawIcon() void {
        icon.barcodeArgb(&g_icon_argb, @intCast(ICON_PIX_SIZE), if (g_icon_dark) icon.white else icon.black);
    }

    // Consulta o esquema de cores via xdg-desktop-portal.
    // Retorna true (escuro) em qualquer falha/desconhecido (padrão seguro p/ tema escuro).
    fn queryDarkScheme() bool {
        const conn = g_conn orelse return true;
        const call = c.dbus_message_new_method_call(
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.Settings",
            "Read",
        ) orelse return true;
        defer c.dbus_message_unref(call);
        var iter: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(call, &iter);
        appendBasic(&iter, c.DBUS_TYPE_STRING, "org.freedesktop.appearance");
        appendBasic(&iter, c.DBUS_TYPE_STRING, "color-scheme");
        var err_buf = ErrBuf{};
        const err = err_buf.ptr();
        c.dbus_error_init(err);
        const reply = c.dbus_connection_send_with_reply_and_block(conn, call, 1000, err);
        if (reply == null) {
            c.dbus_error_free(err);
            return true;
        }
        defer c.dbus_message_unref(reply);
        var a: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_init(reply, &a) == 0) return true;
        var b: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_get_arg_type(&a) != c.DBUS_TYPE_VARIANT) return true;
        c.dbus_message_iter_recurse(&a, &b);
        if (c.dbus_message_iter_get_arg_type(&b) != c.DBUS_TYPE_VARIANT) return true;
        var v: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&b, &v);
        if (c.dbus_message_iter_get_arg_type(&v) != c.DBUS_TYPE_UINT32) return true;
        var val: u32 = 1;
        c.dbus_message_iter_get_basic(&v, @ptrCast(&val));
        return val != 2; // 0/1 = escuro/desconhecido, 2 = claro
    }

    fn replyIntrospect(conn: ?*c.DBusConnection, msg: ?*c.DBusMessage, xml: []const u8) void {
        const reply = c.dbus_message_new_method_return(msg) orelse return;
        var iter: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &iter);
        const z: [*:0]const u8 = @ptrCast(@alignCast(xml.ptr));
        appendBasic(&iter, c.DBUS_TYPE_STRING, z);
        _ = c.dbus_connection_send(conn, reply, null);
        c.dbus_message_unref(reply);
    }

    fn appendStringVariant(iter: *c.DBusMessageIter, value: []const u8) void {
        var v: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_open_container(iter, c.DBUS_TYPE_VARIANT, "s", &v) == 0) return;
        const z: [*:0]const u8 = @ptrCast(@alignCast(value.ptr));
        appendBasic(&v, c.DBUS_TYPE_STRING, z);
        _ = c.dbus_message_iter_close_container(iter, &v);
    }

    fn appendBoolVariant(iter: *c.DBusMessageIter, value: i32) void {
        var v: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_open_container(iter, c.DBUS_TYPE_VARIANT, "b", &v) == 0) return;
        appendBasic(&v, c.DBUS_TYPE_BOOLEAN, value);
        _ = c.dbus_message_iter_close_container(iter, &v);
    }

    fn appendObjectPathVariant(iter: *c.DBusMessageIter, path: []const u8) void {
        var v: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_open_container(iter, c.DBUS_TYPE_VARIANT, "o", &v) == 0) return;
        const z: [*:0]const u8 = @ptrCast(@alignCast(path.ptr));
        appendBasic(&v, c.DBUS_TYPE_OBJECT_PATH, z);
        _ = c.dbus_message_iter_close_container(iter, &v);
    }

    fn appendIconPixmapVariant(iter: *c.DBusMessageIter) void {
        var v: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_open_container(iter, c.DBUS_TYPE_VARIANT, "a(iiay)", &v) == 0) return;
        var arr: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_open_container(&v, c.DBUS_TYPE_ARRAY, "(iiay)", &arr) != 0) {
            var st: c.DBusMessageIter = undefined;
            if (c.dbus_message_iter_open_container(&arr, c.DBUS_TYPE_STRUCT, null, &st) != 0) {
                appendBasic(&st, c.DBUS_TYPE_INT32, ICON_PIX_SIZE);
                appendBasic(&st, c.DBUS_TYPE_INT32, ICON_PIX_SIZE);
                var ba: c.DBusMessageIter = undefined;
                if (c.dbus_message_iter_open_container(&st, c.DBUS_TYPE_ARRAY, "y", &ba) != 0) {
                    var ptr: [*]const u8 = &g_icon_argb;
                    _ = c.dbus_message_iter_append_fixed_array(&ba, c.DBUS_TYPE_BYTE, @ptrCast(&ptr), g_icon_argb.len);
                    _ = c.dbus_message_iter_close_container(&st, &ba);
                }
                _ = c.dbus_message_iter_close_container(&arr, &st);
            }
            _ = c.dbus_message_iter_close_container(&v, &arr);
        }
        _ = c.dbus_message_iter_close_container(iter, &v);
    }

    fn appendStringDictEntry(dict: *c.DBusMessageIter, key: []const u8, value: []const u8) void {
        var entry: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_open_container(dict, c.DBUS_TYPE_DICT_ENTRY, null, &entry) == 0) return;
        appendBasic(&entry, c.DBUS_TYPE_STRING, @as([*:0]const u8, @ptrCast(@alignCast(key.ptr))));
        appendStringVariant(&entry, value);
        _ = c.dbus_message_iter_close_container(dict, &entry);
    }

    fn appendSniProperties(iter: *c.DBusMessageIter, all: bool) void {
        var dict: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_open_container(iter, c.DBUS_TYPE_ARRAY, "{sv}", &dict) == 0) return;

        if (all) {
            appendStringDictEntry(&dict, "Category", "Application");
            appendStringDictEntry(&dict, "Id", "xemonitor");
            appendStringDictEntry(&dict, "Title", "XeMonitor");
            appendStringDictEntry(&dict, "Status", "Active");
            // Nome intencionalmente nao-resolvivel: forca o host a usar o IconPixmap
            // dinamico (cor = tema claro/escuro), em vez do SVG instalado no hicolor.
            appendStringDictEntry(&dict, "IconName", "xemonitor-tray");
        }

        var entry: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_open_container(&dict, c.DBUS_TYPE_DICT_ENTRY, null, &entry) != 0) {
            appendBasic(&entry, c.DBUS_TYPE_STRING, @as([*:0]const u8, @ptrCast(@alignCast("ItemIsMenu".ptr))));
            appendBoolVariant(&entry, 0);
            _ = c.dbus_message_iter_close_container(&dict, &entry);
        }
        if (c.dbus_message_iter_open_container(&dict, c.DBUS_TYPE_DICT_ENTRY, null, &entry) != 0) {
            appendBasic(&entry, c.DBUS_TYPE_STRING, @as([*:0]const u8, @ptrCast(@alignCast("Menu".ptr))));
            appendObjectPathVariant(&entry, menu_path);
            _ = c.dbus_message_iter_close_container(&dict, &entry);
        }
        if (c.dbus_message_iter_open_container(&dict, c.DBUS_TYPE_DICT_ENTRY, null, &entry) != 0) {
            appendBasic(&entry, c.DBUS_TYPE_STRING, @as([*:0]const u8, @ptrCast(@alignCast("IconPixmap".ptr))));
            appendIconPixmapVariant(&entry);
            _ = c.dbus_message_iter_close_container(&dict, &entry);
        }

        _ = c.dbus_message_iter_close_container(iter, &dict);
    }

    fn handleProps(conn: ?*c.DBusConnection, msg: ?*c.DBusMessage, t: *Tray) void {
        _ = t;
        const member = std.mem.span(c.dbus_message_get_member(msg));
        if (std.mem.eql(u8, member, "Get")) {
            var iter: c.DBusMessageIter = undefined;
            _ = c.dbus_message_iter_init(msg, &iter);
            _ = getBasicStr(&iter);
            _ = c.dbus_message_iter_next(&iter);
            const p = std.mem.span(getBasicStr(&iter));
            const reply = c.dbus_message_new_method_return(msg) orelse return;
            var riter: c.DBusMessageIter = undefined;
            c.dbus_message_iter_init_append(reply, &riter);
            if (std.mem.eql(u8, p, "ItemIsMenu")) {
                appendBoolVariant(&riter, 0);
            } else if (std.mem.eql(u8, p, "Menu")) {
                appendObjectPathVariant(&riter, menu_path);
            } else if (std.mem.eql(u8, p, "IconPixmap")) {
                appendIconPixmapVariant(&riter);
            } else {
                const val: []const u8 = blk: {
                    if (std.mem.eql(u8, p, "Category")) break :blk "Application";
                    if (std.mem.eql(u8, p, "Id")) break :blk "xemonitor";
                    if (std.mem.eql(u8, p, "Title")) break :blk "XeMonitor";
                    if (std.mem.eql(u8, p, "Status")) break :blk "Active";
                    if (std.mem.eql(u8, p, "IconName")) break :blk "xemonitor-tray";
                    break :blk "";
                };
                appendStringVariant(&riter, val);
            }
            _ = c.dbus_connection_send(conn, reply, null);
            c.dbus_message_unref(reply);
        } else if (std.mem.eql(u8, member, "GetAll")) {
            const reply = c.dbus_message_new_method_return(msg) orelse return;
            var riter: c.DBusMessageIter = undefined;
            c.dbus_message_iter_init_append(reply, &riter);
            appendSniProperties(&riter, true);
            _ = c.dbus_connection_send(conn, reply, null);
            c.dbus_message_unref(reply);
        }
    }

    fn appendMenuItem(iter: *c.DBusMessageIter, id: i32, label: []const u8, children: []const struct { id: i32, label: []const u8 }) void {
        var item: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_open_container(iter, c.DBUS_TYPE_STRUCT, null, &item) == 0) return;
        appendBasic(&item, c.DBUS_TYPE_INT32, id);

        var dict: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_open_container(&item, c.DBUS_TYPE_ARRAY, "{sv}", &dict) != 0) {
            appendStringDictEntry(&dict, "label", label);
            _ = c.dbus_message_iter_close_container(&item, &dict);
        }

        var arr: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_open_container(&item, c.DBUS_TYPE_ARRAY, "v", &arr) != 0) {
            for (children) |ch| {
                var v: c.DBusMessageIter = undefined;
                if (c.dbus_message_iter_open_container(&arr, c.DBUS_TYPE_VARIANT, "(ia{sv}av)", &v) == 0) continue;
                appendMenuItem(&v, ch.id, ch.label, &.{});
                _ = c.dbus_message_iter_close_container(&arr, &v);
            }
            _ = c.dbus_message_iter_close_container(&item, &arr);
        }

        _ = c.dbus_message_iter_close_container(iter, &item);
    }

    fn handleMenuGetLayout(conn: ?*c.DBusConnection, msg: ?*c.DBusMessage) void {
        const reply = c.dbus_message_new_method_return(msg) orelse return;
        var riter: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &riter);
        const revision: u32 = 1;
        appendBasic(&riter, c.DBUS_TYPE_UINT32, revision);
        appendMenuItem(&riter, 0, "XeMonitor", &.{
            .{ .id = MENU_SHOW, .label = "Mostrar janela" },
            .{ .id = MENU_QUIT, .label = "Sair" },
        });
        _ = c.dbus_connection_send(conn, reply, null);
        c.dbus_message_unref(reply);
    }

    fn handleMenuEvent(conn: ?*c.DBusConnection, msg: ?*c.DBusMessage, t: *Tray) void {
        var iter: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_init(msg, &iter);
        var id: i32 = 0;
        c.dbus_message_iter_get_basic(&iter, @ptrCast(&id));
        _ = c.dbus_message_iter_next(&iter);
        const event_id = std.mem.span(getBasicStr(&iter));
        if (std.mem.eql(u8, event_id, "clicked")) {
            if (id == MENU_SHOW) t.requestShow();
            if (id == MENU_QUIT) t.requestQuit();
        }
        sendReply(conn, msg);
    }

    fn handleMenu(conn: ?*c.DBusConnection, msg: ?*c.DBusMessage, t: *Tray) void {
        const member = std.mem.span(c.dbus_message_get_member(msg));
        if (std.mem.eql(u8, member, "GetLayout")) {
            handleMenuGetLayout(conn, msg);
        } else if (std.mem.eql(u8, member, "AboutToShow")) {
            const reply = c.dbus_message_new_method_return(msg) orelse return;
            var riter: c.DBusMessageIter = undefined;
            c.dbus_message_iter_init_append(reply, &riter);
            const need: i32 = 0;
            appendBasic(&riter, c.DBUS_TYPE_BOOLEAN, need);
            _ = c.dbus_connection_send(conn, reply, null);
            c.dbus_message_unref(reply);
        } else if (std.mem.eql(u8, member, "GetGroupProperties") or std.mem.eql(u8, member, "GetProperty")) {
            const reply = c.dbus_message_new_method_return(msg) orelse return;
            var riter: c.DBusMessageIter = undefined;
            c.dbus_message_iter_init_append(reply, &riter);
            var arr: c.DBusMessageIter = undefined;
            if (c.dbus_message_iter_open_container(&riter, c.DBUS_TYPE_ARRAY, "(ia{sv})", &arr) != 0) {
                _ = c.dbus_message_iter_close_container(&riter, &arr);
            }
            _ = c.dbus_connection_send(conn, reply, null);
            c.dbus_message_unref(reply);
        } else if (std.mem.eql(u8, member, "Event")) {
            handleMenuEvent(conn, msg, t);
        } else {
            sendReply(conn, msg);
        }
    }

    const sni_introspect =
        \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
        \\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
        \\<node>
        \\  <interface name="org.freedesktop.DBus.Introspectable">
        \\    <method name="Introspect"><arg name="xml" type="s" direction="out"/></method>
        \\  </interface>
        \\  <interface name="org.freedesktop.DBus.Properties">
        \\    <method name="Get"><arg name="interface" type="s" direction="in"/><arg name="property" type="s" direction="in"/><arg name="value" type="v" direction="out"/></method>
        \\    <method name="GetAll"><arg name="interface" type="s" direction="in"/><arg name="properties" type="a{sv}" direction="out"/></method>
        \\  </interface>
        \\  <interface name="org.kde.StatusNotifierItem">
        \\    <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
        \\    <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
        \\    <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
        \\  </interface>
        \\</node>
        \\
    ;

    const menu_introspect =
        \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
        \\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
        \\<node>
        \\  <interface name="org.freedesktop.DBus.Introspectable">
        \\    <method name="Introspect"><arg name="xml" type="s" direction="out"/></method>
        \\  </interface>
        \\  <interface name="com.canonical.dbusmenu">
        \\    <method name="GetLayout"><arg name="parentId" type="i" direction="in"/><arg name="recursionDepth" type="i" direction="in"/><arg name="propertyNames" type="as" direction="in"/><arg name="revision" type="u" direction="out"/><arg name="layout" type="(ia{sv}av)" direction="out"/></method>
        \\    <method name="GetGroupProperties"><arg name="ids" type="ai" direction="in"/><arg name="propertyNames" type="as" direction="in"/><arg name="properties" type="a(ia{sv})" direction="out"/></method>
        \\    <method name="GetProperty"><arg name="id" type="i" direction="in"/><arg name="name" type="s" direction="in"/><arg name="value" type="v" direction="out"/></method>
        \\    <method name="AboutToShow"><arg name="id" type="i" direction="in"/><arg name="needUpdate" type="b" direction="out"/></method>
        \\    <method name="Event"><arg name="id" type="i" direction="in"/><arg name="eventId" type="s" direction="in"/><arg name="data" type="v" direction="in"/><arg name="timestamp" type="u" direction="in"/></method>
        \\  </interface>
        \\</node>
        \\
    ;

    fn handleMessage(conn: ?*c.DBusConnection, msg: ?*c.DBusMessage, userdata: ?*anyopaque) callconv(.c) c.DBusHandlerResult {
        _ = userdata;
        const m = msg orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        const t = g_tray orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        const path = std.mem.span(c.dbus_message_get_path(m));
        const iface = std.mem.span(c.dbus_message_get_interface(m));
        const member = std.mem.span(c.dbus_message_get_member(m));

        if (std.mem.eql(u8, path, item_path) and std.mem.eql(u8, member, "Introspect")) {
            replyIntrospect(conn, m, sni_introspect);
            return c.DBUS_HANDLER_RESULT_HANDLED;
        }
        if (std.mem.eql(u8, path, item_path) and std.mem.eql(u8, iface, props_iface)) {
            handleProps(conn, m, t);
            return c.DBUS_HANDLER_RESULT_HANDLED;
        }
        if (std.mem.eql(u8, path, item_path) and std.mem.eql(u8, iface, item_iface) and std.mem.eql(u8, member, "Activate")) {
            t.requestToggle();
            sendReply(conn, m);
            return c.DBUS_HANDLER_RESULT_HANDLED;
        }
        if (std.mem.eql(u8, path, menu_path) and std.mem.eql(u8, member, "Introspect")) {
            replyIntrospect(conn, m, menu_introspect);
            return c.DBUS_HANDLER_RESULT_HANDLED;
        }
        if (std.mem.eql(u8, path, menu_path) and std.mem.eql(u8, iface, menu_iface)) {
            handleMenu(conn, m, t);
            return c.DBUS_HANDLER_RESULT_HANDLED;
        }
        return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    const g_vtable = c.DBusObjectPathVTable{
        .unregister_function = null,
        .message_function = handleMessage,
        .dbus_internal_pad1 = null,
        .dbus_internal_pad2 = null,
        .dbus_internal_pad3 = null,
        .dbus_internal_pad4 = null,
    };

    pub fn run(self: *Tray) void {
        g_tray = self;
        redrawIcon();
        var err_buf = ErrBuf{};
        const err = err_buf.ptr();
        c.dbus_error_init(err);
        const conn = c.dbus_bus_get(c.DBUS_BUS_SESSION, err) orelse {
            c.dbus_error_free(err);
            return;
        };
        g_conn = conn;
        c.dbus_connection_set_exit_on_disconnect(conn, 0);

        var name_buf: [128]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "org.kde.StatusNotifierItem-{d}-1", .{std.os.linux.getpid()}) catch return;
        name_buf[name.len] = 0;
        const name_z: [*:0]const u8 = @ptrCast(@alignCast(name.ptr));
        _ = c.dbus_bus_request_name(conn, name_z, 0, err);
        c.dbus_error_free(err);

        g_icon_dark = queryDarkScheme();
        redrawIcon();

        _ = registerObject(item_path);
        _ = registerObject(menu_path);

        const call = c.dbus_message_new_method_call("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem") orelse {
            c.dbus_connection_unref(conn);
            g_conn = null;
            return;
        };
        var iter: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(call, &iter);
        appendBasic(&iter, c.DBUS_TYPE_STRING, name_z);
        _ = c.dbus_connection_send(conn, call, null);
        c.dbus_message_unref(call);

        var ticks: u32 = 0;
        while (!self.stop_flag.load(.seq_cst)) {
            ticks +%= 1;
            if (ticks % 25 == 0) { // ~5s (dispatch timeout = 200ms)
                const dark = queryDarkScheme();
                if (dark != g_icon_dark) {
                    g_icon_dark = dark;
                    redrawIcon();
                }
            }
            _ = c.dbus_connection_read_write_dispatch(conn, 200);
        }

        c.dbus_connection_unref(conn);
        g_conn = null;
    }
} else struct {};
