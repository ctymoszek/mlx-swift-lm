# Remove the `GuidedGenerationSupport` Trait — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the `GuidedGenerationSupport` package trait so `MLXFoundationModels` always uses `MLXGuidedGeneration`, leaving `FoundationModelsIntegration` as the only trait.

**Architecture:** The guided-generation engine is already its own `MLXGuidedGeneration` library/product. This change deletes the optional trait: every `#if GuidedGenerationSupport` block in `MLXFoundationModels` becomes unconditional, the `#else` fallback and `MLXLanguageModelError.guidedGenerationDisabled` are deleted, and `MLXFoundationModels`'s dependency on `MLXGuidedGeneration` is re-keyed to `.when(traits: ["FoundationModelsIntegration"])` (it references engine types only inside that gate).

**Tech Stack:** Swift 6.1, SwiftPM package traits, `swift format`, `rg`, Swift Testing, an Xcode project for IntegrationTesting.

**Spec:** `docs/superpowers/specs/2026-06-11-remove-guided-generation-support-trait-design.md`

**TDD note:** This is a removal refactor with no new behavior. The red/green driver is a reference-guard script (Task 1) that fails while any `GuidedGenerationSupport` reference remains and passes once they are all gone, backed by the FM-on/FM-off build matrix (Task 7) and the existing test suites. The guard is committed RED in Task 1 and goes GREEN in Task 9. Refactor steps are the `swift format` indentation passes after each de-guarding edit.

**Ordering:** Source edits come before the `Package.swift` trait removal so every intermediate **default** build stays green (with the trait still defined and default-on, de-guarded code is simply always-compiled). Intermediate steps build only the default configuration; the full FM-on/FM-off matrix runs at the end.

**Local build flags:** This repo's dev environment needs `--disable-sandbox --skip-update -Xswiftc -disable-sandbox` (the macro plugin server cannot be sandboxed here; network is restricted). These appear in the build commands below.

---

## Task 1: Reference-guard script (the failing test)

**Files:**
- Create: `scripts/verify-no-guided-generation-trait.sh`

- [ ] **Step 1: Write the guard script**

```bash
#!/usr/bin/env bash
#
# Guards against any lingering GuidedGenerationSupport references after the
# trait's removal. The superpowers design/plan docs are allowed to keep
# references (they document the change and prior work), as is this script
# itself (it names the token in its grep pattern).
set -euo pipefail

cd "$(dirname "$0")/.."

matches=$(rg -n "GuidedGenerationSupport" \
    --glob '!.build/**' \
    --glob '!docs/superpowers/**' \
    --glob '!scripts/verify-no-guided-generation-trait.sh' \
    || true)

if [[ -n "$matches" ]]; then
    echo "FAIL: GuidedGenerationSupport references remain:"
    echo "$matches"
    exit 1
fi

echo "PASS: no GuidedGenerationSupport references outside allowed paths"
```

- [ ] **Step 2: Make it executable and run it to verify it FAILS**

Run:
```bash
chmod +x scripts/verify-no-guided-generation-trait.sh
./scripts/verify-no-guided-generation-trait.sh
```
Expected: FAIL, listing references in `Package.swift`, `MLXLanguageModel.swift`, `SchemaConverter.swift`, tests, the pbxproj, README, and the docc files.

- [ ] **Step 3: Commit the RED guard**

```bash
git add scripts/verify-no-guided-generation-trait.sh
git commit -m "test: add guard for GuidedGenerationSupport trait removal"
```

---

## Task 2: Simplify the `SchemaConverter.swift` gate

**Files:**
- Modify: `Libraries/MLXFoundationModels/GuidedGeneration/SchemaConverter.swift`

- [ ] **Step 1: Replace the opening guard (line 3)**

Old:
```swift
#if FoundationModelsIntegration && GuidedGenerationSupport
```
New:
```swift
#if FoundationModelsIntegration
```

- [ ] **Step 2: Replace the closing comment (line 205)**

Old:
```swift
#endif  // FoundationModelsIntegration && GuidedGenerationSupport
```
New:
```swift
#endif  // FoundationModelsIntegration
```

