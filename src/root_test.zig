//! Test aggregator. `zig build test` only runs `test {}` blocks reachable from
//! the root module, so EVERY `*_test.zig` file must be `@import`ed here or its
//! tests are silently skipped (zig-clean-room-cli.md "Test discovery").
//!
//! (The aggregator was proven to surface failures during Phase 1 by adding a
//! deliberately-failing test here, observing it fail under `zig build test`, then
//! removing it.)

comptime {
    _ = @import("fs_probe_test.zig");
    _ = @import("types.zig");
    _ = @import("result.zig");
    _ = @import("json_out.zig");
    _ = @import("testutil.zig");
    _ = @import("frontmatter_test.zig");
    _ = @import("manifest_test.zig");
    _ = @import("hash_test.zig");
    _ = @import("fsutil_test.zig");
    _ = @import("discovery_test.zig");
    _ = @import("net.zig");
    _ = @import("net_test.zig");
    _ = @import("import.zig");
    _ = @import("import_test.zig");
    _ = @import("git.zig");
    _ = @import("repository.zig");
    _ = @import("repository_test.zig");
    _ = @import("ops.zig");
    _ = @import("ops_test.zig");
    _ = @import("promote_test.zig");
    _ = @import("roots.zig");
    _ = @import("roots_test.zig");
    _ = @import("cli.zig");
    _ = @import("cli_test.zig");
    _ = @import("cli_integration_test.zig");
}
