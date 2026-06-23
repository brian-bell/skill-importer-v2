//! Tests for content hashing (cli-clean-room-spec.md "import path": "The
//! directory content hash includes supporting files and relative paths";
//! "Import Manifest": content_hash is "sha256:..."). The exact byte layout is
//! OUR choice (zig-clean-room-cli.md "Decisions locked in": "byte layout is our
//! choice ... lock it with a Zig-computed golden test") and is fixed here.
//!
//! Locked directory-hash encoding: walk all regular files, take each file's
//! path RELATIVE to the root using '/' separators, sort ascending by relative
//! path, and for each file feed into SHA-256, with NO separator between files:
//!     <relpath> "\n" <decimal content length> "\n" <content bytes>
//! The digest is rendered as "sha256:" + lowercase hex.

const std = @import("std");
const testing = std.testing;
const hash = @import("hash.zig");
const testutil = @import("testutil.zig");
const io = std.testing.io;

// String hash golden, computed independently with `shasum -a 256`.
test "hashString: golden sha256 of \"hello world\"" {
    const got = try hash.hashString(testing.allocator, "hello world");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "sha256:b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9",
        got,
    );
}

test "hashString: golden sha256 of empty input" {
    const got = try hash.hashString(testing.allocator, "");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        got,
    );
}

test "hashString: stable across calls and distinct for distinct inputs" {
    const a1 = try hash.hashString(testing.allocator, "alpha");
    defer testing.allocator.free(a1);
    const a2 = try hash.hashString(testing.allocator, "alpha");
    defer testing.allocator.free(a2);
    const b = try hash.hashString(testing.allocator, "beta");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a1, a2);
    try testing.expect(!std.mem.eql(u8, a1, b));
}

// Directory hash golden. Fixture: SKILL.md = "A\n" (2 bytes), lib/helper.txt =
// "xy" (2 bytes). Independently computed:
//   printf 'SKILL.md\n2\nA\nlib/helper.txt\n2\nxy' | shasum -a 256
test "hashDirectory: golden over supporting files + relative paths" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);

    try fx.writeSupportFile("src-skill", "SKILL.md", "A\n");
    try fx.writeSupportFile("src-skill/lib", "helper.txt", "xy");

    var d = try roots.dir().openDir(io, "src-skill", .{ .iterate = true });
    defer d.close(io);

    const got = try hash.hashDirectory(testing.allocator, io, d);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        "sha256:82687bd3144564977ef7e1fcb4964bcb7d7a58fd5bb34158f5b43866ed50c423",
        got,
    );
}

// Determinism: file-creation order must not affect the digest (we sort by
// relative path before hashing).
test "hashDirectory: order-independent for same content" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);

    // Tree 1: create b then a.
    try fx.writeSupportFile("t1", "b.txt", "BB");
    try fx.writeSupportFile("t1", "a.txt", "AA");
    var d1 = try roots.dir().openDir(io, "t1", .{ .iterate = true });
    defer d1.close(io);
    const h1 = try hash.hashDirectory(testing.allocator, io, d1);
    defer testing.allocator.free(h1);

    // Tree 2: same files, opposite creation order.
    try fx.writeSupportFile("t2", "a.txt", "AA");
    try fx.writeSupportFile("t2", "b.txt", "BB");
    var d2 = try roots.dir().openDir(io, "t2", .{ .iterate = true });
    defer d2.close(io);
    const h2 = try hash.hashDirectory(testing.allocator, io, d2);
    defer testing.allocator.free(h2);

    try testing.expectEqualStrings(h1, h2);
}

// Relative path is part of the hash: moving a file to a subdir changes the digest.
test "hashDirectory: relative path affects the digest" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);

    try fx.writeSupportFile("flat", "x.txt", "data");
    var df = try roots.dir().openDir(io, "flat", .{ .iterate = true });
    defer df.close(io);
    const hf = try hash.hashDirectory(testing.allocator, io, df);
    defer testing.allocator.free(hf);

    try fx.writeSupportFile("nested/sub", "x.txt", "data");
    var dn = try roots.dir().openDir(io, "nested", .{ .iterate = true });
    defer dn.close(io);
    const hn = try hash.hashDirectory(testing.allocator, io, dn);
    defer testing.allocator.free(hn);

    try testing.expect(!std.mem.eql(u8, hf, hn));
}

// spec "import path": "Symlinks and unsupported filesystem entries are
// rejected." The hash treats any non-dir/non-file entry as an error.
test "hashDirectory: errors on a symlink entry" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);

    try fx.writeSupportFile("withlink", "SKILL.md", "x");
    try fx.symlink("SKILL.md", "withlink/alias");
    var d = try roots.dir().openDir(io, "withlink", .{ .iterate = true });
    defer d.close(io);

    try testing.expectError(error.UnsupportedEntry, hash.hashDirectory(testing.allocator, io, d));
}
