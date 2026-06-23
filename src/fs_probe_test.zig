//! Throwaway probe: verifies the Zig 0.16.0 `std.Io.Dir` / `Io`-param fs
//! signatures that the rest of the codebase depends on. Per zig-clean-room-cli.md
//! "Zig 0.16.0 API notes", these changed from 0.15 and must be confirmed against
//! the installed std before building helpers on them.
//!
//! Tests use `std.testing.io` (initialized by the test runner) and
//! `std.testing.tmpDir` so they never touch a real user root.

const std = @import("std");
const testing = std.testing;
const io = std.testing.io;

test "probe: createDirPath + writeFile + readFileAlloc" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    // createDirPath makes nested directories (0.16 replacement for makePath).
    try dir.createDirPath(io, "a/b/c");

    // writeFile creates + writes in one call.
    try dir.writeFile(io, .{ .sub_path = "a/b/c/hello.txt", .data = "world" });

    // readFileAlloc takes io + an Io.Limit.
    const contents = try dir.readFileAlloc(io, "a/b/c/hello.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("world", contents);
}

test "probe: symLink + readLink + statFile no-follow classifies sym_link" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try dir.writeFile(io, .{ .sub_path = "target.txt", .data = "t" });
    try dir.symLink(io, "target.txt", "link", .{});

    // readLink returns the byte length written into the buffer.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try dir.readLink(io, "link", &buf);
    try testing.expectEqualStrings("target.txt", buf[0..n]);

    // statFile with follow_symlinks=false reports the link itself.
    const st = try dir.statFile(io, "link", .{ .follow_symlinks = false });
    try testing.expect(st.kind == .sym_link);

    // Following the link reports the regular file.
    const st_follow = try dir.statFile(io, "link", .{ .follow_symlinks = true });
    try testing.expect(st_follow.kind == .file);
}

test "probe: iterate yields entries with kind, classifying sym_link no-follow" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = tmp.dir;

    try dir.createDirPath(io, "realdir");
    try dir.writeFile(io, .{ .sub_path = "realfile", .data = "x" });
    try dir.symLink(io, "realfile", "alink", .{});

    var saw_dir = false;
    var saw_file = false;
    var saw_link = false;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, "realdir")) {
            try testing.expect(entry.kind == .directory);
            saw_dir = true;
        } else if (std.mem.eql(u8, entry.name, "realfile")) {
            try testing.expect(entry.kind == .file);
            saw_file = true;
        } else if (std.mem.eql(u8, entry.name, "alink")) {
            try testing.expect(entry.kind == .sym_link);
            saw_link = true;
        }
    }
    try testing.expect(saw_dir and saw_file and saw_link);
}

test "probe: deleteTree removes a populated subtree" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try dir.createDirPath(io, "tree/inner");
    try dir.writeFile(io, .{ .sub_path = "tree/inner/f", .data = "z" });
    try dir.deleteTree(io, "tree");

    try testing.expectError(error.FileNotFound, dir.statFile(io, "tree", .{ .follow_symlinks = false }));
}
