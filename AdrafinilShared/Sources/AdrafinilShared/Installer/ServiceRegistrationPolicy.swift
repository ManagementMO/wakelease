import Foundation

public enum ServiceRegistrationPolicy {
    public static func isPendingApproval(error: Error, requiresApproval: Bool) -> Bool {
        let error = error as NSError
        return requiresApproval && error.domain == "SMAppServiceErrorDomain" && error.code == 1
    }
}
