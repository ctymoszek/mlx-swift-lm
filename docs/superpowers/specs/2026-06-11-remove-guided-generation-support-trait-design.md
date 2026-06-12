# Remove the `GuidedGenerationSupport` package trait

Date: 2026-06-11
Status: Approved for planning
Branch: mlx-foundationmodels

## Summary

The guided-generation engine now lives in its own `MLXGuidedGeneration`
library and product (see `2026-06-11-mlx-guided-generation-library-split-design.md`).
With that split done, the `GuidedGenerationSupport` trait no longer earns its
keep: it gated whether `MLXFoundationModels` *optionally* pulled in the engine,
but `MLXFoundationModels` should always use `MLXGuidedGeneration`. Remove the
trait entirely. `MLXFoundationModels` depends on `MLXGuidedGeneration` whenever
its FoundationModels adapter is compiled in, and guided generation is no longer
an optional, separately-toggled capability within that adapter.

`FoundationModelsIntegration` is the only package trait that survives.

## Motivation

- The trait predates the library split. Before the split, guided generation
  was code physically inside `MLXFoundationModels`, and the trait let a
  consumer compile it out (skipping the ~1 MB xgrammar C++ tree). Now the
  engine is its own product that anyone can link directly, so "guided
  generation without FoundationModels" is served by linking
  `MLXGuidedGeneration`, not by a trait on `MLXFoundationModels`.
- Two orthogonal traits produced a four-cell build matrix, a degraded
  "guided-generation disabled" code path inside the adapter, and a dedicated
  `MLXLanguageModelError.guidedGenerationDisabled` error. Collapsing to one
  trait removes that complexity: the adapter always has guided generation when
  it exists at all.

## Decision: how `MLXFoundationModels` depends on `MLXGuidedGeneration`

`MLXFoundationModels` references `MLXGuidedGeneration` types only inside its
`#if FoundationModelsIntegration` gate. So the dependency edge should exist
exactly when that gate is open. We condition the edge on
`FoundationModelsIntegration` rather than making it unconditional, so an
FM-off build of `MLXFoundationModels` does not drag in xgrammar it cannot use.

```swift
.target(
    name: "MLXFoundationModels",
    dependencies: [
        "MLXLMCommon",
        .target(name: "MLXGuidedGeneration",
                condition: .when(traits: ["FoundationModelsIntegration"])),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
    ],
    path: "Libraries/MLXFoundationModels"
),
```

The condition lives on this edge and nowhere else. It does **not** touch the
`MLXGuidedGeneration` product or target, so linking `MLXGuidedGeneration`
directly is entirely independent of the trait.

### Resulting linkage matrix

| What the consumer links | `FoundationModelsIntegration` | What builds |
|---|---|---|
| `MLXGuidedGeneration` only | irrelevant | MGG (the trait condition is on MFM's edge, which isn't in play) |
| `MLXFoundationModels` | on | MFM adapter + MGG (transitively) |
| `MLXFoundationModels` | off | empty MFM module only; MGG **not** pulled |
| both products | on/off | MGG always (direct link); MFM adapter follows the trait |

### Known residual imperfection

SwiftPM dependency conditions cannot key off `canImport`. The adapter has a
second, inner gate: `#if canImport(FoundationModels, _version: 2)`. So when a
consumer builds with `FoundationModelsIntegration` **on** but against an SDK
older than the 27 SDK, the adapter body still compiles to empty (the inner
gate is closed), yet `MLXGuidedGeneration` is pulled in because the trait
condition is satisfied. This is narrow and unavoidable; it builds unused C++
only in that specific SDK/trait combination.

## The `FoundationModelsIntegration` trait (unchanged, for reference)

`FoundationModelsIntegration` is a compile-time on/off switch for the
FoundationModels adapter surface inside the `MLXFoundationModels` target. The
entire body of `MLXLanguageModel.swift` (and `SchemaConverter.swift`) is
wrapped in `#if FoundationModelsIntegration`, nested inside
`#if canImport(FoundationModels, _version: 2)`. With the trait off,
`MLXFoundationModels` compiles to an effectively empty module: only
`MLXDownloadProgress` survives, because it lives outside the gate
(`MLXDownloadProgress.swift:24`). This trait is not modified by this work.

## Changes

### Package.swift
- Delete the `GuidedGenerationSupport` trait definition.
- Drop it from `.default(enabledTraits:)`, leaving `["FoundationModelsIntegration"]`.
- In the `MLXFoundationModels` target, change the `MLXGuidedGeneration`
  dependency condition from `.when(traits: ["GuidedGenerationSupport"])` to
  `.when(traits: ["FoundationModelsIntegration"])`.
- In the `MLXFoundationModelsTests` target, apply the same condition change to
  its `MLXGuidedGeneration` dependency.

### Libraries/MLXFoundationModels/MLXLanguageModel.swift
The adapter currently has ~14 `#if GuidedGenerationSupport` blocks plus a
`#else` fallback. Since guided generation is now always present whenever the
adapter compiles:
- For each `#if GuidedGenerationSupport` block, delete the guard lines and keep
  the body unconditionally. This includes `import MLXGuidedGeneration` (line
  19), the cached-tokenizer/constraint fields in `ModelCache` (line 45), the
  guided-output and tool-calling generation paths, the think-then-call phase
  split, and the `GrammarError` remap in the `catch` block.
