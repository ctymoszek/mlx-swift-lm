# MLXGuidedGeneration: split guided generation into its own library

Date: 2026-06-11
Status: Approved for planning
Branch: mlx-foundationmodels

## Summary

Carve the xgrammar-backed guided generation engine out of `MLXFoundationModels`
into a standalone `MLXGuidedGeneration` library, so it is usable with MLX alone
(older Apple OS floors, Linux) without the FoundationModels dependency. At the
same time, isolate the vendored xgrammar C++ symbols by renaming their
namespaces at compile time, so the package can coexist in one binary with any
other xgrammar consumer (notably Apple's CoreAI, which links its own copy).

## Motivation

1. Community reach. In PR #334 review, the suggestion was raised to make
   guided generation its own library: "people might want to use it outside of
   just a pure foundation-model context but still mlx." On Linux,
   FoundationModels does not exist at all, but the guided generation piece is
   still useful. Today the engine sits behind `@available(macOS 27 / iOS 27)`
   and `#if canImport(FoundationModels)`, which is incidental packaging rather
   than a real dependency.
2. Symbol-collision safety. A single app can link both `MLXFoundationModels`
   and CoreAI's `CoreAILanguageModels`. Both vendor xgrammar. CoreAI ships a
   prebuilt static-library xcframework whose C++ symbols use the vanilla
   `xgrammar::` namespace; our vendored source emits the same symbols. Two
   strong definitions of `xgrammar::*` in one link collide (duplicate symbol,
   or silent ODR pick if versions differ). Renaming our namespace removes the
   overlap unilaterally, with no cross-team coordination.

## Goals

- A new `MLXGuidedGeneration` SwiftPM library product that depends only on
  `CXGrammar`, `MLXLMCommon`, and `MLX`. No FoundationModels, no `@available`
  version floor beyond the package's existing macOS 14 / iOS 17.
- A deliberate public API for that library (not a blanket `public` of internal
  types), using descriptive `Grammar*` names.
- Compile-time isolation of the vendored xgrammar (and bundled picojson)
  symbols so the package never collides with another xgrammar in the same
  binary.
- No behavior change for existing `MLXFoundationModels` consumers, including
  those who disable the `GuidedGenerationSupport` trait.

## Non-goals (explicitly deferred)

- Bumping xgrammar from v0.1.30 to v0.2.2. Held for a later pass to keep this
  refactor's blast radius small. Consequences of staying on v0.1.30: the
  `grammar_functor_wrapper.cc` ODR workaround stays, `xg_matcher_fork` stays a
  stub, `GrammarConstraint.clone()` keeps its recompile-fallback behavior, and
  `ForkIndependenceTests` stays `.disabled`.
- Converting the vendored source into an external versioned SwiftPM dependency
  (the "forked package with renames baked in" option). Source stays in-repo
  under `Sources/CXGrammar`, refreshed by the existing sync script, pinned to
  the release tag `v0.1.30` (see Version pinning below).
- Renaming the type prefix beyond `XG* -> Grammar*` (no further API churn).

## Why not depend on the official xgrammar Swift package?

(Written for posterity. This section is intended to be lifted, largely intact,
into the `MLXGuidedGeneration` library's own documentation once it exists.)

As of v0.2.1 (June 2026), upstream mlc-ai/xgrammar ships its own SwiftPM
manifest exposing an `XGrammar` product. The natural question is why this
project vendors the C++ source and maintains a hand-written C shim instead of
just adding that package as a dependency. The reasons, in order of weight:

1. A C++ exception-catching shim is mandatory either way.
   The official package exposes only the raw C++ API: no `extern "C"` layer, no
   Swift wrappers, errors surfaced as C++ exceptions and `std::variant`.
   xgrammar's compile and construct entry points throw. Swift cannot catch C++
   exceptions; an uncaught exception that crosses into Swift terminates the
   process. So a C++ layer that catches exceptions and maps them to status
   codes is required regardless of where the source comes from. The package
   does not let us delete the shim; it only changes the source of the code the
   shim wraps.

2. Symbol isolation requires compiling the source ourselves.
   This library renames the `xgrammar` and `picojson` C++ namespaces so it can
   coexist in a single binary with other xgrammar consumers. Concrete case:
   Apple's CoreAI ships its own prebuilt xgrammar (a static-library
   xcframework) whose symbols use the vanilla `xgrammar::` namespace. Our
   vendored copy emits the same symbols, so two copies in one link collide
   (duplicate symbol, or a silent ODR pick if the versions differ). Renaming
   our namespace removes the overlap unilaterally, with no coordination.

   That rename is a compile-time preprocessor define applied to the xgrammar
   source. In SwiftPM, build settings (`cxxSettings`, `.define`, flags) apply
   only to the target that declares them; a consumer cannot inject a define
   into a dependency's compilation, and there is no symbol-rewrite step in the
   build graph. To rename the symbols we must own their compilation, which
   means vendoring (or a fork we build). Depending on the stock package bakes
   in vanilla `xgrammar::` symbols we have no way to rename.

3. A shared package forces version convergence, not isolation.
   SwiftPM resolves a single version per package across the whole dependency
   graph and refuses two versions of the same package. If two independent
   projects both depended on mlc-ai/xgrammar, an app combining them would be
   forced onto one shared version. These projects ship independently and may
   need different xgrammar versions, so a shared package works against the goal
   rather than for it. Vendoring lets each project pin and isolate its own
   version freely.

4. The Swift/C++ interop the package needs buys us nothing here.
   Importing the raw C++ package requires enabling Swift/C++ interoperability
   and working through `DLTensor`, `std::variant`, and `std::optional` at the
   call site. Our C shim presents a stable, plain-C boundary that Swift imports
   cleanly with no interop. Because the shim is needed anyway (point 1),
   adopting interop would be pure added fragility for no gain.

What we give up by vendoring, and why it is acceptable:
- Manual refresh via `scripts/sync-xgrammar-source.sh` instead of SemVer
  resolution. We preserve legibility by pinning to the release tag (`v0.1.30`)
  rather than a raw SHA.
- Carrying the source tree in-repo plus the small ODR workaround
  (`grammar_functor_wrapper.cc`).

The package's genuine upsides (shedding the vendored tree, automatic version
bumps, and newer features such as `Fork()` and batch matching) are either
capabilities we deliberately want to control or are addressed by a future,
deliberate version bump. They do not outweigh the isolation and
exception-handling requirements above.

