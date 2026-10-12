import Foundation
import PhoneUseMCP

extension CredentialStore {
    public func invocationContext(bearer: String, sessionID: String, deadline: TimeInterval? = nil) throws -> InvocationContext {
        let credential = try authenticate(bearer)
        return InvocationContext(credentialID: credential.id, sessionID: sessionID, deadline: deadline) {
            try self.authorize(credentialID: credential.id)
        }
    }
}
