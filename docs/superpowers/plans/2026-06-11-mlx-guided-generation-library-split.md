# MLXGuidedGeneration Library Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Carve the xgrammar-backed guided-generation engine out of `MLXFoundationModels` into a standalone `MLXGuidedGeneration` SwiftPM library (usable without FoundationModels), give it a deliberate `Grammar*` public API, and compile-time-isolate the vendored xgrammar/picojson C++ symbols so the package can coexist with another xgrammar in one binary.

**Architecture:** A new `MLXGuidedGeneration` target depends only on `CXGrammar`, `MLXLMCommon`, and `MLX`. `MLXFoundationModels` depends on it through the existing `GuidedGenerationSupport` trait; FoundationModels coupling stays isolated in `SchemaConverter`, which produces the schema/grammar *string* the engine consumes. The vendored C++ is symbol-renamed via two preprocessor `-D` defines on the `CXGrammar` target only.

**Tech Stack:** Swift 6.1+ (SwiftPM with package traits), C++17 (vendored xgrammar v0.1.30 + C shim), MLX-Swift, Swift Testing (`import Testing`).

---

## Conventions (read before starting)

- **Logical commits as you go.** Each task ends with its own commit. Do **not** accumulate work into one giant commit at the end. Every commit must leave the package building (see the per-task verification steps).
- **Git identity / signing (already configured for this repo).** The local repo config has been set: `commit.gpgsign=false`, `tag.gpgsign=false`, `user.name=thechriswebb`, `user.email=207731778+thechriswebb@users.noreply.github.com`. Commit normally with `git commit -m "..."` — do **not** pass `-S`, and do not re-enable signing. Task 0 verifies this.
- **Commit message style:** Conventional prefixes (`build:`, `refactor:`, `test:`, `chore:`, `docs:`).
- **Build/test are heavy** (MLX is large). First build is slow. Use targeted `swift test --filter <Suite>` where possible. Trait combinations are toggled with SwiftPM flags:
  - Both traits on (default): `swift build` / `swift test`
  - FM on, GG off: `swift build --traits FoundationModelsIntegration`
  - FM off, GG on: `swift build --traits GuidedGenerationSupport`
  - Both off: `swift build --disable-default-traits`
- **TDD discipline:** For every task, write or relocate the test that expresses the requirement, run it and watch it fail for the *right* reason (RED), make the minimal change (GREEN), then tidy (REFACTOR). Where the "test" is a build/symbol assertion (packaging steps), the RED is a failing build or a failing verification script.
- **Tooling (per repo CLAUDE.md):** use `rg` (not grep), `fd` (not find), `sd` (not sed) for the bulk renames.

---

## File Structure (target end state)

New library `Libraries/MLXGuidedGeneration/` owns the engine:

| File | Responsibility |
|---|---|
| `XGrammarBridge.swift` | Swift wrappers over the CXGrammar C shim: `GrammarTokenizer`, `GrammarConstraint`, `MaskResult`, `CommitResult`, `GrammarError`. (filename kept per spec migration table) |
| `VocabType.swift` | **NEW.** Public `VocabType` enum wrapping `XGVocabType`, so `CXGrammar` does not leak into the public API. |
| `GuidedGenerationLoop.swift` | Orchestration loop over a `ModelContext`. |
| `TokenizerVocabExtractor.swift` | Build a `GrammarTokenizer` vocab from a HF tokenizer. |
| `MaskSnapshot.swift` | Diagnostic mask hashing (internal). |
| `GuidedGenerationError.swift` | Loop-level errors (`incompleteOutput`, `prematureEOS`). |
| `CompositeLogitProcessor.swift` | Chain logit processors (moved up from `MLXLMCommon`). |
| `WhitespaceTokenBias.swift` | Whitespace-only token bias (moved up from `MLXLMCommon`). |

New test target `Tests/MLXGuidedGenerationTests/` owns the FM-independent tests:
`ConcurrentMaskTests.swift`, `ForcedCompletionTests.swift`, `MaskSnapshotTests.swift`, `ConstraintCachingTests.swift` (from `MLXFoundationModelsTests`), plus `CompositeLogitProcessorTests.swift`, `WhitespaceTokenBiasTests.swift` (from `MLXLMTests/GuidedGeneration`), plus a new `PublicAPISurfaceTests.swift`.

**Stays put:**
- `Libraries/MLXFoundationModels/GuidedGeneration/SchemaConverter.swift` (FM->string adapter; gated `#if FoundationModelsIntegration && GuidedGenerationSupport`).
- `Libraries/MLXLMCommon/GuidedGeneration/ClosingTokenBias.swift`, `CompletionReserve.swift`, `WhitespaceRunTracker.swift` (no xgrammar / no FM; reachable from `MLXGuidedGeneration` because it depends on `MLXLMCommon`).
- FM-specific tests in `MLXFoundationModelsTests` (`MLXLanguageModelTests` incl. `XGErrorMappingTests`, `ToolCallingSchemaTests`, `TraitMatrixTests`, etc.) — they get a trait-conditional dependency on `MLXGuidedGeneration`.

---

## Task 0: Preflight verification

**Files:** none (verification only)

- [ ] **Step 1: Confirm branch and git identity/signing**

Run:
```bash
git branch --show-current
git config --get commit.gpgsign
git config --get user.name
git config --get user.email
```
Expected:
```
mlx-foundationmodels
false
thechriswebb
207731778+thechriswebb@users.noreply.github.com
```
If `commit.gpgsign` is not `false`, run `git config --local commit.gpgsign false && git config --local tag.gpgsign false` before proceeding.

- [ ] **Step 2: Confirm a clean baseline build + tests (default traits)**

Run:
```bash
swift build
swift test --filter CXGrammarTests
```
Expected: build succeeds; `CXGrammarTests` pass. This is the green baseline every later task must preserve. No commit.

---

## Task 1: Re-pin vendored xgrammar to tag `v0.1.30`

Pin-hygiene only: record the legible release tag instead of the bare SHA. The vendored source tree is unchanged.

