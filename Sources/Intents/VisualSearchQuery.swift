// The simulator SDK does not ship this framework, so it only builds for devices.
#if canImport(VisualIntelligence)
import AppIntents
import Foundation
import Vision
import VisualIntelligence

/// Results when the user analyses an image with Visual Intelligence. The system's labels are
/// generic ("poster"), so the search uses the text on the image: a cover without any text finds
/// nothing rather than something random.
struct MusicVisualSearchQuery: IntentValueQuery {
    func values(for input: SemanticContentDescriptor) async throws -> [MusicItemEntity] {
        guard let image = input.pixelBuffer else { return [] }
        let lines = image.withUnsafeBuffer { Self.textLines(in: $0) }
        return await AppEnvironment.shared.musicItems(forImageLines: lines)
    }

    private static func textLines(in image: CVPixelBuffer) -> [MusicIntentText.ImageLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cvPixelBuffer: image).perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return MusicIntentText.ImageLine(text: text, height: observation.boundingBox.height)
        }
    }
}
#endif