- [ ] **Step 3: Build the default configuration**

Run: `swift build --disable-sandbox --skip-update -Xswiftc -disable-sandbox`
Expected: PASS (trait still default-on, so this file still compiles).

- [ ] **Step 4: Commit**

```bash
git add Libraries/MLXFoundationModels/GuidedGeneration/SchemaConverter.swift
git commit -m "refactor: drop GuidedGenerationSupport from SchemaConverter gate"
```

---

## Task 3: De-gate `MLXLanguageModel.swift`

The adapter has 10 plain `#if GuidedGenerationSupport ... #endif` wrappers, one `#if … #else … #endif` block, one `#if !GuidedGenerationSupport` block, and one doc comment mentioning the trait. After this task none remain.

**Files:**
- Modify: `Libraries/MLXFoundationModels/MLXLanguageModel.swift`

- [ ] **Step 1: Delete the `#if !GuidedGenerationSupport` error block (lines 1835-1844)**

Delete this entire block (the `MLXLanguageModelError` enum existed only when the trait was off; guided generation is now always available, so the error and its only case are removed):

```swift
        #if !GuidedGenerationSupport
            /// Errors specific to MLXLanguageModel when guided-generation paths are
            /// unavailable. Only present when the SPM trait is disabled.
            public enum MLXLanguageModelError: Error {
                /// The request needs guided generation (a response schema or tool
                /// invocation), but the package was built with the
                /// `GuidedGenerationSupport` trait disabled.
                case guidedGenerationDisabled
            }
        #endif  // !GuidedGenerationSupport
```

- [ ] **Step 2: Collapse the `#if … #else … #endif` tool-calling block**

In the block that opens at `#if GuidedGenerationSupport` (line 957) and runs through its `#endif` (line 1339): keep the `#if` branch body, and delete the guard lines plus the entire `#else` branch. Concretely:

Delete the opening guard line (line 957):
```swift
                            #if GuidedGenerationSupport
```

Delete everything from the `#else` (line 1312) through its `#endif` (line 1339) inclusive — i.e. this whole tail:
```swift
                            #else
                                // Without GuidedGenerationSupport, the only available
                                // path is unconstrained text generation. Tool calling
                                // and guided JSON both depend on xgrammar.
                                if !request.enabledToolDefinitions.isEmpty
                                    && !isContinuationAfterToolCall
                                {
                                    // Surface the limitation rather than silently
                                    // falling back to unconstrained text -- the caller
                                    // explicitly asked for tools.
                                    throw MLXLanguageModelError.guidedGenerationDisabled
                                }
                                if request.schema != nil {
                                    throw MLXLanguageModelError.guidedGenerationDisabled
                                }
                                try await runTextGeneration(
                                    reasoningSetup: reasoningSetup,
                                    fallbackInput: effectiveInput,
                                    requestedMaxTokens: requestedMaxTokens,
                                    requestedTemperature: request.generationOptions.temperature,
                                    samplingMode: requestedSamplingMode,
                                    additionalStopTokens: profile.extraEOSTokens,
                                    responseEntryID: entryID,
                                    reasoningEntryID: reasoningEntryID,
                                    context: context,
                                    channel: channel
                                )
                            #endif
```

The `if`/`else` body that lived in the `#if` branch (the guided tool-calling path and its trailing unconstrained `else`) stays.

- [ ] **Step 3: Remove the 10 plain wrapper guards**

Each of these is a `#if GuidedGenerationSupport` line paired with a matching `#endif`. Delete **only** the guard line and its matching `#endif` line; keep the enclosed body. The guard/`#endif` pairs are:

| `#if` line | matching `#endif` line | What it wraps |
|---|---|---|
| 19 | 21 | `import MLXGuidedGeneration` |
| 45 | 50 | `ModelCache` xgTokenizers / constraintTemplates fields |
| 125 | 197 | (cache-related block) |
| 206 | 209 | (cache-related block) |
| 345 | 379 | (executor block) |
| 545 | 564 | (executor block) |
| 666 | 697 | (generation block) |
| 779 | 786 | (generation block) |
| 1351 | 1358 | `GrammarError` remap in the `catch` |