When to revisit: this decision should be reconsidered if upstream adds a
maintained `extern "C"` API together with a built-in symbol-isolation
mechanism, or if the multi-consumer collision scenario (e.g. shipping alongside
CoreAI) stops applying.

## Decisions

| Decision | Choice |
|---|---|
| xgrammar sourcing | Vendored in-repo `CXGrammar` target (unchanged location) |
| xgrammar version | Stay on v0.1.30; pin to the release tag `v0.1.30`, not the raw SHA; bump deferred |
| Namespace rename prefix | `mlx_` (community-facing, not FM-specific) |
| Opt-in mechanism | Keep the `GuidedGenerationSupport` trait |
| Public type naming | `Grammar*`, unprefixed (module carries the MLX brand) |

## Architecture

Layered target graph (arrows point to dependencies):

```
CXGrammar  (C/C++: vendored xgrammar v0.1.30 + shim; namespaces renamed)
   ^
MLXLMCommon  (unchanged shared base; LogitProcessor protocol stays here)
   ^                              ^
MLXGuidedGeneration  -------------+   (NEW; depends on CXGrammar + MLXLMCommon + MLX)
   ^                                   floor: macOS 14 / iOS 17 / Linux; no FoundationModels
MLXFoundationModels  (depends on MLXGuidedGeneration via the trait; FM glue; @available 27)
```

The clean seam: `GrammarConstraint` consumes a schema or grammar **string**
(JSON Schema, EBNF, or structural tag). FoundationModels coupling is isolated
entirely in `SchemaConverter`, which produces that string from a
`GenerationSchema` / `[Transcript.ToolDefinition]`. Anything that already has a
JSON schema can drive the engine directly, with no FM types involved.

## File migration

| File | Today | After |
|---|---|---|
| `XGrammarBridge.swift` | `MLXFoundationModels/GuidedGeneration` | `MLXGuidedGeneration` |
| `GuidedGenerationLoop.swift` | `MLXFoundationModels/GuidedGeneration` | `MLXGuidedGeneration` |
| `TokenizerVocabExtractor.swift` | `MLXFoundationModels/GuidedGeneration` | `MLXGuidedGeneration` |
| `MaskSnapshot.swift` | `MLXFoundationModels/GuidedGeneration` | `MLXGuidedGeneration` |
| `GuidedGenerationError.swift` | `MLXFoundationModels/GuidedGeneration` | `MLXGuidedGeneration` |
| `CompositeLogitProcessor.swift` | `MLXLMCommon/GuidedGeneration` | `MLXGuidedGeneration` |
| `WhitespaceTokenBias.swift` | `MLXLMCommon/GuidedGeneration` | `MLXGuidedGeneration` |
| `SchemaConverter.swift` | `MLXFoundationModels/GuidedGeneration` | stays (FM->string adapter) |
| `MLXLanguageModel.swift`, `ModelProfile`, `ModelCustomizer`, `ModelCache` | `MLXFoundationModels` | stays |

