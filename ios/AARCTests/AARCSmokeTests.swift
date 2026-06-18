import Testing
import AARCKit
@testable import AARC

@Test func appVersionResolves() {
    let v = AppVersion.versionString
    #expect(!v.isEmpty)
}

@MainActor
@Test func configHasAarunHost() {
    let host = Config.apiBaseURL.host()
    #expect(host == "api.aarun.club" || (host?.hasPrefix("localhost") ?? false))
}