(That is 9 pairs after Steps 1-2 have already consumed the 957/1312/1339 block; the 1647→1831 think-then-call pair is the 10th.)

| `#if` line | matching `#endif` line | What it wraps |
|---|---|---|
| 1647 | 1831 | think-then-call Phase 1/Phase 2 helper methods |

For the `catch`-block pair specifically, after removing the guard lines the body is:
```swift
                        // Re-map xgrammar errors to typed `LanguageModelError` cases
                        // where the cause is provably user input (see `mapXGError`).
                        // Internal-shim failures pass through unchanged.
                        if let xgError = error as? GrammarError {
                            throw Self.mapXGError(xgError)
                        }
```

> Line numbers above are pre-edit positions. Delete from the bottom up (highest line number first) so earlier deletions don't shift later targets. After this step, `rg -n "#if GuidedGenerationSupport|#if !GuidedGenerationSupport" Libraries/MLXFoundationModels/MLXLanguageModel.swift` must return nothing.

- [ ] **Step 4: Reword the doc comment (lines 404-405)**

Old:
```swift
            /// MLX supports guided generation via xgrammar grammar-constrained
            /// decoding (when the GuidedGenerationSupport trait is enabled), tool
            /// calling via the synthetic-final-answer envelope, and reasoning
```
New:
```swift
            /// MLX supports guided generation via xgrammar grammar-constrained
            /// decoding (provided by the MLXGuidedGeneration library), tool
            /// calling via the synthetic-final-answer envelope, and reasoning
```

- [ ] **Step 5: Normalize indentation with the project formatter**

Run: `swift format --in-place Libraries/MLXFoundationModels/MLXLanguageModel.swift`
Then: `git diff --stat Libraries/MLXFoundationModels/MLXLanguageModel.swift`
Expected: changes confined to the de-guarded regions (re-indentation) plus the deletions above. If `swift format` is unavailable, run `pre-commit run --files Libraries/MLXFoundationModels/MLXLanguageModel.swift`.

- [ ] **Step 6: Build the default configuration**

Run: `swift build --disable-sandbox --skip-update -Xswiftc -disable-sandbox`
Expected: PASS. (Trait still default-on; de-guarded code is now unconditional and compiles.)

- [ ] **Step 7: Commit**

```bash
git add Libraries/MLXFoundationModels/MLXLanguageModel.swift
git commit -m "refactor: make guided generation unconditional in MLXLanguageModel"
```

---

## Task 4: Update `MLXFoundationModelsTests`

**Files:**
- Modify: `Tests/MLXFoundationModelsTests/TraitMatrixTests.swift` (rewrite)
- Modify: `Tests/MLXFoundationModelsTests/MLXLanguageModelTests.swift`
- Modify: `Tests/MLXFoundationModelsTests/ToolCallingSchemaTests.swift`
- Modify: `Tests/MLXFoundationModelsTests/TestHelpers.swift`

- [ ] **Step 1: Rewrite `TraitMatrixTests.swift`**

Replace the entire file contents with:

```swift
// Copyright © 2026 Apple Inc.
//
// TraitMatrixTests: symbol-surface + behavioral checks across the
// `FoundationModelsIntegration` trait — the package's only trait.
//
// Each `#if` block below is active for exactly one trait state. Successfully
// compiling this file under a given trait set is the primary structural
// assertion: the test bodies reference the symbols that must be present.
//
// The `FoundationModelsIntegration`-on arm additionally requires
// `canImport(FoundationModels, _version: 2)`: the adapter surface
// (`MLXLanguageModel` et al.) only exists on the 27 SDK, so on the 26 SDK that
// arm compiles to nothing even when the trait is on. Guided generation is no
// longer trait-gated — whenever the adapter exists, the engine is present.

import Testing

#if FoundationModelsIntegration
    @testable import MLXFoundationModels
    import FoundationModels
    import MLXGuidedGeneration
#else
    @testable import MLXFoundationModels
#endif

@Suite("Trait matrix: FoundationModelsIntegration")
struct TraitMatrixTests {

    // MARK: - FoundationModelsIntegration on (default)