**Files:**
- Test: `Tests/CXGrammarTests/VersionTests.swift`
- Modify: `Sources/CXGrammar/shim.cc:46`
- Modify: `Sources/CXGrammar/xgrammar/VERSION`
- Modify: `scripts/sync-xgrammar-source.sh:98-107`

- [ ] **Step 1: Update the version test to expect the tag (RED)**

Replace the body of `Tests/CXGrammarTests/VersionTests.swift` with:
```swift
import CXGrammar
import Testing

@Suite
struct VersionTests {

    /// Verifies that kXGrammarVersion in shim.cc matches the upstream
    /// release tag recorded in Sources/CXGrammar/xgrammar/VERSION. The
    /// vendored snapshot is pinned to the legible tag (v0.1.30) rather
    /// than a bare commit SHA.
    @Test
    func testVersionMatchesVendoredTag() throws {
        let shimVersion = String(cString: xg_version())
        #expect(shimVersion == "v0.1.30")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter VersionTests`
Expected: FAIL — `shimVersion` is still `"d476a48dcd8fa3b5afeddbe850e73bb3b1dcf505"`.

- [ ] **Step 3: Update `kXGrammarVersion` in the shim (GREEN)**

In `Sources/CXGrammar/shim.cc:46`, change:
```cpp
constexpr const char kXGrammarVersion[] = "d476a48dcd8fa3b5afeddbe850e73bb3b1dcf505";
```
to:
```cpp
constexpr const char kXGrammarVersion[] = "v0.1.30";
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter VersionTests`
Expected: PASS.

- [ ] **Step 5: Record the tag as the canonical pin in VERSION**

Replace the contents of `Sources/CXGrammar/xgrammar/VERSION` with:
```
v0.1.30

Pinned to the upstream release tag v0.1.30
(resolved SHA d476a48dcd8fa3b5afeddbe850e73bb3b1dcf505, informational).

This directory is a vendored snapshot of https://github.com/mlc-ai/xgrammar.
Refresh with: scripts/sync-xgrammar-source.sh v0.1.30

Do not edit files under this directory by hand -- changes will be overwritten
at the next sync. Patches against upstream belong upstream.
```

- [ ] **Step 6: Make the sync script record tag + resolved SHA**

In `scripts/sync-xgrammar-source.sh`, replace the `Writing VERSION` block (lines 98-107):
```bash
echo "==> Writing VERSION"
cat > "$DEST_ROOT/VERSION" <<EOF
$RESOLVED_SHA

This directory is a vendored snapshot of https://github.com/mlc-ai/xgrammar.
Refresh with: scripts/sync-xgrammar-source.sh <sha-or-tag>

Do not edit files under this directory by hand -- changes will be overwritten
at the next sync. Patches against upstream belong upstream.
EOF
```
with:
```bash
echo "==> Writing VERSION"
cat > "$DEST_ROOT/VERSION" <<EOF
$REQUESTED_REV

Pinned to the upstream revision $REQUESTED_REV
(resolved SHA $RESOLVED_SHA, informational).

This directory is a vendored snapshot of https://github.com/mlc-ai/xgrammar.
Refresh with: scripts/sync-xgrammar-source.sh <sha-or-tag>

Do not edit files under this directory by hand -- changes will be overwritten
at the next sync. Patches against upstream belong upstream.
EOF
```
The pin of record is whatever rev the caller passed (the tag); the resolved SHA stays as an informational note.

- [ ] **Step 7: Commit**

```bash
git add Tests/CXGrammarTests/VersionTests.swift Sources/CXGrammar/shim.cc Sources/CXGrammar/xgrammar/VERSION scripts/sync-xgrammar-source.sh
git commit -m "build: pin vendored xgrammar to release tag v0.1.30"
```

---

## Task 2: Isolate vendored xgrammar/picojson C++ symbols

Rename the `xgrammar::` and `picojson::` C++ namespaces at compile time so two copies of xgrammar can coexist in one binary. This touches only how the `CXGrammar` target is compiled; the `xg_*` C surface is unchanged, so Swift needs no edits.

**Files:**
- Create: `scripts/verify-xgrammar-symbol-isolation.sh`
- Modify: `Package.swift:194-217` (the `CXGrammar` target `cxxSettings`)

- [ ] **Step 1: Write the symbol-isolation verification script (the "test")**

Create `scripts/verify-xgrammar-symbol-isolation.sh`:
```bash
#!/usr/bin/env bash
#
# Verifies the vendored xgrammar/picojson C++ symbols were namespace-renamed
# so they cannot collide with another xgrammar in the same binary.
#
# PASS criteria:
#   (a) mlx_xgrammar:: and mlx_picojson:: symbols are present in CXGrammar objects
#   (b) no STRONG (defined, external) bare xgrammar:: / picojson:: symbols remain
#
set -euo pipefail

echo "==> Building CXGrammar"
swift build --target CXGrammar >/dev/null

obj_dir="$(find .build -type d -name 'CXGrammar.build' | head -1)"
if [[ -z "$obj_dir" ]]; then
    echo "FAIL: could not locate CXGrammar.build object directory" >&2
    exit 1
fi
echo "    object dir: $obj_dir"

all_syms="$(find "$obj_dir" -name '*.o' -exec nm -C {} + 2>/dev/null)"

# (a) renamed namespaces present
if ! echo "$all_syms" | rg -q 'mlx_xgrammar::'; then
    echo "FAIL: no mlx_xgrammar:: symbols found (rename did not take effect)" >&2
    exit 1
fi
if ! echo "$all_syms" | rg -q 'mlx_picojson::'; then
    echo "FAIL: no mlx_picojson:: symbols found (rename did not take effect)" >&2
    exit 1
fi

# (b) no STRONG bare xgrammar:: / picojson:: symbols.
# nm -C lines look like: "<addr> <type> <demangled name>".
# Strong external defined symbols use uppercase type letters T/D/S/B.
# A bare namespace match is xgrammar::/picojson:: NOT preceded by "mlx_".
leaked="$(echo "$all_syms" \
    | rg '^[0-9a-fA-F]+ [TDSB] ' \
    | rg '(^|[^_A-Za-z0-9])(xgrammar|picojson)::' || true)"
if [[ -n "$leaked" ]]; then
    echo "FAIL: strong bare xgrammar::/picojson:: symbols leaked:" >&2
    echo "$leaked" | head -20 >&2
    exit 1
fi

echo "PASS: symbols isolated under mlx_xgrammar:: / mlx_picojson::"
```
Make it executable: `chmod +x scripts/verify-xgrammar-symbol-isolation.sh`.

