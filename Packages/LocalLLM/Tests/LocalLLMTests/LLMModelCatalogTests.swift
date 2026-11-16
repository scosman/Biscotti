import Foundation
import Testing
@testable import LocalLLM

@Suite("LLMModelCatalog")
struct LLMModelCatalogTests {
    @Test("Catalog contains exactly three models")
    func catalogCount() {
        #expect(LLMModelCatalog.all.count == 3)
    }

    @Test("Catalog IDs are distinct and non-empty")
    func catalogIDsDistinctAndNonEmpty() {
        let ids = LLMModelCatalog.all.map(\.id)
        for id in ids {
            #expect(!id.isEmpty, "Model ID must not be empty")
        }
        #expect(Set(ids).count == ids.count, "Model IDs must be unique")
    }

    @Test("Catalog display names are distinct and non-empty")
    func catalogDisplayNames() {
        let names = LLMModelCatalog.all.map(\.displayName)
        for name in names {
            #expect(!name.isEmpty)
        }
        #expect(Set(names).count == names.count, "Display names must be unique")
    }

    @Test("Catalog download URLs are distinct and well-formed HTTPS")
    func catalogURLs() {
        let urls = LLMModelCatalog.all.map(\.downloadURL)
        for url in urls {
            #expect(url.scheme == "https")
            #expect(url.host != nil)
        }
        let urlStrings = urls.map(\.absoluteString)
        #expect(Set(urlStrings).count == urlStrings.count, "Download URLs must be unique")
    }

    @Test("Catalog filenames are distinct and non-empty")
    func catalogFilenames() {
        let filenames = LLMModelCatalog.all.map(\.fileName)
        for name in filenames {
            #expect(!name.isEmpty)
        }
        #expect(Set(filenames).count == filenames.count, "Filenames must be unique")
    }

    @Test("Catalog approxDownloadBytes are positive for each model")
    func catalogDownloadSizes() {
        for model in LLMModelCatalog.all {
            #expect(model.approxDownloadBytes > 0, "\(model.id) download size must be positive")
        }
    }

    @Test("Display order is largest first: 12B, E4B, E2B")
    func catalogOrder() {
        let ids = LLMModelCatalog.all.map(\.id)
        #expect(ids == ["gemma-4-12b", "gemma-4-e4b", "gemma-4-e2b"])
    }

    @Test("model(id:) returns correct entry for known IDs")
    func lookupKnown() {
        let model12b = LLMModelCatalog.model(id: "gemma-4-12b")
        #expect(model12b?.displayName == "Gemma 4 12B")
        #expect(model12b?.id == "gemma-4-12b")

        let modelE4b = LLMModelCatalog.model(id: "gemma-4-e4b")
        #expect(modelE4b?.displayName == "Gemma 4 E4B")
        #expect(modelE4b?.id == "gemma-4-e4b")

        let modelE2b = LLMModelCatalog.model(id: "gemma-4-e2b")
        #expect(modelE2b?.displayName == "Gemma 4 E2B")
        #expect(modelE2b?.id == "gemma-4-e2b")
    }

    @Test("E4B entry points at the unsloth QAT Q4_K_XL GGUF")
    func e4bDownloadCoordinates() throws {
        let modelE4b = try #require(LLMModelCatalog.model(id: "gemma-4-e4b"))
        #expect(
            modelE4b.downloadURL.absoluteString
                == "https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF/resolve/main/gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf"
        )
        #expect(modelE4b.fileName == "gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf")
        #expect(modelE4b.approxDownloadBytes == 5_000_000_000)
    }

    @Test("model(id:) returns nil for unknown ID")
    func lookupUnknown() {
        #expect(LLMModelCatalog.model(id: "nonexistent") == nil)
        #expect(LLMModelCatalog.model(id: "") == nil)
    }

    @Test("12B catalog entry matches existing defaultModelURL")
    func twelveBMatchesLegacyURL() {
        let model12b = LLMModelCatalog.model(id: "gemma-4-12b")
        #expect(model12b?.downloadURL == ModelDownloader.defaultModelURL)
        #expect(model12b?.fileName == ModelDownloader.defaultModelURL.lastPathComponent)
    }

    @Test("Each model's fileName matches its downloadURL lastPathComponent")
    func fileNameMatchesURL() {
        for model in LLMModelCatalog.all {
            #expect(
                model.fileName == model.downloadURL.lastPathComponent,
                "\(model.id) fileName must match downloadURL.lastPathComponent"
            )
        }
    }
}
