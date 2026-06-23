const std = @import("std");

pub fn main(init: std.process.Init) !void {
    // Phase 6 wires up real argv parsing, root resolution, dispatch, and render.
    // For Phase 1 this is a placeholder so the executable links.
    const io = init.io;
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;
    try w.writeAll("skill-importer: CLI not yet wired (Phase 6)\n");
    try w.flush();
}