- [ ] **Step 2: Run the script to verify it fails (RED)**

Run: `./scripts/verify-xgrammar-symbol-isolation.sh`
Expected: FAIL — strong bare `xgrammar::` symbols are present because the rename defines are not yet applied.

- [ ] **Step 3: Add the rename defines to the `CXGrammar` target (GREEN)**

In `Package.swift`, inside the `CXGrammar` target's `cxxSettings` array, add the two defines immediately after the existing `XGRAMMAR_ENABLE_INTERNAL_CHECK` define (currently line 200). The block becomes:
```swift
                .define("XGRAMMAR_ENABLE_CPPTRACE", to: "0"),
                .define("XGRAMMAR_ENABLE_INTERNAL_CHECK", to: "0"),
                // Rename the vendored C++ namespaces at compile time so this
                // target's symbols cannot collide with another xgrammar in the
                // same binary (e.g. CoreAI's prebuilt copy). Token-level
                // substitution: it rewrites bare `xgrammar` / `picojson`
                // identifiers (namespace decls and `::` uses) but not header
                // names, string literals, `XGRAMMAR_*` macros, or `xg_*` tokens.
                .define("xgrammar", to: "mlx_xgrammar"),
                .define("picojson", to: "mlx_picojson"),
                // xgrammar throws -- exceptions must stay enabled.
                .unsafeFlags(["-std=c++17", "-fexceptions"]),
```
(The `.unsafeFlags(["-std=c++17", ...])` and warning-suppression flags that follow are unchanged.)

- [ ] **Step 4: Re-run the script to verify it passes (GREEN)**

Run: `./scripts/verify-xgrammar-symbol-isolation.sh`
Expected: `PASS: symbols isolated under mlx_xgrammar:: / mlx_picojson::`.

- [ ] **Step 5: Confirm the C surface is unchanged**

Run: `swift test --filter CXGrammarTests`
Expected: PASS — the rename does not touch the `xg_*` C API, so these tests are unaffected.

- [ ] **Step 6: Commit**

```bash
git add scripts/verify-xgrammar-symbol-isolation.sh Package.swift
git commit -m "build: isolate vendored xgrammar/picojson C++ symbols via namespace rename"
```

---

## Task 3: Create `MLXGuidedGeneration`, move the engine + FM-independent tests (no rename yet)

Move the 7 engine files and 6 FM-independent test files into the new library/test target, drop their `GuidedGenerationSupport` guards (the library is unconditionally guided-generation), and rewire `Package.swift`. Types keep their `XG*` names in this task; the rename is Task 4. The whole package must build at the end of this task.

**Files:**
- Create dir: `Libraries/MLXGuidedGeneration/`
- Move (git mv): the 7 engine files (below)
- Create dir: `Tests/MLXGuidedGenerationTests/`
- Move (git mv): the 6 test files (below)
- Modify: `Package.swift` (add target + product + test target; edit FM target + FM test target)
- Modify: `Libraries/MLXFoundationModels/MLXLanguageModel.swift:19-21` (import)

- [ ] **Step 1: Move the 7 engine source files**

```bash
mkdir -p Libraries/MLXGuidedGeneration
git mv Libraries/MLXFoundationModels/GuidedGeneration/XGrammarBridge.swift          Libraries/MLXGuidedGeneration/XGrammarBridge.swift
git mv Libraries/MLXFoundationModels/GuidedGeneration/GuidedGenerationLoop.swift     Libraries/MLXGuidedGeneration/GuidedGenerationLoop.swift
git mv Libraries/MLXFoundationModels/GuidedGeneration/TokenizerVocabExtractor.swift  Libraries/MLXGuidedGeneration/TokenizerVocabExtractor.swift
git mv Libraries/MLXFoundationModels/GuidedGeneration/MaskSnapshot.swift             Libraries/MLXGuidedGeneration/MaskSnapshot.swift
git mv Libraries/MLXFoundationModels/GuidedGeneration/GuidedGenerationError.swift    Libraries/MLXGuidedGeneration/GuidedGenerationError.swift
git mv Libraries/MLXLMCommon/GuidedGeneration/CompositeLogitProcessor.swift          Libraries/MLXGuidedGeneration/CompositeLogitProcessor.swift
git mv Libraries/MLXLMCommon/GuidedGeneration/WhitespaceTokenBias.swift              Libraries/MLXGuidedGeneration/WhitespaceTokenBias.swift
```

- [ ] **Step 2: Drop the `GuidedGenerationSupport` guard from the 5 moved FM files**

These 5 files each begin with `#if GuidedGenerationSupport` (line 3) and end with `#endif`, and the body is indented 4 spaces inside the guard:
`XGrammarBridge.swift`, `GuidedGenerationLoop.swift`, `TokenizerVocabExtractor.swift`, `MaskSnapshot.swift`, `GuidedGenerationError.swift` (all now under `Libraries/MLXGuidedGeneration/`).

