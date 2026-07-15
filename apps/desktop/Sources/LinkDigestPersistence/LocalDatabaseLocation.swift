import Foundation

public struct LocalDatabaseLocation: Sendable, Equatable {
  public let directoryURL: URL
  public let databaseURL: URL
  public let walURL: URL
  public let sharedMemoryURL: URL

  public init(applicationSupportRoot: URL, databaseName: String = "history.sqlite") {
    directoryURL = applicationSupportRoot.appendingPathComponent("LinkDigest", isDirectory: true)
    databaseURL = directoryURL.appendingPathComponent(databaseName)
    walURL = directoryURL.appendingPathComponent("\(databaseName)-wal")
    sharedMemoryURL = directoryURL.appendingPathComponent("\(databaseName)-shm")
  }

  public init(directoryURL: URL, databaseName: String = "history.sqlite") {
    self.directoryURL = directoryURL
    databaseURL = directoryURL.appendingPathComponent(databaseName)
    walURL = directoryURL.appendingPathComponent("\(databaseName)-wal")
    sharedMemoryURL = directoryURL.appendingPathComponent("\(databaseName)-shm")
  }
}
