const std = @import("std");
const flate = std.compress.flate;

/// PNG embeddado do icone do app (512x512 RGBA8, sem interlace).
/// Trocar este arquivo reflete no build (bandeja + janela).
/// Referenciado por nome de modulo: o build.zig registra o arquivo como
/// anonymous import "barcode_png" (evita o erro de package path do @embedFile
/// para arquivos fora de src/).
pub const source = @embedFile("barcode_png");

const Signature = [8]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };

fn readU32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .big);
}

/// Cabecalho IHDR parseado em tempo de compilacao (dimensoes do icone).
const Header = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    interlace: u8,
};

const header: Header = blk: {
    if (!std.mem.eql(u8, source[0..8], &Signature)) @compileError("Barcode Scanner.png: assinatura PNG invalida");
    const len = readU32(source[8..12]);
    if (!std.mem.eql(u8, source[12..16], "IHDR")) @compileError("Barcode Scanner.png: esperava IHDR primeiro");
    if (len < 13) @compileError("Barcode Scanner.png: IHDR curto demais");
    break :blk .{
        .width = readU32(source[16..20]),
        .height = readU32(source[20..24]),
        .bit_depth = source[24],
        .color_type = source[25],
        .interlace = source[28],
    };
};

pub const width: u32 = header.width;
pub const height: u32 = header.height;

const row_bytes = @as(usize, header.width) * 4;

var g_idat: [source.len]u8 = undefined;
var g_flate_buf: [flate.max_window_len]u8 = undefined;
var g_prev_buf: [row_bytes]u8 = [_]u8{0} ** row_bytes;
var g_rgba: [row_bytes * @as(usize, header.height)]u8 = undefined;

var g_mutex: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn ensure() void {
    if (g_mutex.load(.acquire)) return;
    const ok = decodeOnce();
    g_mutex.store(ok, .release);
}

