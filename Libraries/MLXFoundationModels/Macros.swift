// Copyright © 2026 Apple Inc.

#if FoundationModelsIntegration && canImport(FoundationModels, _version: 2)

    import Foundation
    import FoundationModels
    import MLXLMCommon

    /// Builds an ``MLXLanguageModel`` backed by HuggingFace downloading and
    /// tokenizer loading, so a configuration is all the caller provides.
    ///
    /// Expands to the `MLXLanguageModel` initializer with the HuggingFace hub
    /// downloader, tokenizer loader, and on-disk weights resolver supplied for
    /// you. The call site must import `MLXFoundationModels`, `MLXHuggingFace`,
    /// `MLXLMCommon`, `HuggingFace`, `Tokenizers`, and `Hub`.
    ///
    /// ```swift
    /// let model = #huggingFaceLanguageModel(configuration: LLMRegistry.gemma3_1B_qat_4bit)
    /// let session = LanguageModelSession(model: model)
    /// ```
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    @freestanding(expression)
    public macro huggingFaceLanguageModel(
        configuration: ModelConfiguration,
        capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration],
        configurationResolver: any ModelConfigurationResolver = DefaultConfigurationResolver()
    ) -> MLXLanguageModel =
        #externalMacro(module: "MLXHuggingFaceMacros", type: "HuggingFaceLanguageModelMacro")

#endif