    #if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
        @Test("FM on: MLXLanguageModel + guided-generation primitives compile")
        func fmOnSurface() {
            guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
            _ = MLXLanguageModel.self
            _ = MLXLanguageModel.Executor.self
            _ = GuidedGenerationLoop.self
            _ = GrammarConstraint.self
            _ = MLXDownloadProgress.self
        }

        @Test("FM on: capabilities stored verbatim from init")
        func capabilitiesStoredVerbatim() {
            guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
            // Capabilities are authoritative: the adapter stores what the caller
            // passes, never inferring from the model id.
            let reasoning = makeStubModel(
                "mlx-community/Qwen3-4B-4bit",
                capabilities: LanguageModelCapabilities(capabilities: [
                    .reasoning, .guidedGeneration, .toolCalling,
                ])
            ).capabilities
            #expect(reasoning.contains(.reasoning))
            #expect(reasoning.contains(.guidedGeneration))
            #expect(reasoning.contains(.toolCalling))

            let nonReasoning = makeStubModel(
                TestFixtures.gemmaModelID,
                capabilities: LanguageModelCapabilities(capabilities: [
                    .guidedGeneration, .toolCalling,
                ])
            ).capabilities
            #expect(!nonReasoning.contains(.reasoning))
            #expect(nonReasoning.contains(.guidedGeneration))
        }
    #endif

    // MARK: - FoundationModelsIntegration off

    #if !FoundationModelsIntegration
        @Test("FM off: MLXFoundationModels exposes only MLXDownloadProgress")
        func fmOffSurface() {
            _ = MLXDownloadProgress.self
            // No MLXLanguageModel in this configuration; the fact that this file
            // compiles without referencing it is the assertion.
        }
    #endif
}
```

- [ ] **Step 2: Fix `MLXLanguageModelTests.swift` import gate (lines 10-12)**

Old:
```swift
#if GuidedGenerationSupport
    import MLXGuidedGeneration
#endif
```
New (the test target now links `MLXGuidedGeneration` whenever FM is on):
```swift
#if FoundationModelsIntegration
    import MLXGuidedGeneration
