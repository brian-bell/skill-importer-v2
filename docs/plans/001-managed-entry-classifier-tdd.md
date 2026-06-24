# Plan A — Deepen the managed-entry classifier (TDD)

**Status:** proposed
**Candidate:** A (Strong) from the 2026-06-23 architecture review
**Glossary:** module / interface / depth / seam / adapter / leverage / locality (see `improve-codebase-architecture/LANGUAGE.md`)

---

## 1. Why

The "is this filesystem entry a managed symlink pointing inside the canonical/imports
roots, accounting for symlinked ancestors, and is it broken?" policy is implemented
**twice**:

- `discovery.zig` → `classifyAgentEntry` + `canonRootOrLexical` + `isInside`
  (produces a `types.AgentEntryStatus`).
- `ops.zig` → `symlinkPointsAt` + `symlinkPointsAtCanon` + `symlinkResolves` +
  `canonOrLexical` + `targetIsDirectory` (produces a safe/unsafe preflight verdict).

The code admits the coupling in comments: *"mirrors the discovery classifier"*
(`ops.zig:397,419`) and *"Resolve the target with the SAME policy as the roots below"*
(`discovery.zig:222`). The two copies **must agree** — a `disable` that removes an entry
discovery would call `imported_symlink`, a broken link that must classify the same way in
both (Findings #8, #9). Today that agreement is maintained by hand, and the policy can
only be tested through whole-operation tests.

**Deletion test:** delete the ops helpers and the duplicated canon/points-at logic —
complexity reappears verbatim in discovery. It is earning its keep; it belongs in one
deep module.

## 2. Goal

A single deep module, `src/managed_entry.zig`, that classifies a path against the roots.
`discovery` and `ops` become thin **adapters** that map its result onto their own
vocabulary. The classifier's interface becomes the **test surface** for filesystem
safety.

Two real adapters already exist (discovery wants a status; ops wants a verdict) → the
seam is real, not hypothetical.

## 3. Proposed interface (refine during implementation)

```zig
//! src/managed_entry.zig
//! One classification of a filesystem path against the managed roots. Concentrates
//! the no-follow classify, the broken-link probe, lexical symlink-target resolution,
//! and the existing-ancestor canonicalization policy that discovery and ops both need.

pub const Classification = union(enum) {
    missing,
    real_directory,
    real_file,
    /// A symlink whose target cannot be resolved end-to-end (dangling / loop /
    /// access-denied through the chain). Distinct from `external` (Finding #9).
    broken_symlink,
    /// A resolvable symlink. `target_canon` is its target, canonicalized through
    /// existing ancestors (so a managed link reached via /tmp->/private/tmp or a
    /// symlinked $HOME is not misclassified).
    symlink: []const u8,
};

/// Classify `link_path` (absolute) WITHOUT following a final symlink, resolving and
/// canonicalizing the target when it is a symlink. All allocations are arena-owned.
pub fn classify(arena: std.mem.Allocator, io: std.Io, link_path: []const u8) !Classification;

/// Canonicalize `path` through existing ancestors, falling back to a lexical resolve
/// for a not-yet-existing path. (The `canonOrLexical` / `canonRootOrLexical` policy.)
pub fn canonicalize(arena: std.mem.Allocator, io: std.Io, path: []const u8) []const u8;

/// True iff `path` is `root` itself or lies strictly inside it (component-aware: a
/// sibling like `<root>-evil` is NOT inside `<root>`).
pub fn isInside(path: []const u8, root: []const u8) bool;
```

Notes:
- `classify` internally uses the existing `fsutil.classify` (no-follow kind),
  `fsutil.resolveLinkTarget` (lexical), and `fsutil.canonicalizeExistingAncestor`.
  Those primitives stay in `fsutil`; `managed_entry` is the policy that composes them.
- `discovery` needs **membership** (`isInside(target, canonical_root)`); `ops` needs
  **specific-target equality** (`mem.eql(target_canon, expected_canon)`). Both are
  trivially expressed from `Classification.symlink` + the two helpers, so one interface
  serves both.
- Keep `fsutil.classify` for the many plain no-follow kind checks elsewhere
  (`promote` dest-exists, `analyze` auth.json, `rootExists`); do not route those through
  `managed_entry`.

## 4. Caller mapping (the adapters)

`discovery.classifyAgentEntry` collapses to a pure mapping:

| `Classification`        | `AgentEntryStatus`                                   |
| ----------------------- | ---------------------------------------------------- |
| `.missing`              | (skip — entry not present)                            |
| `.real_directory`       | `.skill_directory`                                   |
| `.real_file`            | `null` (stray file, skipped)                         |
| `.broken_symlink`       | `.broken_symlink`                                    |
| `.symlink: t`           | `isInside(t, canon)` → `.canonical_symlink`; else `isInside(t, imports)` → `.imported_symlink`; else `.external_symlink` |

`ops` preflight branches map `Classification` onto plan/verdict:
- `enablePlan`, `preflight` (disable), `preflightPromoteAgent`, `executeUnpromote`
  call `managed_entry.classify(link_path)` once and switch on the union, comparing
  `.symlink` targets to `managed_entry.canonicalize(expected_target)`.
- A `.broken_symlink` for a managed link → **unsafe / left untouched** (Finding #8),
  now a single code path.

Deleted from `ops.zig` after migration: `symlinkPointsAt`, `symlinkPointsAtCanon`,
`symlinkResolves`, `canonOrLexical`. Keep `targetIsDirectory` and `rootExists` (they are
follow-stat / no-follow kind checks, not symlink-membership) unless they fall out
naturally.

## 5. TDD sequence (red → green → refactor)

Test-first throughout. Use the `tdd` skill. Each step: write the failing test, watch it
fail with `make test`, make it pass, refactor, re-run `make check`.

### Step 0 — scaffold the seam (red harness)
1. Create `src/managed_entry.zig` with the three signatures, bodies `unreachable`.
2. Create `src/managed_entry_test.zig`.
3. Register both in `src/root_test.zig` (`_ = @import("managed_entry.zig");` and
   `_ = @import("managed_entry_test.zig");`) — **mandatory**, or the tests are silently
   skipped (`root_test.zig` header).
4. `make test` → fails. Harness proven.

### Step 1 — `classify` happy kinds
Build a temp tree with `testutil.TmpRoots` / `Fixtures` (never real roots — CLAUDE.md
hard rule). Tests:
- missing path → `.missing`
- real directory → `.real_directory`
- real file → `.real_file`

Implement `classify` for the non-symlink cases via `fsutil.classify`. Green.

### Step 2 — resolvable symlinks + `isInside` + `canonicalize`
Using `Fixtures.symlink` / `managedSymlink`:
- symlink → dir inside canonical root → `.symlink` whose target `isInside(canonical)`.
- symlink → dir inside imports root → `isInside(imports)`.
- symlink → a path outside all roots → `isInside` false for both (external).
- **sibling-prefix trap:** a symlink to `<canonical>-evil` is NOT inside `<canonical>`
  (locks the component-aware `isInside`; mirrors `analyzer.pathWithin`).
- `canonicalize` of a non-existent path returns the lexically-resolved absolute path.
- `canonicalize` of a path under a symlinked ancestor returns the realpath'd form.

Implement the symlink branch (readLink → `fsutil.resolveLinkTarget` against
`canonicalize(dirname(link_path))` → `canonicalize(target)`). Green.

### Step 3 — broken-link policy (Finding #9)
- dangling symlink (target removed) → `.broken_symlink`, **not** `.symlink`/external.
- symlink loop → `.broken_symlink` (any resolve error ⇒ broken).

Implement the follow-stat resolvability probe before target resolution. Green.
These two tests are the unit-level home for Finding #9, which today only lives in
`discovery_test`.

### Step 4 — migrate `discovery.classifyAgentEntry` (refactor, behavior-preserving)
1. Replace the body with `managed_entry.classify` + the mapping table in §4.
2. Delete `discovery`'s now-unused `canonRootOrLexical`; keep its local `isInside` only
   if still referenced, else delete and use `managed_entry.isInside`.
3. Regression gate: `make test` — `discovery_test.zig` (and `cli_integration_test.zig`)
   pass **unchanged**. They are the behavior-preservation net. No test edits expected.

### Step 5 — migrate `ops` preflight (refactor, behavior-preserving)
Migrate one function at a time, running `make test` after each:
1. `preflight` (disable branch) → `managed_entry.classify`; broken managed link ⇒ unsafe.
2. `enablePlan` → `managed_entry.classify`.
3. `preflightPromoteAgent` → `managed_entry.classify`.
4. `executeUnpromote` symlink check → `managed_entry.classify` + `isInside`/eql.
5. Delete `symlinkPointsAt`, `symlinkPointsAtCanon`, `symlinkResolves`, `canonOrLexical`.

Regression gate: `ops_test.zig` and `promote_test.zig` pass **unchanged** — the existing
unsafe-entry / Finding #8 / Finding #4 cases now flow through the shared classifier.

### Step 6 — close the loop
- `make check` (`zig fmt --check src` + `zig build test`).
- Confirm `grep -n "symlinkPointsAt\|symlinkResolves\|canonOrLexical" src/ops.zig` is empty.
- Confirm `managed_entry.zig` has no dependency on `discovery` or `ops` (leaf module;
  it may depend only on `std` + `fsutil`).

## 6. Behavior-preservation strategy

This is a **pure refactor** — no spec behavior changes. The safety net is the existing
`discovery_test`, `ops_test`, `promote_test`, `cli_integration_test`, which must pass with
**zero edits**. If any requires editing, treat it as a regression and stop: the classifier
diverged from one of the two original implementations. The new `managed_entry_test` adds
unit-level coverage that did not previously exist (the interface as test surface).

## 7. Risks & mitigations

- **Subtle canonicalization divergence** between the two originals. Mitigation: migrate
  discovery first (Step 4) and keep `ops` on its old helpers until Step 5, so any
  divergence surfaces as a discovery-test failure in isolation.
- **`Classification.symlink` carries an allocated target** — ensure arena ownership
  matches callers (all callers already pass an operation arena).
- **Over-reach**: do not also fold `fsutil.classify`'s plain kind-checks into the new
  module; that would widen the interface and lose depth.

## 8. Done criteria

- [ ] `src/managed_entry.zig` + `src/managed_entry_test.zig` exist and are registered.
- [ ] `discovery` and `ops` contain no symlink-membership/canonicalization logic of their
      own — only mapping from `Classification`.
- [ ] All pre-existing tests pass unedited; new unit tests cover Steps 1–3.
- [ ] `make check` is green.
- [ ] `commit` skill run (plan + implementation in logical commits on a feature branch,
      never on `main`).