- Delete the `#else` / `#if !GuidedGenerationSupport` branches outright,
  including:
  - the unconstrained text-only fallback path that throws on schema/tool
    requests (around lines 1312-1339), and
  - the `MLXLanguageModelError` enum and its `guidedGenerationDisabled` case
    (lines 1835-1844).
  This removes the `guidedGenerationDisabled` public symbol; it only existed in
  the FM-on / GG-off configuration, which no longer exists.

### Libraries/MLXFoundationModels/GuidedGeneration/SchemaConverter.swift
- Change `#if FoundationModelsIntegration && GuidedGenerationSupport` to
  `#if FoundationModelsIntegration` (and the matching trailing `#endif`
  comment).

### Tests (Tests/MLXFoundationModelsTests)
- `TraitMatrixTests.swift`: collapse from four trait combinations to two
  (FM on / FM off). Remove the `GuidedGenerationSupport` import gate and the
  two GG-only / neither-trait arms. Drop the three "FM on, GG off:
  guidedGenerationDisabled" behavioral tests, since that error and path are
  gone. The FM-on arm keeps asserting that `MLXLanguageModel` and the
  guided-generation primitives compile together.
- `MLXLanguageModelTests.swift`, `ToolCallingSchemaTests.swift`,
  `TestHelpers.swift`: remove the `#if GuidedGenerationSupport` guards; the
  guarded bodies become unconditional (these tests run under the default
  build, which always has the adapter + engine).

### IntegrationTesting (separate xcodeproj, not SPM traits)
The IntegrationTesting project defines `GuidedGenerationSupport` as a Swift
compilation condition in build settings
(`IntegrationTesting.xcodeproj/project.pbxproj` lines 465, 483), alongside
`FoundationModelsIntegration`.
- Remove `GuidedGenerationSupport` from `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
  in both configurations, keeping `FoundationModelsIntegration`.
- In the affected test files (~27 reference the trait; several only in
  comments), remove `#if GuidedGenerationSupport` guards. Where a guard is
  `#if GuidedGenerationSupport && FoundationModelsIntegration`, reduce it to
  `#if FoundationModelsIntegration`. Comments referencing the trait are updated
  to match.

### Tooling
- `scripts/verify-trait-matrix.sh`: reduce from the four-arm matrix to two arms
  (FM on, FM off). Rename to `scripts/verify-trait-builds.sh` to reflect that
  there is no longer a matrix. The FM-off arm remains the regression-prone one:
  if a `MLXGuidedGeneration` type is referenced outside the
  `#if FoundationModelsIntegration` gate, that arm fails.

### Documentation
- `Libraries/MLXFoundationModels/Documentation.docc/guided-generation.md`:
  remove the "The `GuidedGenerationSupport` package trait" section. Describe
  guided generation as always present within `MLXFoundationModels`, and point
  readers who want it without FoundationModels at the `MLXGuidedGeneration`
  product.
- `Libraries/MLXFoundationModels/Documentation.docc/Documentation.md`: remove
  the `GuidedGenerationSupport` rows/entries from the trait tables; keep the
  `FoundationModelsIntegration` description.
- `README.md`: remove `GuidedGenerationSupport` from the trait list and the
  trait-combination table; update the "Requires the 27 SDK" / traits paragraph
  to mention only `FoundationModelsIntegration` and the separate
  `MLXGuidedGeneration` product.

### Out of scope (historical records, leave unchanged)
- `docs/superpowers/plans/2026-06-11-mlx-guided-generation-library-split.md`
- `docs/superpowers/specs/2026-06-11-mlx-guided-generation-library-split-design.md`

These document completed work and should retain their original trait
references.

## Public API impact

- Removed: `MLXLanguageModelError.guidedGenerationDisabled` (and the
  `MLXLanguageModelError` enum, which had only that case). This symbol existed
  only in the FM-on / GG-off build, a configuration this change eliminates.
- No other public surface changes. `MLXGuidedGeneration`'s `Grammar*` API is
  untouched.

## Testing

- Build matrix collapses to two arms; both must build:
  - `FoundationModelsIntegration` on (default).
  - `FoundationModelsIntegration` off (`--disable-default-traits`): MFM is the
    empty module, MGG is not pulled by MFM.
- `MLXFoundationModelsTests` pass under the default build.
- `MLXGuidedGenerationTests` and `CXGrammarTests` are unaffected (they do not
  reference the trait) and continue to pass.
- IntegrationTesting xcodeproj builds and runs with `FoundationModelsIntegration`
  defined and `GuidedGenerationSupport` removed.
- Grep check: no `GuidedGenerationSupport` references remain outside the two
  historical docs listed under "Out of scope".

## Risks and mitigations

- A `MLXGuidedGeneration` symbol referenced outside the
  `#if FoundationModelsIntegration` gate would break the FM-off build.
  Mitigation: `verify-trait-builds.sh` builds the FM-off arm.
- Missed `#if GuidedGenerationSupport` guard (source or test) leaves a dangling
  condition that silently compiles to nothing. Mitigation: the final grep
  check asserts zero remaining references outside the historical docs.
- IntegrationTesting build-setting change is easy to forget since it lives in
  the xcodeproj, not SPM. Mitigation: explicit step in the plan plus the grep
  check covers the pbxproj.