Verified that nothing in `MLXLMCommon` core or `MLXLLM` / `MLXVLM` /
`MLXEmbedders` references `CompositeLogitProcessor` or `WhitespaceTokenBias`, so
moving them up out of the shared base is safe. Their only consumers are the
guided-gen loop and `MLXLanguageModel.swift` (which will reach them through
`MLXGuidedGeneration`).

## Package.swift changes

New product:

```swift
.library(name: "MLXGuidedGeneration", targets: ["MLXGuidedGeneration"]),
```

`CXGrammar` target gains the rename defines (location and vendored tree
unchanged):

```swift
cxxSettings: [
    // existing header search paths and XGRAMMAR_* defines ...
    .define("xgrammar", to: "mlx_xgrammar"),
    .define("picojson", to: "mlx_picojson"),
],
```

New engine target:

```swift
.target(
    name: "MLXGuidedGeneration",
    dependencies: [
        "MLXLMCommon",
        "CXGrammar",                       // unconditional: this library is guided generation
        .product(name: "MLX", package: "mlx-swift"),
    ],
    path: "Libraries/MLXGuidedGeneration"
),
```

`MLXFoundationModels` target: the trait now gates the dependency on the engine
instead of on `CXGrammar` directly. The direct `CXGrammar` dependency is
removed (it arrives transitively):

```swift
.target(
    name: "MLXFoundationModels",
    dependencies: [
        "MLXLMCommon",
        .target(name: "MLXGuidedGeneration",
                condition: .when(traits: ["GuidedGenerationSupport"])),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
    ],
    path: "Libraries/MLXFoundationModels"
),
```

Tests:
- `CXGrammarTests` (direct C-API tests) are unaffected by the rename, since the
  rename does not touch the `xg_*` C surface. They keep depending on `CXGrammar`.
- A new `MLXGuidedGenerationTests` target should own the FM-independent tests
  that currently live under `MLXFoundationModelsTests` (e.g. mask/constraint/
  fork tests). FM-specific tests stay in `MLXFoundationModelsTests`.

## Trait wiring after the split

The `GuidedGenerationSupport` semantics are preserved, just relocated one layer
up:

- `MLXGuidedGeneration` depends on `CXGrammar` unconditionally. If a consumer
  links this product, they want xgrammar.
- `MLXFoundationModels` depends on `MLXGuidedGeneration` only when
  `GuidedGenerationSupport` is enabled (the default). With the trait off, FM
  compiles chat + tool calling with zero xgrammar, exactly as today.
- `SchemaConverter.swift` stays gated under
  `#if FoundationModelsIntegration && GuidedGenerationSupport`.
- The `WhitespaceTokenBias.compute(...)` call sites in `MLXLanguageModel.swift`
  must sit inside the same trait gate, since they now reference types that live
  in `MLXGuidedGeneration`. This is the one wiring detail that must be correct
  for the trait-off build to keep compiling.

## Public API surface

These types become the deliberate public API of `MLXGuidedGeneration`. Rename
from the current internal `XG*` names to descriptive `Grammar*` names; the
module name already provides the MLX brand, so types are not MLX-prefixed
(matching `ModelContext` / `LogitProcessor` in `MLXLMCommon`).

| New name | Was | Role |
|---|---|---|
| `GrammarTokenizer` | `XGTokenizer` | build from vocab + `VocabType` + stop token |
| `GrammarConstraint` | `XGConstraint` | init from JSON-schema / EBNF / structural-tag string; `computeMask` / `commitToken` / `rollback` / `clone` |
| `MaskResult` | `XGMaskResult` | matcher mask step result |
| `CommitResult` | `XGCommitResult` | token-commit / fast-forward result |
| `GrammarError` | `XGError` | bridge error surface |
| `GuidedGenerationLoop` | (same) | orchestration entry over a `ModelContext` |
| `GuidedGenerationError` | (same) | loop-level errors (incompleteOutput, prematureEOS) |
| `TokenizerVocabExtractor` | (same) | build a `GrammarTokenizer` from a HF tokenizer |
| `CompositeLogitProcessor` | (same) | chain logit processors |
| `WhitespaceTokenBias` | (same) | whitespace-only token bias |

Audit each declaration's access level when moving it: expose only what a
standalone consumer needs, keeping internals `internal`. This directly answers
the "should this be public?" questions raised in the PR review.

## Version pinning

