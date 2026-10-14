import SwiftUI
import UniformTypeIdentifiers

/// A PNG image to save with `fileExporter`.
struct PNGDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.png]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
