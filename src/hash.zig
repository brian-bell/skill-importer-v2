//! Content hashing (cli-clean-room-spec.md "Import Manifest": content_hash is
//! "sha256:..."; "import path": directory hash "includes supporting files and
//! relative paths").
//!
//! Byte layout is our choice (zig-clean-room-cli.md "Decisions locked in"),
//! locked by goldens in hash_test.zig:
//!   - String hash: SHA-256 over the raw bytes.
//!   - Directory hash: every regular file, addressed by its path RELATIVE to
//!     the root with '/' separators, sorted ascending by relative path, fed into
//!     SHA-256 with NO separator between files as:
//!         <relpath> "\n" <decimal content length> "\n" <content bytes>
//! Both render as "sha256:" + lowercase hex.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Error when a directory contains an entry that is neither a regular file nor
/// a subdirectory (e.g. a symlink) — spec "import path" rejects such entries.
pub const HashError = error{UnsupportedEntry} || std.mem.Allocator.Error || std.Io.Dir.OpenError || std.Io.File.OpenError || std.Io.File.ReadError;

/// SHA-256 of `bytes`, rendered "sha256:<hex>". Caller owns the result.
pub fn hashString(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var h = Sha256.init(.{});
    h.update(bytes);
    return finalize(gpa, &h);
}

/// SHA-256 over a directory's regular files + relative paths, in the locked
/// encoding above. Returns `error.UnsupportedEntry` for any non-file/non-dir
/// entry (spec "import path": "Symlinks and unsupported filesystem entries are
/// rejected."). Caller owns the result.
pub fn hashDirectory(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]u8 {
    return hashDirectoryImpl(gpa, io, dir, false);
}

/// Like `hashDirectory`, but EXCLUDES any version-control metadata: a path whose
/// first component is `.git` (the top-level `.git` directory or symlink a real
/// `git clone` leaves behind), and any `.git` nested deeper, is ignored entirely
/// — neither its presence nor its bytes affect the digest, and a `.git` SYMLINK
/// no longer trips `error.UnsupportedEntry`. This keeps the repository import
/// `content_hash` DETERMINISTIC across clones (the `.git` directory differs run
/// to run). Caller owns the result.
pub fn hashDirectoryExcludingGit(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]u8 {
    return hashDirectoryImpl(gpa, io, dir, true);
}

/// Returns true when the FIRST path component of `rel` (OS-native or '/'
/// separated) is exactly `.git` — i.e. `rel` is the `.git` dir/link itself or
/// lives anywhere under a `.git`.
fn isGitPath(rel: []const u8) bool {
    var i: usize = 0;
    while (i < rel.len and rel[i] != '/' and rel[i] != '\\') : (i += 1) {}
    return std.mem.eql(u8, rel[0..i], ".git");
}

fn hashDirectoryImpl(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, exclude_git: bool) ![]u8 {
    // For each regular file keep TWO forms of its relative path:
    //   - `native`: the walker's OS-native path (using the OS separator) — used
    //     to OPEN/READ the bytes. On '\'-separator OSes this is the only form
    //     the filesystem accepts.
    //   - `normalized`: the same path with '\' rewritten to '/' — used ONLY in
    //     the hash ENCODING so the digest is identical across separators.
    // Reading by `normalized` would break on backslash OSes; keeping them
    // separate fixes that (cli-clean-room-spec.md "import path": directory hash
    // "includes supporting files and relative paths").
    const RelFile = struct { native: []u8, normalized: []u8 };
    var files: std.ArrayList(RelFile) = .empty;
    defer {
        for (files.items) |f| {
            gpa.free(f.native);
            gpa.free(f.normalized);
        }
        files.deinit(gpa);
    }

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        // Version-control metadata is excluded entirely for repository imports:
        // skip `.git` (and anything beneath it) regardless of entry kind, so a
        // `.git` directory's contents do not enter the digest and a `.git`
        // SYMLINK does not trip the UnsupportedEntry rejection below.
        if (exclude_git and isGitPath(entry.path)) continue;
        switch (entry.kind) {
            .directory => {},
            .file => {
                // `entry.path` is invalidated by the next walker step, so dupe.
                const native = try gpa.dupe(u8, entry.path);
                errdefer gpa.free(native);
                const normalized = try normalizeSep(gpa, native);
                errdefer gpa.free(normalized);
                try files.append(gpa, .{ .native = native, .normalized = normalized });
            },
            else => return error.UnsupportedEntry,
        }
    }

    // Sort by the '/'-normalized path so ordering is OS-independent.
    std.mem.sort(RelFile, files.items, {}, struct {
        fn lessThan(_: void, a: RelFile, b: RelFile) bool {
            return std.mem.lessThan(u8, a.normalized, b.normalized);
        }
    }.lessThan);

    var h = Sha256.init(.{});
    var len_buf: [32]u8 = undefined;
    for (files.items) |f| {
        // Read bytes via the OS-native path; encode with the normalized path.
        const content = try dir.readFileAlloc(io, f.native, gpa, .unlimited);
        defer gpa.free(content);
        h.update(f.normalized);
        h.update("\n");
        const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{content.len}) catch unreachable;
        h.update(len_str);
        h.update("\n");
        h.update(content);
    }
    return finalize(gpa, &h);
}

/// Finalize a SHA-256 state into an owned "sha256:<lowercase-hex>" string.
fn finalize(gpa: std.mem.Allocator, h: *Sha256) ![]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(gpa, "sha256:{s}", .{hex});
}

/// Copy `path` replacing any backslash separators with '/', for cross-platform
/// deterministic relative paths. Caller owns the result.
fn normalizeSep(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, path);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}
