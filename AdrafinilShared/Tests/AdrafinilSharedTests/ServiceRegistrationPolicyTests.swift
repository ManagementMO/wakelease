import Foundation
import Testing
@testable import AdrafinilShared

@Suite("Service approval state")
struct ServiceRegistrationPolicyTests {
    @Test
    func `permission denial with pending approval is presented as an approval request`() {
        let error = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        #expect(ServiceRegistrationPolicy.isPendingApproval(error: error, requiresApproval: true))
    }

    @Test
    func `permission denial without pending approval remains a failure`() {
        let error = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        #expect(!ServiceRegistrationPolicy.isPendingApproval(error: error, requiresApproval: false))
    }

    @Test
    func `unrelated errors are not hidden by a stale approval state`() {
        for error in [NSError(domain: "SMAppServiceErrorDomain", code: 99), NSError(domain: NSPOSIXErrorDomain, code: 1)] {
            #expect(!ServiceRegistrationPolicy.isPendingApproval(error: error, requiresApproval: true))
        }
    }
}