The vendored xgrammar is pinned to the upstream release **tag `v0.1.30`**, not
the raw commit SHA. Rationale: a tag is legible (you can see at a glance which
release you are on and reason about upgrades), whereas a bare SHA
(`d476a48...`) is opaque.

- `scripts/sync-xgrammar-source.sh` is invoked with `v0.1.30` as its
  `<sha-or-tag>` argument.
- `Sources/CXGrammar/xgrammar/VERSION` records `v0.1.30` as the canonical pin.
  The resolved SHA may be retained alongside it as an informational note for
  reproducibility, but the tag is the pin of record.
- `kXGrammarVersion` in `shim.cc` reflects `v0.1.30`.

This is a documentation and pin-hygiene change only; the actual source tree is
the same v0.1.30 snapshot already vendored.

## Symbol isolation: mechanism and verification

The rename is a preprocessor token substitution applied where the C++ is
compiled (the `CXGrammar` target). `-Dxgrammar=mlx_xgrammar` rewrites every bare
`xgrammar` identifier (namespace declarations and `xgrammar::` uses) across both
the vendored tree and `shim.cc`, which are in the same target and so stay
consistent. `-Dpicojson=mlx_picojson` does the same for the bundled picojson,
which lives in its own namespace and is therefore not covered by the xgrammar
rename.

What the rename does and does not touch:
- Renamed: the `xgrammar::` and `picojson::` C++ namespaces (the strong symbols
  that actually cause duplicate-symbol link errors).
- Not touched, and safe anyway: standard library template instantiations
  (`std::__1::...`) and picojson inline members are emitted as weak,
  coalesced symbols ("weak external automatically hidden"). The linker merges
  duplicates rather than erroring. dlpack is a C header of struct and enum
  definitions with no out-of-line symbols, so it cannot collide; it is also
  part of the bitmask C API, so it must not be renamed.
- Not touched, and already distinct: our `xg_*` / `XG*` C bridge symbols, which
  differ from CoreAI's `xgrammar_*` / `XGrammar*` bridge names.

Acceptance check after applying the defines: build clean, then `nm` the
compiled `CXGrammar` objects and confirm (a) `mlx_xgrammar::` and
`mlx_picojson::` symbols appear, (b) zero strong `xgrammar::` / `picojson::`
symbols remain, and (c) the `xg_*` C surface is unchanged so the Swift side
needs no edits.

## Risks and mitigations

- Rename misfire: `-Dxgrammar=` would also rewrite any non-namespace bare
  `xgrammar` identifier (e.g. a variable named `xgrammar`). Mitigation: test
  compile; the substitution is token-level so it does not touch string
  literals, `XGRAMMAR_*` macros, or `xgrammar_*` tokens. Low risk for this
  codebase.
- Trait-off build regression: if a moved type is referenced outside the trait
  gate in `MLXFoundationModels`, the `GuidedGenerationSupport`-off build breaks.
  Mitigation: build both trait configurations in CI; verify the
  `WhitespaceTokenBias` call sites are gated.
- Public-API over-exposure: blanket `public` would lock in a surface that is
  hard to change later. Mitigation: explicit per-declaration access review.
- Test relocation gaps: moving FM-independent tests must not silently drop
  coverage. Mitigation: confirm test counts before and after; ensure the new
  `MLXGuidedGenerationTests` target builds without FoundationModels.

## Testing

- Existing `CXGrammarTests` continue to pass unchanged (rename does not affect
  the C surface).
- New `MLXGuidedGenerationTests` build and run without FoundationModels,
  covering constraint compile / mask / commit / rollback / vocab extraction.
- `MLXFoundationModelsTests` continue to pass with the trait on.
- Build matrix: `GuidedGenerationSupport` on and off; `FoundationModelsIntegration`
  on and off. The trait-off and FM-off combination must compile.
- Symbol acceptance check (above) runs as part of verification.

## Implementation outline (detail belongs to the plan)

1. Add the `mlx_xgrammar` / `mlx_picojson` rename defines to `CXGrammar`;
   re-pin the vendored source to tag `v0.1.30` in the sync script, `VERSION`,
   and `kXGrammarVersion`; verify the symbol acceptance check.
2. Create `Libraries/MLXGuidedGeneration` and move the seven FM-independent
   files into it; add the target and product to `Package.swift`.
3. Rename `XG*` types to `Grammar*` and set deliberate access levels.
4. Re-point `MLXFoundationModels` at `MLXGuidedGeneration` through the trait;
   gate the `WhitespaceTokenBias` call sites; keep `SchemaConverter` in FM.
5. Split tests into `MLXGuidedGenerationTests` (FM-independent) and the existing
   FM test target; run the full build matrix.
