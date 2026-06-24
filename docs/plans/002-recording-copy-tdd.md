# Plan B — Collapse the three recording tree-copies into one (TDD)

**Status:** proposed
**Candidate:** B (Strong) from the 2026-06-23 architecture review
**Glossary:** module / interface / depth / seam / adapter / leverage / locality (see `improve-codebase-architecture/LANGUAGE.md`)

---

## 1. Why

"Recursively copy a directory, deterministically, recording a `copy_file` action per
regular file, skipping some entries" is implemented **three times**:

- `import.zig` → `copyDirRecording` + `collectSortedEntries` + `joinRel` + `SortedEntry`
  (sorts ✓, excludes nothing).
- `repository.zig` → `copyDirRecording` + `collectSortedEntries` + `joinRel` +
  `SortedEntry` (sorts ✓, excludes `.git` anywhere).
- `ops.zig` → `copyExcludingManifest` (excludes top-level `import.json`,
  **iterates in filesystem readdir order — never got the determinism fix**).

The determinism guarantee (Finding #13) was added to two copies and **missed in the
third**: `import_test` and `repository_test` each assert "copy_file actions in sorted
order"; `promote_test` has **no** such assertion, so promote's recorded `copy_file`
ordering is unguaranteed today. This is the textbook locality failure — one rule, three
copies, the fix applied unevenly.

**Deletion test:** delete two of the three copiers — complexity (deterministic sort +
recursion + action recording) reappears. It belongs in one deep module.

## 2. Goal

One deep module, `src/recording_copy.zig`, that owns the deterministic recursive copy.
The three operations become thin **adapters** differing only in (a) which entries they
exclude and (b) which action type they record. The determinism fix lives in one place →
promote inherits it for free (the intended behavior change).

## 3. Proposed interface (refine during implementation)

```zig
//! src/recording_copy.zig
//! Deterministic, recording recursive directory copy. Entries are copied in sorted
//! order so the recorded action stream is deterministic (Finding #13) regardless of
//! filesystem readdir order. Regular files are copied and emitted; directories are
//! created and recursed; symlinks / unsupported entries are rejected.

/// Called once per copied regular file with its absolute destination path. The caller
/// wraps its own action type (ImportAction vs SkillAction). May fail; the error
/// aborts the copy and propagates, so already-emitted actions form the partial record.
pub const Sink = struct {
    ctx: *anyopaque,
    emitFn: *const fn (ctx: *anyopaque, abs_path: []const u8) anyerror!void,
    pub fn emit(self: Sink, abs_path: []const u8) anyerror!void {
        return self.emitFn(self.ctx, abs_path);
    }
};

/// Decide whether to skip a top-level-or-nested entry by name. `at_top` is true only
/// for entries directly under the copy root.
pub const Exclude = struct {
    ctx: *anyopaque = undefined,
    skipFn: *const fn (ctx: *anyopaque, name: []const u8, at_top: bool) bool,
    pub fn skip(self: Exclude, name: []const u8, at_top: bool) bool {
        return self.skipFn(self.ctx, name, at_top);
    }
};

/// Reusable exclusion policies for the three known callers.
pub const exclude_none: Exclude;            // import path/markdown directory copy
pub fn excludeGit() Exclude;                // repository: skip `.git` anywhere
pub fn excludeTopImportJson() Exclude;      // promote: skip top-level `import.json`

/// Recursively copy `src` into `dst`. `dest_root` is the absolute path of the
/// destination root used to build emitted action paths; `rel` is "" at the top level.
/// All allocations are arena-owned.
pub fn copyTree(
    arena: std.mem.Allocator,
    io: std.Io,
    src: std.Io.Dir,
    dst: std.Io.Dir,
    dest_root: []const u8,
    rel: []const u8,
    exclude: Exclude,
    sink: Sink,
) anyerror!void;
```

Notes:
- Callers already open `src`/`dst` `Dir` handles (`import.executeStore`,
  `repository.writeSkill`, `ops.executePromote`), so taking handles matches all three.
- `dest_root` for promote is the **final** `<canonical>/<name>` (not the transient
  staging dir) — that path-mapping subtlety (`ops.zig` copy comment) is preserved by the
  caller passing `dest_dir`, exactly as today.
- This is distinct from `fsutil.copyTree`, which **recreates** symlinks and records
  nothing; leave `fsutil.copyTree` untouched.
- Internal `SortedEntry`/`collectSortedEntries`/`joinRel` move into this module and are
  deleted from `import.zig` and `repository.zig`.

## 4. Caller adapters

Each caller provides a ~6-line local `Sink` wrapping its action list:

- **import.zig** (`executeStore`): sink appends
  `types.ImportAction{ .action = .copy_file, .path = abs }`; `exclude_none`.
- **repository.zig** (`writeSkill`): same `ImportAction` sink; `excludeGit()`.
- **ops.zig** (`executePromote`): sink appends
  `types.SkillAction{ .action = .copy_file, .path = abs }`; `excludeTopImportJson()`.

After migration, delete: `import.copyDirRecording` + its `SortedEntry`/`collectSortedEntries`/`joinRel`;
`repository.copyDirRecording` + its triplet; `ops.copyExcludingManifest` + `ops.joinAbsRel`.

## 5. TDD sequence (red → green → refactor)

Test-first throughout (`tdd` skill). All fixtures use `testutil.TmpRoots`/`Fixtures` —
disposable temp trees only (CLAUDE.md hard rule). `make test` after every step.

### Step 0 — scaffold the seam (red harness)
1. Create `src/recording_copy.zig` (signatures, `unreachable` body) and
   `src/recording_copy_test.zig`.
2. Register both in `src/root_test.zig`. **Mandatory** (silent-skip otherwise).
3. `make test` → fails. Harness proven.

### Step 1 — flat copy + emission order
Fixture: a source dir with files created in non-sorted order (e.g. `c.txt`, `a.txt`,
`b.txt`) plus `SKILL.md`. Test with a recording sink that collects emitted basenames:
- every regular file is copied to `dst` (assert files exist on disk),
- emitted paths are **sorted ascending** regardless of creation order,
- emitted paths are absolute under `dest_root`.

Implement `copyTree` flat case with internal sort. Green. (This is the determinism
contract, now lifted into one module.)

### Step 2 — nested recursion + path mapping
Fixture: `sub/x.txt`, `sub/deeper/y.txt`. Assert:
- subdirectories are created in `dst`,
- emitted action paths are `dest_root/sub/x.txt`, `dest_root/sub/deeper/y.txt`,
- recursion is depth-first in sorted order.

Implement recursion. Green.

### Step 3 — exclusion policies
- `exclude_none`: an `import.json` in the source IS copied.
- `excludeGit()`: a `.git` dir (and a `.git` at a nested level) is skipped entirely.
- `excludeTopImportJson()`: a **top-level** `import.json` is skipped, but a `import.json`
  in a **subdirectory** is copied (locks the `at_top` semantics).

Implement `Exclude` + the three constructors. Green.

### Step 4 — unsupported entries + sink errors
- a symlink in the source → `error.UnsupportedEntry` (matches all three originals).
- a sink that returns an error on the 2nd file → `copyTree` propagates it, and the files
  emitted before the error are exactly those the sink already saw (partial-record
  contract used by promote's partial-action reporting).

Green.

### Step 5 — migrate `import.zig` (behavior-preserving)
1. Replace `copyDirRecording` call with `recording_copy.copyTree(..., exclude_none, sink)`.
2. Delete `import.copyDirRecording`, `SortedEntry`, `collectSortedEntries`, `joinRel`.
3. Regression gate: `import_test.zig` passes **unchanged** — including
   `"import path directory emits copy_file actions in sorted (deterministic) order"`
   (line ~235) and the create_directory < copy_file < write_manifest ordering test
   (line ~600).

### Step 6 — migrate `repository.zig` (behavior-preserving)
1. Replace with `recording_copy.copyTree(..., excludeGit(), sink)`.
2. Delete the `repository` copier + triplet.
3. Regression gate: `repository_test.zig` passes **unchanged** — including the sorted-order
   test (line ~238) and the `.git`-exclusion behavior.

### Step 7 — migrate `ops.executePromote` (behavior CHANGE: promote becomes deterministic)
This is the one intended behavior change. **Write the failing test first:**
1. Add to `promote_test.zig` a new test
   `"promote: copy_file actions are emitted in sorted (deterministic) order"`, mirroring
   the import/repository sorted-order tests — create promote source files out of order,
   promote, assert emitted `copy_file` basenames are sorted. Run `make test` → **red**
   (today promote uses readdir order).
2. Replace `copyExcludingManifest` call with
   `recording_copy.copyTree(..., dest_dir, "", excludeTopImportJson(), sink)`.
3. Delete `ops.copyExcludingManifest` and `ops.joinAbsRel`.
4. `make test` → the new test is **green**; the existing promote tests
   (`copy_file path exists under canonical` line ~287, `every action path exists after
   swap` line ~796, partial-action line ~1075) pass **unchanged**.

### Step 8 — close the loop
- `make check` (`zig fmt --check src` + `zig build test`).
- `grep -n "copyDirRecording\|copyExcludingManifest\|collectSortedEntries\|joinAbsRel" src/import.zig src/repository.zig src/ops.zig` → empty.
- `recording_copy.zig` depends only on `std` + `types` (leaf-ish; no dependency on
  import/repository/ops).

## 6. Behavior-preservation strategy

Steps 5–6 are pure refactors: `import_test` and `repository_test` are the net and must
pass **unedited**. Step 7 is a deliberate, spec-aligned improvement (Output Contract:
deterministic output) — it gets its **own new failing test first**, and the pre-existing
promote tests (which assert path-existence, not order) must remain green and unedited. If
any path-existence promote test breaks, the `dest_root` mapping was passed wrong (it must
be the final destination, not staging).

## 7. Risks & mitigations

- **Sink/Exclude fn-pointer ergonomics in Zig 0.16** — keep adapters as small local
  structs with `@ptrCast`/`@alignCast` ctx (mirrors the existing `Spawner`/`EnvLookup`/
  `Clock` injection patterns already in the codebase).
- **`dest_root` vs staging path** for promote — covered by the unchanged
  `promote_test` path-existence assertions; do not let `copyTree` learn about staging.
- **Scope creep** — resist also unifying `fsutil.copyTree` (different semantics:
  symlink-preserving, non-recording).
- **Optional follow-on:** Candidate E (the duplicated `importsCollision` /
  `frontmatterName` in `import.zig`/`repository.zig`) is the natural neighbor of this
  module — both are "writing into the imports root." Fold it in here if appetite remains,
  otherwise leave for a separate pass.

## 8. Done criteria

- [ ] `src/recording_copy.zig` + `src/recording_copy_test.zig` exist and are registered.
- [ ] `import`, `repository`, `ops` each call `recording_copy.copyTree` with a local sink
      and an exclusion policy; no private recursive copier remains.
- [ ] New promote sorted-order test exists and passes; all pre-existing copy_file tests
      pass unedited.
- [ ] `make check` is green.
- [ ] `commit` skill run (logical commits on a feature branch, never on `main`).

## 9. Sequencing note

Plan A and Plan B are independent and touch mostly disjoint code (A: classification in
discovery/ops preflight; B: recursive copy in import/repository/ops execute). A is the
review's top recommendation; B is a clean follow-on that also closes the live promote
determinism gap. Do A first, then B; or run them on separate branches in parallel.