In **each** of those 5 files: delete the `#if GuidedGenerationSupport` line (and the blank line that follows it) at the top, and delete the trailing `#endif` line at the bottom. The library always provides this code, so no guard is needed. Example — `Libraries/MLXGuidedGeneration/GuidedGenerationError.swift` becomes:
```swift
// Copyright © 2025 Apple Inc.

/// Errors from grammar-constrained generation.
///
/// These indicate structural failures where the grammar could not reach
/// an accepting state, meaning the output is syntactically incomplete.
enum GuidedGenerationError: Error {
    /// Generation exhausted `maxTokens` before the grammar reached a stop state.
    /// The output is incomplete (e.g., truncated JSON missing closing braces).
    case incompleteOutput

    /// The model emitted EOS before the grammar reached a stop state.
    /// The output is incomplete despite the model thinking it was done.
    case prematureEOS
}
```
The 2 files moved from `MLXLMCommon` (`CompositeLogitProcessor.swift`, `WhitespaceTokenBias.swift`) have **no** guard and need no edit here.

- [ ] **Step 3: Normalize indentation on the de-guarded files**

The bodies of the 5 de-guarded files are now over-indented by 4 spaces. Normalize with the formatter:
```bash
swift format --in-place \
  Libraries/MLXGuidedGeneration/XGrammarBridge.swift \
  Libraries/MLXGuidedGeneration/GuidedGenerationLoop.swift \
  Libraries/MLXGuidedGeneration/TokenizerVocabExtractor.swift \
  Libraries/MLXGuidedGeneration/MaskSnapshot.swift \
  Libraries/MLXGuidedGeneration/GuidedGenerationError.swift
```
If `swift format` is unavailable in the toolchain, run the project formatter instead: `pre-commit run --files <those 5 files>`. Verify with `git diff --stat` that only indentation changed.

- [ ] **Step 4: Move the 6 FM-independent test files**

```bash
mkdir -p Tests/MLXGuidedGenerationTests
git mv Tests/MLXFoundationModelsTests/ConcurrentMaskTests.swift     Tests/MLXGuidedGenerationTests/ConcurrentMaskTests.swift
git mv Tests/MLXFoundationModelsTests/ForcedCompletionTests.swift   Tests/MLXGuidedGenerationTests/ForcedCompletionTests.swift
git mv Tests/MLXFoundationModelsTests/MaskSnapshotTests.swift       Tests/MLXGuidedGenerationTests/MaskSnapshotTests.swift
git mv Tests/MLXFoundationModelsTests/ConstraintCachingTests.swift  Tests/MLXGuidedGenerationTests/ConstraintCachingTests.swift
git mv Tests/MLXLMTests/GuidedGeneration/CompositeLogitProcessorTests.swift Tests/MLXGuidedGenerationTests/CompositeLogitProcessorTests.swift
git mv Tests/MLXLMTests/GuidedGeneration/WhitespaceTokenBiasTests.swift     Tests/MLXGuidedGenerationTests/WhitespaceTokenBiasTests.swift
```

- [ ] **Step 5: Repoint the moved tests' imports**