#endif
```

- [ ] **Step 3: Fix the `GrammarErrorMappingTests` guard (line 131) in `MLXLanguageModelTests.swift`**

Old:
```swift
#if GuidedGenerationSupport
    @Suite("GrammarError typed mapping")
    struct GrammarErrorMappingTests {
```
New:
```swift
#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
    @Suite("GrammarError typed mapping")
    struct GrammarErrorMappingTests {
```
(The suite references `MLXLanguageModel.Executor`, which requires the FM adapter; `GrammarError` arrives with the engine, which is now present whenever the adapter is. Leave the matching `#endif` at line 188 as-is.)

- [ ] **Step 4: Fix `ToolCallingSchemaTests.swift` gate (line 3)**

Old:
```swift
#if FoundationModelsIntegration && GuidedGenerationSupport && canImport(FoundationModels, _version: 2)
```
New:
```swift
#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)
```
And the closing comment (line 259):
Old:
```swift
#endif  // FoundationModelsIntegration && GuidedGenerationSupport && canImport(FoundationModels)
```
New:
```swift
#endif  // FoundationModelsIntegration && canImport(FoundationModels)
```

- [ ] **Step 5: Fix `TestHelpers.swift` capability default (lines 76-78)**

Old:
```swift
                #if GuidedGenerationSupport
                    set += [.guidedGeneration, .toolCalling]
                #endif
```
New (guided generation + tool calling are always available when the adapter compiles; this helper is only reachable under `FoundationModelsIntegration`):
```swift
                set += [.guidedGeneration, .toolCalling]
```

- [ ] **Step 6: Build and run the test target (default config)**

Run:
```bash
swift test --disable-sandbox --skip-update -Xswiftc -disable-sandbox \
    --filter MLXFoundationModelsTests
```
Expected: PASS (build succeeds; the rewritten `TraitMatrixTests` FM-on arm runs).

- [ ] **Step 7: Commit**

```bash
git add Tests/MLXFoundationModelsTests/TraitMatrixTests.swift \
    Tests/MLXFoundationModelsTests/MLXLanguageModelTests.swift \
    Tests/MLXFoundationModelsTests/ToolCallingSchemaTests.swift \
    Tests/MLXFoundationModelsTests/TestHelpers.swift
git commit -m "test: collapse trait matrix tests to FoundationModelsIntegration only"
```

---

## Task 5: Remove the trait from `Package.swift`

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Delete the `GuidedGenerationSupport` trait definition (lines 58-66)**

Delete this block:
```swift
        // Grammar-constrained generation via the vendored xgrammar library.
        // Default-on. Disabling the trait removes MLXFoundationModels's
        // dependency on CXGrammar so consumers who don't need guided
        // generation skip compiling the vendored C++ source tree.
        .trait(
            name: "GuidedGenerationSupport",
            description:
                "Enables grammar-constrained generation via xgrammar. When disabled, MLXFoundationModels still builds and provides chat / tool calling, but guided-output APIs are unavailable."
        ),
```

- [ ] **Step 2: Update the default traits (line 67)**

Old:
```swift
        .default(enabledTraits: ["FoundationModelsIntegration", "GuidedGenerationSupport"]),
```
New:
```swift
        .default(enabledTraits: ["FoundationModelsIntegration"]),
```

- [ ] **Step 3: Re-key the `MLXGuidedGeneration` dependency in the `MLXFoundationModels` target (lines 257-260)**

Old:
```swift
                .target(
                    name: "MLXGuidedGeneration",
                    condition: .when(traits: ["GuidedGenerationSupport"])
                ),
```
New:
```swift
                .target(
                    name: "MLXGuidedGeneration",
                    condition: .when(traits: ["FoundationModelsIntegration"])
                ),
```

- [ ] **Step 4: Re-key the same dependency in the `MLXFoundationModelsTests` target (lines 271-274)**

Old:
```swift
                .target(
                    name: "MLXGuidedGeneration",
                    condition: .when(traits: ["GuidedGenerationSupport"])
                ),
```
New:
```swift
                .target(
                    name: "MLXGuidedGeneration",
                    condition: .when(traits: ["FoundationModelsIntegration"])
                ),
```

- [ ] **Step 5: Update the `MLXFoundationModels` target comment (lines 250-252)**

Old:
```swift
        // CXGrammar dependency is trait-conditional: with the
        // GuidedGenerationSupport trait disabled, the xgrammar backend is
        // not linked and grammar-constrained generation is unavailable.
```
New:
```swift
        // MLXGuidedGeneration dependency is trait-conditional: it is linked only
        // when FoundationModelsIntegration is enabled, since the adapter
        // references the engine exclusively inside that gate.
```

- [ ] **Step 6: Build the default configuration**

Run: `swift build --disable-sandbox --skip-update -Xswiftc -disable-sandbox`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Package.swift
git commit -m "build: remove GuidedGenerationSupport trait; key engine dep on FM trait"
```

---

## Task 6: Update the IntegrationTesting Xcode project

The IntegrationTesting project sets `GuidedGenerationSupport` as a Swift compilation condition (not an SPM trait) and gates ~27 test files on it.

**Files:**
- Modify: `IntegrationTesting/IntegrationTesting.xcodeproj/project.pbxproj` (lines 465, 483)
- Modify: the IntegrationTesting test files listed below

- [ ] **Step 1: Drop the condition from both build configurations (pbxproj lines 465 and 483)**

Both lines read:
```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) FoundationModelsIntegration GuidedGenerationSupport";
```
Change both to:
```
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) FoundationModelsIntegration";
```

- [ ] **Step 2: Remove the trait from every IntegrationTesting test file**

For each file below, transform its conditionals:
- `#if GuidedGenerationSupport && FoundationModelsIntegration` → `#if FoundationModelsIntegration`
- a standalone `#if GuidedGenerationSupport` → remove the guard and its matching `#endif`, keeping the body
- update any `#endif // …GuidedGenerationSupport…` trailing comments to match
- reword comments that mention the trait

