import Foundation

/// A source adapter owns exactly two decisions: whether it takes a submitted
/// URL, and which local document that source produces. Transport, persistence
/// and model execution remain outside this seam.
public protocol SourceAdapting: Sendable {
  func takesOwnership(of url: URL) -> Bool
  func capture(url: URL) async throws -> CapturedDocument
}
