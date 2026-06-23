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
    // Collect '/'-normalized relative paths of every regular file.
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {},
            .file => {
                const rel = try normalizeSep(gpa, entry.path);
                errdefer gpa.free(rel);
                try paths.append(gpa, rel);
            },
            else => return error.UnsupportedEntry,
        }
    }

    std.mem.sort([]u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var h = Sha256.init(.{});
    var len_buf: [32]u8 = undefined;
    for (paths.items) |rel| {
        const content = try dir.readFileAlloc(io, rel, gpa, .unlimited);
        defer gpa.free(content);
        h.update(rel);
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