Files (from `rg -l GuidedGenerationSupport IntegrationTesting`):
```
EmitStopSignalTests.swift          FMTestHelpers.swift
FastForwardTokenizationDisagreementTests.swift   ForkIndependenceTests.swift
GenerableRoundTripTests.swift      GoldenFixtureManifestTests.swift
GoldenReplayTests.swift            GuidedGenerationBenchmarkTests.swift
GuidedGenerationIntegrationTests.swift   GuidedGenerationTests.swift
HardReserveStressTests.swift       LoopInvariantsOnXGrammarTests.swift
MalformedSchemaErrorParityTests.swift    MaxTokenTruncationTests.swift
MultiModelCorrectnessTests.swift   PlainChatGenerationTests.swift
PrewarmGrammarTests.swift          RollbackDeterminismTests.swift
StopTokenRegressionIntegrationTests.swift   StreamingDeltaTests.swift
TokenizerVocabExtractorTests.swift ToolCallRoundTripTests.swift
ToolCallingIntegrationTests.swift  ToolCallingReasoningCharacterizationTests.swift
ToolCallingReasoningTests.swift    UpdateUsageEmissionTests.swift
XGrammarBridgeTests.swift
```
Per-file specifics to watch (verify each with `rg -n "GuidedGenerationSupport" <file>` before editing):
- `PlainChatGenerationTests.swift`, `GoldenReplayTests.swift`, `PrewarmGrammarTests.swift`, `XGrammarBridgeTests.swift`, `LoopInvariantsOnXGrammarTests.swift`: references are in comments only — reword them; do not change live conditionals beyond the rules above.
- `UpdateUsageEmissionTests.swift`, `ToolCallRoundTripTests.swift`, `MalformedSchemaErrorParityTests.swift`, `RollbackDeterminismTests.swift`, `XGrammarBridgeTests.swift`, `LoopInvariantsOnXGrammarTests.swift`: use `#if GuidedGenerationSupport && FoundationModelsIntegration` → reduce to `#if FoundationModelsIntegration` (and matching trailing `#endif` comment).
- All others: standalone `#if GuidedGenerationSupport` → remove guard + matching `#endif`.

- [ ] **Step 3: Verify no references remain in IntegrationTesting**

Run: `rg -n "GuidedGenerationSupport" IntegrationTesting`
Expected: no output.

- [ ] **Step 4: Build the IntegrationTesting scheme**

Run (adjust destination to an available simulator/SDK on the machine):
```bash
xcodebuild build-for-testing \
    -project IntegrationTesting/IntegrationTesting.xcodeproj \
    -scheme IntegrationTesting \
    -destination 'platform=macOS'
```
Expected: BUILD SUCCEEDED. If the scheme name differs, list schemes with `xcodebuild -list -project IntegrationTesting/IntegrationTesting.xcodeproj`.

- [ ] **Step 5: Commit**

```bash
git add IntegrationTesting
git commit -m "test: drop GuidedGenerationSupport from IntegrationTesting project"
```

---

## Task 7: Reduce and rename the build-matrix script

**Files:**
- Delete: `scripts/verify-trait-matrix.sh`
- Create: `scripts/verify-trait-builds.sh`

- [ ] **Step 1: Create the new two-arm script**

```bash
#!/usr/bin/env bash
#
# Builds both states of the package's sole remaining trait,
# FoundationModelsIntegration. The FM-off arm is the regression-prone one: a
# MLXGuidedGeneration type referenced outside the #if FoundationModelsIntegration
# gate in MLXFoundationModels would break it.
#
# Note: this repo's local dev environment requires --disable-sandbox and
# -Xswiftc -disable-sandbox (the Swift macro plugin server cannot be sandboxed
# here) plus --skip-update (network-restricted). CI uses plain `swift build`.
#
set -euo pipefail

FLAGS=(--disable-sandbox --skip-update -Xswiftc -disable-sandbox)

echo "==> [1/2] FoundationModelsIntegration ON (default)"
swift build "${FLAGS[@]}"

echo "==> [2/2] FoundationModelsIntegration OFF"
swift build "${FLAGS[@]}" --disable-default-traits

echo "PASS: both trait states build"
```

- [ ] **Step 2: Remove the old script and make the new one executable**

