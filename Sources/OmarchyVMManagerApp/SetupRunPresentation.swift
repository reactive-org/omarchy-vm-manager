import OmarchyVMManagerCore

/// Change setup's words for how a run ended and why a run didn't start.
/// Kept apart from the view so its long body stays within the type checker's limit.
enum SetupRunPresentation {
    /// How a finished run ended, in a few words.
    static func outcome(_ run: ProvisioningWorkflowSnapshot) -> String {
        if run.cleanupRelease != nil { return "Interrupted; cleanup was released without verification" }
        return switch run.stage {
        case .succeeded, .checked: "Finished"
        case .failed:
            switch run.failure {
            case .systemUpdateFailed: "Failed during system update"
            case .helperUnavailable: "Failed: the setup helper wasn’t available"
            case .sshTimeout, .restartTimeout: "Failed: the guest didn’t become reachable in time"
            default: "Failed"
            }
        case .cancelled: "Cancelled"
        case .interrupted: "Interrupted"
        case .cleanupRequired: "Stopped; cleanup still needs verification"
        default: run.title
        }
    }
    /// Why Run setup didn't start a run. Nothing is retried automatically.
    static func submissionFailure(_ error: any Error) -> String {
        let reason: String = switch error {
        case ProvisioningServiceFailure.alreadyRun: "this plan has already run. Open Change setup again to repeat the same choices."
        case ProvisioningServiceFailure.busy: "another setup run or an unresolved cleanup hold is in progress. Wait for it to finish, then try again."
        case ProvisioningServiceFailure.disabled: "setup execution is disabled in this build."
        case ProvisioningServiceFailure.reviewRequired, ProvisioningReviewFailure.consentRequired, ProvisioningReviewFailure.changed:
            "the guest, its connection or the setup inputs changed after it was prepared. Discard this run and run setup again."
        case ProvisioningReviewFailure.taskTrustRequired: "the custom tasks need your separate trust."
        case ProvisioningReviewFailure.conflictingConsent: "a different approval was already submitted for this review."
        default: "setup coordination is unavailable."
        }
        return "Setup didn’t start: " + reason + " Nothing was retried automatically."
    }
}
