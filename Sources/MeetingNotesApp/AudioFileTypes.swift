import UniformTypeIdentifiers

/// File types the importer accepts.
///
/// `.audio` covers most of these already, but naming the common containers
/// explicitly means the open panel and drop target enable the right files even
/// when a type is not tagged as conforming to `public.audio`.
enum AudioFileTypes {
    static let all: [UTType] = {
        var types: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .mpeg4Movie]
        // FLAC has no UTType constant on macOS.
        if let flac = UTType(filenameExtension: "flac") { types.append(flac) }
        if let m4a = UTType(filenameExtension: "m4a") { types.append(m4a) }
        return types
    }()
}