```bash
git rm scripts/verify-trait-matrix.sh
chmod +x scripts/verify-trait-builds.sh
```

- [ ] **Step 3: Run the new script to verify both arms build**

Run: `./scripts/verify-trait-builds.sh`
Expected: `PASS: both trait states build`. The FM-off arm confirms no engine type leaked outside the `#if FoundationModelsIntegration` gate.

- [ ] **Step 4: Commit**

```bash
git add scripts/verify-trait-builds.sh
git commit -m "build: replace trait matrix script with FM on/off build check"
```

---

## Task 8: Update documentation

**Files:**
- Modify: `README.md` (lines 32, 136-160)
- Modify: `Libraries/MLXFoundationModels/Documentation.docc/Documentation.md` (lines 48-76)
- Modify: `Libraries/MLXFoundationModels/Documentation.docc/guided-generation.md` (lines 20-40)

- [ ] **Step 1: README library blurb (line 32)**

Old:
```markdown
- [MLXFoundationModels](https://swiftpackageindex.com/ml-explore/mlx-swift-lm/main/documentation/mlxfoundationmodel): Bridge MLX models into Apple's `FoundationModels.LanguageModel` so they can plug into `LanguageModelSession`. Requires the macOS/iOS 27.0 SDK. Gated by two orthogonal package traits: `FoundationModelsIntegration` (the adapter types; default on) and `GuidedGenerationSupport` (grammar-constrained generation via xgrammar; default on).
```
New:
```markdown
- [MLXFoundationModels](https://swiftpackageindex.com/ml-explore/mlx-swift-lm/main/documentation/mlxfoundationmodel): Bridge MLX models into Apple's `FoundationModels.LanguageModel` so they can plug into `LanguageModelSession`. Requires the macOS/iOS 27.0 SDK. Gated by the `FoundationModelsIntegration` package trait (the adapter types; default on). Grammar-constrained generation comes from the separate `MLXGuidedGeneration` library, which this adapter always uses.
```

- [ ] **Step 2: README trait section (lines 136-160)**

Replace the block beginning `` `MLXFoundationModels` exposes two orthogonal SwiftPM traits, both default-on: `` through the closing ``` ``` ``` fence (line 160) with:
```markdown
`MLXFoundationModels` exposes one SwiftPM trait, default-on:

| Trait | Gates |
|---|---|
| `FoundationModelsIntegration` | The `MLXLanguageModel` / `MLXLanguageModel.Executor` adapter types that bridge to `FoundationModels.LanguageModel`. Requires the 27.0 SDK to compile. Disabling it compiles `MLXFoundationModels` down to `MLXDownloadProgress` alone. |

Grammar-constrained ("guided") generation lives in the separate
`MLXGuidedGeneration` product. `MLXFoundationModels` always uses it when the
adapter is compiled in, so guided output and tool calling are always available
there. To use guided generation without FoundationModels (older OS floors,
Linux), depend on `MLXGuidedGeneration` directly:

```swift
.package(
    url: "https://github.com/ml-explore/mlx-swift-lm",
    from: "3.33.0"
)
```

`FoundationModelsIntegration` is default-on; disable it with
`.disableDefaultTraits` (or by not enabling it) for iOS-17-era consumers that
want `MLXLLM` / `MLXLMCommon` without the FoundationModels adapter.
```

- [ ] **Step 3: Documentation.docc/Documentation.md trait section (lines 48-76)**

Replace the block from `` `MLXFoundationModels` is gated by two orthogonal SwiftPM traits, both `` through the closing ``` ``` ``` fence (line 76) with:
```markdown
`MLXFoundationModels` is gated by one SwiftPM trait, default-on:

- `FoundationModelsIntegration` controls the `MLXLanguageModel` /
  `MLXLanguageModel.Executor` surface. Disabling it compiles this target
  down to just ``MLXDownloadProgress``.

Grammar-constrained generation lives in the separate `MLXGuidedGeneration`
product, which this target always uses when the adapter is compiled in.

Consumer configurations:

| `FoundationModelsIntegration` | MLXLanguageModel | Guided generation | Chat / tools |
|---|---|---|---|
| On (default) | Yes | Yes | Yes |
| Off | No (symbol absent) | Use `MLXGuidedGeneration` directly | Only `MLXDownloadProgress` remains |
```

