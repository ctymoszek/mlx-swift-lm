// Copyright © 2026 Apple Inc.

import Foundation
import FoundationModels
import Hub
import HuggingFace
import MLXFoundationModels
import MLXHuggingFace
import MLXLMCommon
import Testing
import Tokenizers

@Suite("#huggingFaceLanguageModel")
struct HuggingFaceLanguageModelMacroTests {

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    @Test("Builds a model with the given id and default guided-generation capability")
    func buildsModelWithDefaults() {
        let model = #huggingFaceLanguageModel(
            configuration: ModelConfiguration(id: "mlx-community/Qwen3-4B-4bit"))
        #expect(model.modelID == "mlx-community/Qwen3-4B-4bit")
        #expect(model.capabilities.contains(.guidedGeneration))
    }

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    @Test("Forwards an explicit capability set")
    func forwardsExplicitCapabilities() {
        let model = #huggingFaceLanguageModel(
            configuration: ModelConfiguration(id: "mlx-community/Qwen3-4B-4bit"),
            capabilities: [.guidedGeneration, .toolCalling])
        #expect(model.capabilities.contains(.toolCalling))
    }
}