In the 4 files moved from `MLXFoundationModelsTests` (`ConcurrentMaskTests.swift`, `ForcedCompletionTests.swift`, `MaskSnapshotTests.swift`, `ConstraintCachingTests.swift`): they currently sit inside `#if GuidedGenerationSupport ... #endif` and `@testable import MLXFoundationModels`. Remove the `#if GuidedGenerationSupport` guard (top line + following blank, and trailing `#endif`), normalize indentation (Step 3's formatter command, applied to these files), and change `@testable import MLXFoundationModels` to `@testable import MLXGuidedGeneration`. They are unconditional now (the new test target always builds the engine).

In the 2 files moved from `MLXLMTests` (`CompositeLogitProcessorTests.swift`, `WhitespaceTokenBiasTests.swift`): add `import MLXGuidedGeneration` alongside the existing `import MLXLMCommon`. Their imports become:
```swift
import MLX
import MLXLMCommon
import MLXGuidedGeneration
import Testing
```
(`CompositeLogitProcessor` and `WhitespaceTokenBias` now live in `MLXGuidedGeneration`; `LogitProcessor` and `Tokenizer` still come from `MLXLMCommon`.)

- [ ] **Step 6: Wire the new target, product, and test target into `Package.swift`**

(6a) Add the product to the `products:` array (after the `MLXFoundationModels` library product, ~line 33):
```swift
        .library(
            name: "MLXGuidedGeneration",
            targets: ["MLXGuidedGeneration"]),
```

(6b) Add the engine target. Place it just before the `MLXFoundationModels` target (~line 229):
```swift
        // Grammar-constrained ("guided") generation engine built on the
        // vendored xgrammar C++ via CXGrammar. Standalone: depends only on
        // CXGrammar + MLXLMCommon + MLX, with no FoundationModels coupling and
        // no @available floor beyond the package's macOS 14 / iOS 17 minimum.
        .target(
            name: "MLXGuidedGeneration",
            dependencies: [
                "MLXLMCommon",
                "CXGrammar",
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Libraries/MLXGuidedGeneration"
        ),
```

(6c) Change the `MLXFoundationModels` target: replace its trait-conditional `CXGrammar` dependency with a trait-conditional `MLXGuidedGeneration` dependency. The dependencies array (currently lines 231-239) becomes:
```swift
            dependencies: [
                "MLXLMCommon",
                .target(
                    name: "MLXGuidedGeneration",
                    condition: .when(traits: ["GuidedGenerationSupport"])
                ),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ],
```

(6d) Add a trait-conditional `MLXGuidedGeneration` dependency to the `MLXFoundationModelsTests` target (its staying tests — `ToolCallingSchemaTests`, `MLXLanguageModelTests`, `TraitMatrixTests` — reference engine types). Its dependencies array (currently lines 244-254) becomes:
```swift
            dependencies: [
                "MLXFoundationModels",
                "MLXLMCommon",
                .target(
                    name: "MLXGuidedGeneration",
                    condition: .when(traits: ["GuidedGenerationSupport"])
                ),
                "MLXLLM",
                .product(name: "MLX", package: "mlx-swift"),
            ],
```

(6e) Add the new test target after `MLXFoundationModelsTests` (~line 257):
```swift
        // FM-independent guided-generation tests. Depends only on the engine
        // (+ CXGrammar for the byte-fallback vocab constant used by some
        // fixtures) and MLXLMCommon. No FoundationModels.
        .testTarget(
            name: "MLXGuidedGenerationTests",
            dependencies: [
                "MLXGuidedGeneration",
                "MLXLMCommon",
                "CXGrammar",
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Tests/MLXGuidedGenerationTests"
        ),
```

- [ ] **Step 7: Repoint the FM import from `CXGrammar` to `MLXGuidedGeneration`**

In `Libraries/MLXFoundationModels/MLXLanguageModel.swift`, the engine types now live in `MLXGuidedGeneration`. The `XGTokenizer` constructor still receives `vocab.vocabType` (type `XGVocabType` from `CXGrammar`) until Task 4, so `CXGrammar` is still needed here for now. Change lines 19-21 from:
```swift
        #if GuidedGenerationSupport
            import CXGrammar
        #endif
```
to:
```swift
        #if GuidedGenerationSupport
            import CXGrammar
            import MLXGuidedGeneration
        #endif
```

- [ ] **Step 8: Build (default traits) to verify the move (GREEN)**

Run: `swift build`
Expected: PASS. If the linker complains about a missing engine type in `MLXFoundationModels`, confirm Step 7's import was added and that the moved files compile under `MLXGuidedGeneration`.

- [ ] **Step 9: Run the relocated tests + the untouched neighbors**

Run:
```bash
swift test --filter MLXGuidedGenerationTests
swift test --filter MLXLMTests
```
Expected: `MLXGuidedGenerationTests` build and pass (note `ConstraintCachingTests` is a `.disabled` suite — it will be skipped, not failed). `MLXLMTests` still pass (the 3 remaining `GuidedGeneration` suites — `ClosingTokenBiasTests`, `CompletionReserveTests`, `WhitespaceRunTrackerTests` — are unaffected).

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "refactor: extract guided-generation engine into MLXGuidedGeneration library"
```

---

## Task 4: Rename `XG*` -> `Grammar*`, add `VocabType`, set the public API surface

Give the library a deliberate public API: rename the five `XG*` Swift types, introduce a public `VocabType` that hides `CXGrammar` from callers, mark the intended surface `public`, and drop FM's now-unneeded `CXGrammar` import. The rename is token-level and word-boundary safe, so it does **not** touch `CXGrammar` C identifiers (`XGTokenizerInfo`, `XGGrammarCompiler`, `XGCompiledGrammar`, `XGMatcher`, `XGStatus`, `XGVocabType`, `XG_OK`, `XG_*`).

**Files:**
- Create: `Libraries/MLXGuidedGeneration/VocabType.swift`
- Create: `Tests/MLXGuidedGenerationTests/PublicAPISurfaceTests.swift`
- Modify: `Libraries/MLXGuidedGeneration/*.swift` (rename + access levels)
- Modify: `Libraries/MLXFoundationModels/MLXLanguageModel.swift` (rename call sites; drop `CXGrammar` import)
- Modify: `Libraries/MLXFoundationModels/GuidedGeneration/SchemaConverter.swift:120` (doc comment)
- Modify: `Libraries/MLXFoundationModels/Documentation.docc/guided-generation.md:44,53`
- Modify: the staying FM tests + moved tests that name `XG*` / `XGVocabType`

- [ ] **Step 1: Write the public-API surface test (RED)**

This test uses a **plain** `import MLXGuidedGeneration` (not `@testable`), so it only compiles once the renamed types and `VocabType` are `public`. Create `Tests/MLXGuidedGenerationTests/PublicAPISurfaceTests.swift`:
```swift
// Copyright © 2026 Apple Inc.
//
// Pins the deliberate public API of MLXGuidedGeneration. Uses a NON-@testable
// import so it fails to compile if any of these declarations is not `public`.

import MLXGuidedGeneration
import Testing

@Suite
struct PublicAPISurfaceTests {

    @Test
    func grammarConstraintCompilesAndMasksThroughPublicAPI() throws {
        // GrammarTokenizer built from a 256-entry byte-fallback vocab via the
        // public VocabType enum (no CXGrammar import required by the caller).
        let vocab: [String] = (0 ..< 256).map { String(format: "<0x%02X>", $0) }
        let tokenizer = try GrammarTokenizer(
            vocab: vocab,
            vocabType: .byteFallback,
            eosTokenId: 255
        )

        let constraint = try GrammarConstraint(
            tokenizer: tokenizer,
            jsonSchema: #"{ "type": "integer" }"#
        )

        let mask: MaskResult = try constraint.computeMask()
        #expect(!mask.mask.isEmpty)
        #expect(mask.isTerminated == false)
    }

    @Test
    func grammarErrorIsPublicAndTyped() {
        let error: GrammarError = .invalidJSONSchema("bad schema")
        guard case .invalidJSONSchema(let message) = error else {
            Issue.record("expected invalidJSONSchema")
            return
        }
        #expect(message == "bad schema")
    }

    @Test
    func commitResultIsPublic() throws {
        let vocab: [String] = (0 ..< 256).map { String(format: "<0x%02X>", $0) }
        let tokenizer = try GrammarTokenizer(vocab: vocab, vocabType: .byteFallback, eosTokenId: 255)
        let constraint = try GrammarConstraint(tokenizer: tokenizer, jsonSchema: #"{ "type": "integer" }"#)
        _ = try constraint.computeMask()
        // "0" is ASCII 0x30 = token 48 in the byte-fallback vocab; a valid
        // first token for an integer. commitToken returns a public CommitResult.
        let result: CommitResult = try constraint.commitToken(48)
        #expect(result.isTerminated == true || result.isTerminated == false)
    }
}
```

- [ ] **Step 2: Run it to verify it fails (RED)**

Run: `swift test --filter PublicAPISurfaceTests`
Expected: FAIL to compile — `GrammarTokenizer`, `GrammarConstraint`, `MaskResult`, `CommitResult`, `GrammarError`, and `VocabType` do not exist yet (still `XG*`, and not `public`).

- [ ] **Step 3: Add the `VocabType` enum (GREEN, part 1)**

Create `Libraries/MLXGuidedGeneration/VocabType.swift`:
```swift
// Copyright © 2026 Apple Inc.

import CXGrammar

/// Selects xgrammar's token-decoding path when building a ``GrammarTokenizer``.
///
/// Wraps `CXGrammar`'s `XGVocabType` so callers of this library do not need to
/// import the C shim to construct a tokenizer.
public enum VocabType: Sendable {
    /// Each vocab string is literal UTF-8 bytes (`XG_VOCAB_TYPE_RAW`).
    case raw
    /// SentencePiece `<0xNN>` byte-fallback + `▁` decoding
    /// (`XG_VOCAB_TYPE_BYTE_FALLBACK`).
    case byteFallback
    /// GPT-2 `bytes_to_unicode` byte-level decoding
    /// (`XG_VOCAB_TYPE_BYTE_LEVEL`).
    case byteLevel

    /// The matching `CXGrammar` C enum value.
    var xgVocabType: XGVocabType {
        switch self {
        case .raw: return XG_VOCAB_TYPE_RAW
        case .byteFallback: return XG_VOCAB_TYPE_BYTE_FALLBACK
        case .byteLevel: return XG_VOCAB_TYPE_BYTE_LEVEL
        }
    }
}
```

- [ ] **Step 4: Run the five word-boundary type renames (GREEN, part 2)**

Run these across the engine library, the FM library, and both test directories. `\b` boundaries protect the `CXGrammar` C identifiers (e.g. `XGTokenizerInfo`, `XGStatus`) and method names like `makeXGTokenizer` / `mapXGError`:
```bash
fd -e swift . Libraries/MLXGuidedGeneration Libraries/MLXFoundationModels Tests/MLXGuidedGenerationTests Tests/MLXFoundationModelsTests \
  -x sd '\bXGConstraint\b' 'GrammarConstraint' {}
fd -e swift . Libraries/MLXGuidedGeneration Libraries/MLXFoundationModels Tests/MLXGuidedGenerationTests Tests/MLXFoundationModelsTests \
  -x sd '\bXGTokenizer\b' 'GrammarTokenizer' {}
fd -e swift . Libraries/MLXGuidedGeneration Libraries/MLXFoundationModels Tests/MLXGuidedGenerationTests Tests/MLXFoundationModelsTests \
  -x sd '\bXGMaskResult\b' 'MaskResult' {}
fd -e swift . Libraries/MLXGuidedGeneration Libraries/MLXFoundationModels Tests/MLXGuidedGenerationTests Tests/MLXFoundationModelsTests \
  -x sd '\bXGCommitResult\b' 'CommitResult' {}
fd -e swift . Libraries/MLXGuidedGeneration Libraries/MLXFoundationModels Tests/MLXGuidedGenerationTests Tests/MLXFoundationModelsTests \
  -x sd '\bXGError\b' 'GrammarError' {}
```
Sanity-check that no C identifiers were caught (expected: still present, unchanged):
```bash
rg -n '\bXGTokenizerInfo\b|\bXGGrammarCompiler\b|\bXGCompiledGrammar\b|\bXGMatcher\b|\bXGStatus\b|\bXGVocabType\b' Libraries/MLXGuidedGeneration
```

- [ ] **Step 5: Switch `GrammarTokenizer` and the vocab extractor to `VocabType` (GREEN, part 3)**

(5a) In `Libraries/MLXGuidedGeneration/XGrammarBridge.swift`, change the `GrammarTokenizer.init` signature and the call into the C shim. The initializer's parameter `vocabType: XGVocabType` becomes `vocabType: VocabType`, and the `xg_tokenizer_info_new` call passes `vocabType.xgVocabType`:
```swift
        init(vocab: [String], vocabType: VocabType, eosTokenId: Int32) throws {
            self.vocabSize = vocab.count

            var info: OpaquePointer?
            let stopTokens: [Int32] = [eosTokenId]

            let status: XGStatus = vocab.withCStringPointers { ptrs in
                stopTokens.withUnsafeBufferPointer { stopBuf in
                    xg_tokenizer_info_new(
                        ptrs.baseAddress,
                        ptrs.count,
                        vocabType.xgVocabType,
                        stopBuf.baseAddress,
                        stopBuf.count,
                        &info
                    )
                }
            }
            // ... (remainder of init unchanged)
```

(5b) In `Libraries/MLXGuidedGeneration/TokenizerVocabExtractor.swift`, change `XGrammarVocab.vocabType` to `VocabType` and map the detection result to it. Replace the field declaration:
```swift
        struct XGrammarVocab {
            let vocab: [String]
            let vocabType: VocabType
        }
```
and the detection tail of `extractForXGrammar(from:)`:
```swift
            let vocabType: VocabType
            if sawByteFallback {
                vocabType = .byteFallback
            } else if sawByteLevelScalar {
                vocabType = .byteLevel
            } else {
                vocabType = .raw
            }

            return XGrammarVocab(vocab: vocab, vocabType: vocabType)
```
`TokenizerVocabExtractor` no longer references any `XG_VOCAB_TYPE_*` constant. Remove its now-unused `import CXGrammar` (keep `import MLXLMCommon`).

- [ ] **Step 6: Set the public access levels (GREEN, part 4)**

Apply `public` to the deliberate surface. Internals stay `internal` (no keyword).

In `Libraries/MLXGuidedGeneration/XGrammarBridge.swift`:
- `enum GrammarError: Error` -> `public enum GrammarError: Error` (cases are public automatically).
- `final class GrammarTokenizer: @unchecked Sendable` -> `public final class GrammarTokenizer: @unchecked Sendable`; mark its `init(vocab:vocabType:eosTokenId:)` `public`. Leave `pointer` / `vocabSize` as `internal`.
- `struct MaskResult` -> `public struct MaskResult`; mark its stored properties `public let mask`, `public let isTerminated`, `public let needsApply`, and add a `public init(mask:isTerminated:needsApply:)` (a public struct needs a public memberwise init for external construction; the loop constructs it in-module so this can stay implicit, but mark the properties public).
- `struct CommitResult` -> `public struct CommitResult`; mark `public let tokens`, `public let isTerminated`.
- `final class GrammarConstraint: @unchecked Sendable` -> `public final class GrammarConstraint: @unchecked Sendable`. Mark `public` the three throwing inits (`init(tokenizer:jsonSchema:fastForward:hostTokenizer:)`, `init(tokenizer:grammar:rootRule:fastForward:hostTokenizer:)`, `init(tokenizer:structuralTag:fastForward:hostTokenizer:)`), and the methods `computeMask()`, `commitToken(_:)`, `rollback(_:)`, `clone()`, `flushLogs()`, and the `fastForwardDisagreementCount` computed property. The private `init(fromFork:parent:)`, the stored properties, and `emitFastForwardLocked` / `isMatcherTerminatedLocked` / `captureShimError` stay `private`.

In `Libraries/MLXGuidedGeneration/GuidedGenerationError.swift`: `enum GuidedGenerationError` -> `public enum GuidedGenerationError`.

In `Libraries/MLXGuidedGeneration/GuidedGenerationLoop.swift`: `enum GuidedGenerationLoop` -> `public enum GuidedGenerationLoop`; mark `static func run(...)` `public`. Leave `applyMaskAndSample`, `buildStopTokenIDs`, `StepResult`, and the private helpers `internal`/`private` (tests reach them via `@testable`).

In `Libraries/MLXGuidedGeneration/TokenizerVocabExtractor.swift`: `enum TokenizerVocabExtractor` -> `public enum TokenizerVocabExtractor`; mark `static func extractForXGrammar(from:)` `public` and `struct XGrammarVocab` -> `public struct XGrammarVocab` with `public let vocab` / `public let vocabType`. Leave `extract(from:)`, `VocabData`, and `tokenToBytes` `internal` (used only by `@testable` tests).

`MaskSnapshot.swift` stays fully `internal` (diagnostic, `@testable`-only). `CompositeLogitProcessor.swift` and `WhitespaceTokenBias.swift` are already `public`.

- [ ] **Step 7: Drop FM's `CXGrammar` import and migrate its tokenizer construction**

In `Libraries/MLXFoundationModels/MLXLanguageModel.swift`, the only reason FM imported `CXGrammar` was the `XGVocabType` passthrough, which is now `VocabType`. Change lines 19-21 to:
```swift
        #if GuidedGenerationSupport
            import MLXGuidedGeneration
        #endif
```
The `makeXGTokenizer` body (around line 135) already passes `vocab.vocabType` straight through; its type is now `VocabType`, so no further edit is needed there. Build will confirm FM no longer references any `CXGrammar` symbol.

- [ ] **Step 8: Migrate the staying FM tests' tokenizer construction to `VocabType`**

The three staying FM tests build a tokenizer with `vocabType: XG_VOCAB_TYPE_BYTE_FALLBACK`. After Step 5a the initializer takes a `VocabType`. Update each call site:

In `Tests/MLXFoundationModelsTests/ConstraintCachingTests.swift` (~line 33), `ToolCallingSchemaTests.swift` (~line 251), and `TraitMatrixTests.swift` (~line 189), change:
```swift
            return try GrammarTokenizer(
                vocab: vocab,
                vocabType: XG_VOCAB_TYPE_BYTE_FALLBACK,
                eosTokenId: Int32(vocabSize - 1)
            )
```
to:
```swift
            return try GrammarTokenizer(
                vocab: vocab,
                vocabType: .byteFallback,
                eosTokenId: Int32(vocabSize - 1)
            )
```
(`TraitMatrixTests` constructs inline rather than in a helper, but the `GrammarTokenizer(...)` call shape is identical.) Then remove the now-unused `import CXGrammar` from any of these files that imported it solely for that constant (e.g. `ToolCallingSchemaTests.swift`). Keep `@testable import MLXFoundationModels` and add `@testable import MLXGuidedGeneration` where a file references engine internals.

- [ ] **Step 9: Migrate the moved test that used the C constant**

`Tests/MLXGuidedGenerationTests/ConstraintCachingTests.swift` (moved in Task 3) builds its tokenizer with `XG_VOCAB_TYPE_BYTE_FALLBACK` and `import CXGrammar`. Change its construction to `vocabType: .byteFallback` and remove `import CXGrammar` (it now reaches `GrammarTokenizer` / `VocabType` via `@testable import MLXGuidedGeneration`).

- [ ] **Step 10: Fix the lingering `XG*` mentions in prose/docs**

These are comments/docs the token rename either updated or should be checked:
- `Libraries/MLXFoundationModels/GuidedGeneration/SchemaConverter.swift:120` — the doc comment mentioning `XGTokenizer` was rewritten to `GrammarTokenizer` by Step 4; confirm it reads sensibly.
- `Libraries/MLXFoundationModels/Documentation.docc/guided-generation.md` — confirm Step 4 rewrote `XGConstraint` -> `GrammarConstraint` (line ~53) and that `GuidedGenerationLoop.run` (line ~44) still resolves. Fix any symbol link that no longer points at a real symbol.
- The top-of-file comment block in `Libraries/MLXGuidedGeneration/XGrammarBridge.swift` should now read `GrammarTokenizer` / `GrammarConstraint` / `GrammarError` / `MaskResult` / `CommitResult` (renamed by Step 4) while still naming the C handles `XGGrammarCompiler` / `XGCompiledGrammar` / `XGMatcher` (unchanged). Confirm it's coherent.

- [ ] **Step 11: Build and run the public-API test + relocated tests (GREEN)**

Run:
```bash
swift build
swift test --filter MLXGuidedGenerationTests
```
Expected: PASS. `PublicAPISurfaceTests` now compiles (proving the surface is `public`) and passes. The other relocated suites pass; `ConstraintCachingTests` stays skipped (`.disabled`).

- [ ] **Step 12: Build the FM test target to confirm the staying tests compile**

Run: `swift test --filter MLXFoundationModelsTests`
Expected: PASS. `XGErrorMappingTests` (now exercising `GrammarError` through `MLXLanguageModel.Executor.mapXGError`), `ToolCallingSchemaTests`, and `TraitMatrixTests` compile and pass against the renamed surface.

- [ ] **Step 13: Commit**

```bash
git add -A
git commit -m "refactor: give MLXGuidedGeneration a deliberate Grammar* public API"
```

---

## Task 5: Verify the full trait matrix and symbol isolation

Confirm all four trait combinations build (the FM-off and trait-off combinations are the regression-prone ones), re-run the symbol acceptance check, and capture the matrix as a repeatable script.

**Files:**
- Create: `scripts/verify-trait-matrix.sh`

- [ ] **Step 1: Write the trait-matrix verification script (the "test")**

Create `scripts/verify-trait-matrix.sh`:
```bash
#!/usr/bin/env bash
#
# Builds every trait combination of the package. The FM-off / GG-off arms are
# the regression-prone ones after the MLXGuidedGeneration split: a moved type
# referenced outside the GuidedGenerationSupport gate in MLXFoundationModels
# would break here.
#
set -euo pipefail

echo "==> [1/4] both traits ON (defaults)"
swift build

echo "==> [2/4] FM on, GG off"
swift build --traits FoundationModelsIntegration

echo "==> [3/4] FM off, GG on"
swift build --traits GuidedGenerationSupport

echo "==> [4/4] both traits OFF"
swift build --disable-default-traits

echo "PASS: all four trait combinations build"
```
Make it executable: `chmod +x scripts/verify-trait-matrix.sh`.

- [ ] **Step 2: Run the matrix (RED if any ungated reference slipped through)**

Run: `./scripts/verify-trait-matrix.sh`
Expected: `PASS: all four trait combinations build`.
If arm [3] (FM off, GG on) fails, an engine type is referenced in `MLXFoundationModels` outside the `#if GuidedGenerationSupport` gate, or the FM target's `MLXGuidedGeneration` dependency condition is wrong — fix the gate/condition and re-run.
If arm [4] (both off) fails, an engine reference is outside both gates — fix and re-run.

- [ ] **Step 3: Re-run the symbol isolation check**

Run: `./scripts/verify-xgrammar-symbol-isolation.sh`
Expected: `PASS: symbols isolated under mlx_xgrammar:: / mlx_picojson::` (the Task 2 guarantee still holds after the moves).

- [ ] **Step 4: Confirm test coverage did not silently drop**

Run, with default traits:
```bash
swift test --filter MLXGuidedGenerationTests
swift test --filter MLXFoundationModelsTests
swift test --filter MLXLMTests
swift test --filter CXGrammarTests
```
Expected: all pass. Spot-check that the count of guided-generation test functions equals the pre-split count: the four moved FM suites + two moved MLXLMTests suites now live under `MLXGuidedGenerationTests` (plus the new `PublicAPISurfaceTests`), the three `MLXLMTests/GuidedGeneration` suites that stayed still run, and the FM suites that stayed still run. Nothing should be orphaned (no test file left referencing a moved type from the wrong target).

- [ ] **Step 5: Commit**

```bash
git add scripts/verify-trait-matrix.sh
git commit -m "build: add trait-matrix verification script for the guided-generation split"
```

---

## Self-Review

**1. Spec coverage** (checked against `docs/superpowers/specs/2026-06-11-mlx-guided-generation-library-split-design.md`):
- New `MLXGuidedGeneration` product/target depending only on `CXGrammar` + `MLXLMCommon` + `MLX` — Task 3 (6a, 6b).
- Deliberate `Grammar*` public API with per-declaration access review — Task 4 (Steps 4, 6) + `PublicAPISurfaceTests`.
- Compile-time symbol isolation (`xgrammar`/`picojson` rename) + nm acceptance check — Task 2.
- No behavior change for FM consumers, trait-off included — Task 5 matrix.
- Trait wiring relocated one layer up (FM -> engine via trait; engine -> CXGrammar unconditional) — Task 3 (6c); `WhitespaceTokenBias` call sites already inside the gate (verified by explore) and FM's only engine import is gated — Task 3 (7), Task 4 (7).
- `SchemaConverter` stays in FM under its gate — File Structure + Task 4 (10).
- Version pin to tag `v0.1.30` across sync script, `VERSION`, `kXGrammarVersion` — Task 1.
- Tests split: FM-independent -> `MLXGuidedGenerationTests`; FM-specific stay — Task 3 (4-5), Task 4 (8-9).
- Deferred non-goals respected: no xgrammar version bump, no external-package conversion, no prefix changes beyond `XG*->Grammar*`. The `VocabType` enum is the one addition, required to keep `CXGrammar` out of the public API (squarely within the spec's "expose only what a standalone consumer needs").

**2. Placeholder scan:** No `TBD`/`implement later`/"add error handling"/"write tests for the above" left. Every code step shows the code; every command shows expected output.

**3. Type consistency:** Renames are consistent across tasks — `XGConstraint->GrammarConstraint`, `XGTokenizer->GrammarTokenizer`, `XGMaskResult->MaskResult`, `XGCommitResult->CommitResult`, `XGError->GrammarError`; `GuidedGenerationLoop`, `GuidedGenerationError`, `TokenizerVocabExtractor`, `CompositeLogitProcessor`, `WhitespaceTokenBias`, `MaskSnapshot` keep their names. `VocabType` (new) is used identically in `GrammarTokenizer.init`, `XGrammarVocab.vocabType`, and the tests. The CXGrammar C identifiers deliberately left untouched (`XGTokenizerInfo`, `XGGrammarCompiler`, `XGCompiledGrammar`, `XGMatcher`, `XGStatus`, `XGVocabType`, `XG_*`) are protected by `\b` boundaries and re-verified in Task 4 (Step 4).
