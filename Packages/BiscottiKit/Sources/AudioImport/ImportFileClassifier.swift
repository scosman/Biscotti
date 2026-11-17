import Foundation
import UniformTypeIdentifiers

/// Classifies files and declared types as import-supported or unsupported.
public enum ImportFileClassifier {
    /// Supported iff `type` conforms to `.audio` or `.audiovisualContent`.
    public static func isSupported(_ type: UTType) -> Bool {
        type.conforms(to: .audio) || type.conforms(to: .audiovisualContent)
    }

    /// Classifies a local URL by cheap resource values only (never opens it).
    /// Directories and packages -> false. Unknown type -> false.
    public static func isSupported(fileURL url: URL) -> Bool {
        let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey]
        )
        if values?.isDirectory == true || values?.isPackage == true {
            return false
        }
        let type = values?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return false }
        return isSupported(type)
    }

    /// Classifies a declared type identifier (file promises).
    public static func isSupported(typeIdentifier: String) -> Bool {
        guard let type = UTType(typeIdentifier) else { return false }
        return isSupported(type)
    }

    /// The open panel's / fileImporter's filter.
    public static let allowedContentTypes: [UTType] = [
        .audio, .audiovisualContent
    ]
}
