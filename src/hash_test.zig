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

// Golden for an EMPTY directory (zero regular files): the digest is the SHA-256
// of nothing fed into the hash, i.e. equal to hashString(""), and must be stable
// across runs with the "sha256:" prefix. Independently:
//   printf '' | shasum -a 256
test "hashDirectory: golden over an empty directory (zero regular files)" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();

    try roots.dir().createDirPath(io, "empty-skill");
    var d = try roots.dir().openDir(io, "empty-skill", .{ .iterate = true });
    defer d.close(io);

    const got = try hash.hashDirectory(testing.allocator, io, d);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.startsWith(u8, got, "sha256:"));
    try testing.expectEqualStrings(
        "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        got,
    );
}

// Golden for a tree WITH subdirectories (multiple nesting levels). The digest is
// stable and "sha256:"-prefixed. Fixture (sorted by '/'-normalized relpath):
//   SKILL.md           = "root\n"  (5 bytes)
//   a/one.txt          = "1"       (1 byte)
//   a/b/two.txt        = "22"      (2 bytes)
// Independently computed:
//   printf 'SKILL.md\n5\nroot\na/b/two.txt\n2\n22a/one.txt\n1\n1' | shasum -a 256
test "hashDirectory: golden over a tree with subdirectories is stable" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);

    try fx.writeSupportFile("tree", "SKILL.md", "root\n");
    try fx.writeSupportFile("tree/a", "one.txt", "1");
    try fx.writeSupportFile("tree/a/b", "two.txt", "22");

    var d = try roots.dir().openDir(io, "tree", .{ .iterate = true });
    defer d.close(io);

    const got = try hash.hashDirectory(testing.allocator, io, d);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.startsWith(u8, got, "sha256:"));
    try testing.expectEqualStrings(
        "sha256:4fdf7892bfa51147e1f727d9f72c263125d4daf06078d0c2f7d80c34fd399964",
        got,
    );

    // Re-hashing the same tree yields the identical digest (determinism).
    var d2 = try roots.dir().openDir(io, "tree", .{ .iterate = true });
    defer d2.close(io);
    const got2 = try hash.hashDirectory(testing.allocator, io, d2);
    defer testing.allocator.free(got2);
    try testing.expectEqualStrings(got, got2);
}

// Read-path regression guard for trees WITH subdirectories. hashDirectory must
// READ each file's bytes via the OS-native relative path (the walker entry path
// using path.sep), NOT via the '/'-normalized string it uses for the hash
// ENCODING. On a '\'-separator OS, reading by the normalized "a/b/two.txt" form
// would fail with FileNotFound, while the encoding must still use '/'. This test
// proves that nested files are actually read (their CONTENT is in the digest):
// if the read path used the normalized form on a backslash OS this would error,
// and on any OS, if nested content were silently skipped the two digests below
// would be equal. They must differ because only the nested file's bytes change.
test "hashDirectory: nested file content is read and folded into the digest" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);

    // Two trees with identical structure/paths; only the DEEPLY NESTED file's
    // bytes differ. The digests must differ, which can only happen if the nested
    // file was opened and read (via its OS-native path) rather than skipped or
    // mis-addressed.
    try fx.writeSupportFile("rp1", "SKILL.md", "same");
    try fx.writeSupportFile("rp1/deep/inner", "data.txt", "AAAA");
    var d1 = try roots.dir().openDir(io, "rp1", .{ .iterate = true });
    defer d1.close(io);
    const h1 = try hash.hashDirectory(testing.allocator, io, d1);
    defer testing.allocator.free(h1);

    try fx.writeSupportFile("rp2", "SKILL.md", "same");
    try fx.writeSupportFile("rp2/deep/inner", "data.txt", "BBBB");
    var d2 = try roots.dir().openDir(io, "rp2", .{ .iterate = true });
    defer d2.close(io);
    const h2 = try hash.hashDirectory(testing.allocator, io, d2);
    defer testing.allocator.free(h2);

    try testing.expect(!std.mem.eql(u8, h1, h2));
}

// Repository imports exclude version-control metadata from the content hash so
// the digest is DETERMINISTIC across clones (a real `git clone` leaves a `.git`
// directory whose bytes differ run to run). `hashDirectoryExcludingGit` must
// ignore a top-level `.git` directory's contents entirely: the digest equals the
// digest of the same tree with no `.git` at all, and matches the plain
// `hashDirectory` of the `.git`-free tree.
test "hashDirectoryExcludingGit: ignores a top-level .git directory's contents" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);

    // Tree WITH a .git dir (and some nested git metadata).
    try fx.writeSupportFile("withgit", "SKILL.md", "A\n");
    try fx.writeSupportFile("withgit/.git", "config", "[core]\n");
    try fx.writeSupportFile("withgit/.git/objects", "deadbeef", "blob");
    var dg = try roots.dir().openDir(io, "withgit", .{ .iterate = true });
    defer dg.close(io);
    const hg = try hash.hashDirectoryExcludingGit(testing.allocator, io, dg);
    defer testing.allocator.free(hg);

    // Same tree WITHOUT any .git.
    try fx.writeSupportFile("nogit", "SKILL.md", "A\n");
    var dn = try roots.dir().openDir(io, "nogit", .{ .iterate = true });
    defer dn.close(io);
    const hn = try hash.hashDirectory(testing.allocator, io, dn);
    defer testing.allocator.free(hn);

    try testing.expectEqualStrings(hn, hg);
}

// A `.git` SYMLINK (as a real `git clone` of certain layouts can leave) must NOT
// trip the UnsupportedEntry rejection when excluding git metadata.
test "hashDirectoryExcludingGit: tolerates a .git symlink entry" {
    var roots = try testutil.TmpRoots.init(testing.allocator);
    defer roots.deinit();
    var fx = testutil.Fixtures.init(&roots);

    try fx.writeSupportFile("linkgit", "SKILL.md", "A\n");
    try fx.symlink("elsewhere", "linkgit/.git");
    var d = try roots.dir().openDir(io, "linkgit", .{ .iterate = true });
    defer d.close(io);

    // Plain hashDirectory rejects the symlink...
    try testing.expectError(error.UnsupportedEntry, hash.hashDirectory(testing.allocator, io, d));

    // ...but the git-excluding variant ignores it and hashes only SKILL.md.
    var d2 = try roots.dir().openDir(io, "linkgit", .{ .iterate = true });
    defer d2.close(io);
    const got = try hash.hashDirectoryExcludingGit(testing.allocator, io, d2);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.startsWith(u8, got, "sha256:"));

    // A non-.git symlink is still rejected by the git-excluding variant.
    try fx.symlink("SKILL.md", "linkgit/alias");
    var d3 = try roots.dir().openDir(io, "linkgit", .{ .iterate = true });
    defer d3.close(io);
    try testing.expectError(error.UnsupportedEntry, hash.hashDirectoryExcludingGit(testing.allocator, io, d3));
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
