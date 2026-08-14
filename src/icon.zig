const std = @import("std");

pub const GRID: u32 = 24;

fn fillRect(dst: []u8, size: u32, x0: f32, y0: f32, x1: f32, y1: f32, comptime argb: bool, fg: [3]u8) void {
    const scale: f32 = @as(f32, @floatFromInt(size)) / @as(f32, @floatFromInt(GRID));
    const ix0: i32 = @intFromFloat(@ceil(x0 * scale));
    const iy0: i32 = @intFromFloat(@ceil(y0 * scale));
    const ix1: i32 = @intFromFloat(@floor(x1 * scale));
    const iy1: i32 = @intFromFloat(@floor(y1 * scale));
    const max: i32 = @intCast(size);
    const si: i32 = @intCast(size);
    const a: usize = if (argb) 0 else 3;
    const r: usize = if (argb) 1 else 2;
    const g: usize = if (argb) 2 else 1;
    const b: usize = if (argb) 3 else 0;
    var y: i32 = @max(iy0, 0);
    while (y < @min(iy1, max)) : (y += 1) {
        var x: i32 = @max(ix0, 0);
        while (x < @min(ix1, max)) : (x += 1) {
            const p: usize = @intCast((y * si + x) * 4);
            dst[p + a] = 255;
            dst[p + r] = fg[0];
            dst[p + g] = fg[1];
            dst[p + b] = fg[2];
        }
    }
}

fn renderBarcode(dst: []u8, size: u32, comptime argb: bool, fg: [3]u8) void {
    @memset(dst[0 .. size * size * 4], 0);

    fillRect(dst, size, 4, 10, 6, 14, argb, fg);
    fillRect(dst, size, 9, 10, 11, 14, argb, fg);
    fillRect(dst, size, 13, 10, 15, 14, argb, fg);
    fillRect(dst, size, 18, 10, 20, 14, argb, fg);

    fillRect(dst, size, 3, 4, 5, 8, argb, fg);
    fillRect(dst, size, 4, 3, 8, 5, argb, fg);
    fillRect(dst, size, 19, 4, 21, 8, argb, fg);
    fillRect(dst, size, 16, 3, 20, 5, argb, fg);
    fillRect(dst, size, 3, 16, 5, 20, argb, fg);
    fillRect(dst, size, 4, 19, 8, 21, argb, fg);
    fillRect(dst, size, 19, 16, 21, 20, argb, fg);
    fillRect(dst, size, 16, 19, 20, 21, argb, fg);
}

pub fn barcodeArgb(dst: []u8, size: u32, fg: [3]u8) void {
    std.debug.assert(dst.len >= size * size * 4);
    renderBarcode(dst, size, true, fg);
}

pub fn barcodeBgra(dst: []u8, size: u32, fg: [3]u8) void {
    std.debug.assert(dst.len >= size * size * 4);
    renderBarcode(dst, size, false, fg);
}

pub const white = [3]u8{ 255, 255, 255 };
pub const black = [3]u8{ 0, 0, 0 };