- [ ] **Step 4: guided-generation.md trait section (lines 20-40)**

Replace the section that starts at `## The `GuidedGenerationSupport` package trait` and runs through the end of the paragraph at line 40 (`literally vanish from the binary when the trait is off.`) with:
```markdown
## Where the engine lives

Schema enforcement is implemented by the separate `MLXGuidedGeneration`
library (the vendored xgrammar engine). `MLXFoundationModels` depends on it
whenever the FoundationModels adapter is compiled in (the
`FoundationModelsIntegration` trait, default-on), so guided output is always
available alongside the adapter. The FoundationModels-to-grammar glue lives in
`Libraries/MLXFoundationModels/GuidedGeneration/SchemaConverter.swift`.

To use guided generation without FoundationModels (older OS floors, Linux),
depend on the `MLXGuidedGeneration` product directly.
```

- [ ] **Step 5: Update the trailing paragraph of guided-generation.md (line 72-74)**

Old:
```markdown
For pure chat / completion with no schema, the trait doesn't change
output behavior; you can disable it to skip compiling the xgrammar
source tree.
```
New:
```markdown
For pure chat / completion with no schema, guided generation doesn't change
output behavior. To skip compiling the xgrammar source tree entirely, don't
link `MLXFoundationModels` or `MLXGuidedGeneration`.
```

- [ ] **Step 6: Verify docs build**

Run: `./scripts/verify-docs.sh`
Expected: documentation builds without warnings. (If the toolchain can't generate docs locally, at minimum confirm no remaining trait references with `rg -n "GuidedGenerationSupport" README.md Libraries/MLXFoundationModels/Documentation.docc` → no output.)

- [ ] **Step 7: Commit**

```bash
git add README.md Libraries/MLXFoundationModels/Documentation.docc
git commit -m "docs: describe guided generation as always-on via MLXGuidedGeneration"
```

---

## Task 9: Final verification (GREEN)

**Files:** none (verification only)

- [ ] **Step 1: Run the reference guard — it must now PASS**

Run: `./scripts/verify-no-guided-generation-trait.sh`
Expected: `PASS: no GuidedGenerationSupport references outside allowed paths`.

- [ ] **Step 2: Run the FM on/off build matrix**

Run: `./scripts/verify-trait-builds.sh`
Expected: `PASS: both trait states build`.

- [ ] **Step 3: Run the SwiftPM test suites**

Run:
```bash
swift test --disable-sandbox --skip-update -Xswiftc -disable-sandbox
```
Expected: PASS, including `MLXFoundationModelsTests`, `MLXGuidedGenerationTests`, and `CXGrammarTests`.

- [ ] **Step 4: Confirm clean tree**

Run: `git status --short`
Expected: no uncommitted changes (every task committed its work).

---

## Self-Review Notes

- **Spec coverage:** Package.swift trait removal + dependency re-key (Task 5); `MLXLanguageModel.swift` de-gating, `#else` and `guidedGenerationDisabled` deletion (Task 3); `SchemaConverter` gate (Task 2); test updates incl. TraitMatrixTests collapse and dropped `guidedGenerationDisabled` tests (Task 4); IntegrationTesting pbxproj + files (Task 6); script reduce/rename (Task 7); README + both docc files (Task 8); historical docs left untouched (excluded by the guard's `docs/superpowers/**` glob). All spec sections map to a task.
- **Public-API removal:** `MLXLanguageModelError.guidedGenerationDisabled` is deleted in Task 3 Step 1 and its tests removed in Task 4 Step 1 — consistent.
- **Type/name consistency:** `MLXGuidedGeneration`, `GrammarConstraint`, `GuidedGenerationLoop`, `GrammarError`, `MLXDownloadProgress`, `FoundationModelsIntegration` used consistently across tasks.
- **Line numbers** are pre-edit references; Task 3 instructs bottom-up deletion to avoid drift, and each editing task ends with a grep/build check rather than relying on line numbers alone.
