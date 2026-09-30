import Testing
import Foundation
@testable import Core

@Suite struct AppPathsTests {
    @Test func appSupportPathEndsWithSimpleToken() {
        #expect(AppPaths.appSupport.lastPathComponent == "SimpleToken")
    }

    @Test func legacyArchivePointsAtTokenMonitor() {
        #expect(AppPaths.legacyHistoryArchive.path.contains("Token Monitor"))
    }
}