/// Retorna os pixels RGBA8 (width*height*4). Vazio se o decode falhar.
pub fn rgba() []const u8 {
    ensure();
    if (!g_mutex.load(.acquire)) return &[_]u8{};
    return g_rgba[0 .. row_bytes * @as(usize, header.height)];
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn unfilterRow(f: u8, raw: []const u8, prev: []const u8, out: []u8) void {
    const bpp: usize = 4;
    var x: usize = 0;
    while (x < raw.len) : (x += 1) {
        const rawb = raw[x];
        const left = if (x >= bpp) out[x - bpp] else 0;
        const up = prev[x];
        const up_left = if (x >= bpp) prev[x - bpp] else 0;
        const recon: u8 = switch (f) {
            0 => rawb,
            1 => rawb +% left,
            2 => rawb +% up,
            3 => rawb +% @as(u8, @intCast(@divTrunc(@as(u16, left) + up, 2))),
            4 => rawb +% paeth(left, up, up_left),
            else => return,
        };
        out[x] = recon;
    }
}

fn decodeOnce() bool {
    const s = source;
    if (s.len < 8) return false;
    if (!std.mem.eql(u8, s[0..8], &Signature)) return false;

    var pos: usize = 8;
    var ihdr_ok = false;
    var w: u32 = 0;
    var h: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var interlace: u8 = 0;
    var idat_len: usize = 0;

    while (pos + 8 <= s.len) {
        const len = std.mem.readInt(u32, s[pos..][0..4], .big);
        const ctype = s[pos + 4 ..][0..4];
        if (pos + 12 + len > s.len) return false;
        if (std.mem.eql(u8, ctype, "IHDR")) {
            if (len < 13) return false;
            w = readU32(s[pos + 8 ..][0..4]);
            h = readU32(s[pos + 12 ..][0..4]);
            bit_depth = s[pos + 16];
            color_type = s[pos + 17];
            interlace = s[pos + 20];
            ihdr_ok = true;
        } else if (std.mem.eql(u8, ctype, "IDAT")) {
            if (idat_len + len > g_idat.len) return false;
            @memcpy(g_idat[idat_len..][0..len], s[pos + 8 ..][0..len]);
            idat_len += len;
        } else if (std.mem.eql(u8, ctype, "IEND")) {
            break;
        }
        pos += 12 + len;
    }
    if (!ihdr_ok) return false;
    if (bit_depth != 8 or color_type != 6 or interlace != 0) return false;
    if (w != header.width or h != header.height) return false;
    if (idat_len == 0) return false;

    var in: std.Io.Reader = .fixed(g_idat[0..idat_len]);
    var decomp = flate.Decompress.init(&in, .zlib, &g_flate_buf);
    const r = &decomp.reader;

    @memset(g_prev_buf[0..row_bytes], 0);
    var y: usize = 0;
    while (y < header.height) : (y += 1) {
        var fbyte: [1]u8 = undefined;
        r.readSliceAll(&fbyte) catch return false;
        var raw_row: [row_bytes]u8 = undefined;
        r.readSliceAll(&raw_row) catch return false;
        const out = g_rgba[y * row_bytes ..][0..row_bytes];
        unfilterRow(fbyte[0], &raw_row, g_prev_buf[0..row_bytes], out);
        @memcpy(g_prev_buf[0..row_bytes], out);
    }
    return true;
}

/// Ordem dos canais de saida do downscale.
pub const Order = enum { rgba, bgra, argb };

/// Redimensiona (box filter) RGBA8 de `src` para `dst`, escrevendo na ordem
/// de canais escolhida. Tamanhos: dst deve ter dw*dh*4 bytes.
pub fn resize(src: []const u8, sw: u32, sh: u32, dst: []u8, dw: u32, dh: u32, order: Order) void {
    std.debug.assert(src.len >= @as(usize, sw) * sh * 4);
    std.debug.assert(dst.len >= @as(usize, dw) * dh * 4);

    var dy: u32 = 0;
    while (dy < dh) : (dy += 1) {
        const y0 = dy * sh / dh;
        const y1 = (dy + 1) * sh / dh;
        var dx: u32 = 0;
        while (dx < dw) : (dx += 1) {
            const x0 = dx * sw / dw;
            const x1 = (dx + 1) * sw / dw;
            var acc = [4]u32{ 0, 0, 0, 0 };
            var cnt: u32 = 0;
            var sy = y0;
            while (sy < y1) : (sy += 1) {
                var sx = x0;
                while (sx < x1) : (sx += 1) {
                    const p = (@as(usize, sy) * sw + sx) * 4;
                    acc[0] += src[p];
                    acc[1] += src[p + 1];
                    acc[2] += src[p + 2];
                    acc[3] += src[p + 3];
                    cnt += 1;
                }
            }
            if (cnt == 0) cnt = 1;
            const r = @as(u8, @intCast(acc[0] / cnt));
            const g = @as(u8, @intCast(acc[1] / cnt));
            const b = @as(u8, @intCast(acc[2] / cnt));
            const a = @as(u8, @intCast(acc[3] / cnt));
            const d = (@as(usize, dy) * dw + dx) * 4;
            switch (order) {
                .rgba => {
                    dst[d] = r;
                    dst[d + 1] = g;
                    dst[d + 2] = b;
                    dst[d + 3] = a;
                },
                .bgra => {
                    dst[d] = b;
                    dst[d + 1] = g;
                    dst[d + 2] = r;
                    dst[d + 3] = a;
                },
                .argb => {
                    dst[d] = a;
                    dst[d + 1] = r;
                    dst[d + 2] = g;
                    dst[d + 3] = b;
                },
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

test "embedded png decodes to RGBA8" {
    const px = rgba();
    try std.testing.expect(px.len == @as(usize, header.width) * header.height * 4);
    try std.testing.expect(header.width == 512);
    try std.testing.expect(header.height == 512);

    // centro do icone deve ser opaco (amarelo/alaranjado)
    const center = px[(@as(usize, 256) * 512 + 256) * 4 ..][0..4];
    try std.testing.expect(center[3] > 200);
    try std.testing.expect(center[0] > 200); // R alto
    try std.testing.expect(center[1] > 100); // G medio-alto

    // borda deve ser transparente
    const corner = px[0..4];
    try std.testing.expect(corner[3] < 128);
}

test "resize preserves order and size" {
    ensure();
    if (!g_mutex.load(.acquire)) return error.SkipZigTest;

    var out24: [24 * 24 * 4]u8 = undefined;
    resize(g_rgba[0 .. row_bytes * @as(usize, header.height)], header.width, header.height, &out24, 24, 24, .rgba);
    try std.testing.expect(out24.len == 24 * 24 * 4);

    var out64: [64 * 64 * 4]u8 = undefined;
    resize(g_rgba[0 .. row_bytes * @as(usize, header.height)], header.width, header.height, &out64, 64, 64, .bgra);
    try std.testing.expect(out64.len == 64 * 64 * 4);
    // BGRA: o 4o byte e alpha (deve ser opaco no centro)
    try std.testing.expect(out64[(32 * 64 + 32) * 4 + 3] > 200);
}
