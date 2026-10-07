import Foundation
import Testing

@testable import DSHRemoteKit

/// Guards the fixture set itself: a capture dropped into `Fixtures/` without a decode
/// test fails here, so "verified against captured bytes" cannot quietly rot.
@Test("every file in Fixtures/ is listed and loads as a JSON object")
func allFixturesAreCovered() throws {
    let onDisk = try FileManager.default.contentsOfDirectory(atPath: Fixtures.directory.path)
        .filter { $0.hasSuffix(".json") }
        .sorted()
    let listed = Set(Fixtures.File.allCases.map(\.rawValue))

    #expect(onDisk.sorted() == listed.sorted())

    for file in Fixtures.File.allCases {
        let object = try Fixtures.object(file)
        #expect(!object.isEmpty, "\(file.rawValue) decoded to an empty object")
    }
}
