import OmarchyVMManagerCore

/// Change setup's words for a plan's run and for Run setup again (issue #14).
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
    /// The line shown in place of Review this run… once the plan has a run.
    static func status(_ run: ProvisioningWorkflowSnapshot) -> String {
        guard run.runFinished else { return "This setup is running: " + run.title + ". Follow it in View output; it continues if you close this sheet." }
        return "Last run: " + outcome(run) + "."
    }
    /// Run setup again repeats a finished run's choices. A cleanup hold is resolved
    /// first by the reviewed recover or release action.
    static func offersRunAgain(_ run: ProvisioningWorkflowSnapshot) -> Bool {
        run.runFinished && !run.cleanupRequired && run.stage != .cleanupRequired
    }
    static let runAgainNote = "Run setup again makes a fresh plan from the same choices, as they were frozen for the last run, using the current setup engine. You review it before anything runs. To choose different software, pick a source above instead."
    /// What changed between the last run's plan and the fresh one.
    static func summary(_ retry: ProvisioningRetryPreview) -> String {
        var text: String
        if retry.engineChanged { text = "dev-vm has been updated since the last run, so this plan was rebuilt with the current version from the same choices." }
        else if retry.planChanged { text = "This plan was rebuilt from the same choices and differs from the last run’s plan." }
        else { return "A fresh plan from the same choices as the last run. Nothing in the plan has changed." }
        let added = retry.addedFeatures ?? [], removed = retry.removedFeatures ?? []
        if !added.isEmpty { text += " It now also includes " + list(added) + "." }
        if !removed.isEmpty { text += " It no longer includes " + list(removed) + "." }
        if retry.addedFeatures == nil { text += " The last run’s software list wasn’t recorded, so review the plan below for differences." }
        else if added.isEmpty, removed.isEmpty { text += " The same software is selected; review the plan below for other differences." }
        return text
    }
    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
    /// Why Run setup again couldn't make a fresh plan.
    static func retryFailure(_ error: any Error) -> String {
        switch error {
        case ProvisioningServiceFailure.busy: "Resolve this guest’s cleanup hold with the reviewed action below before running setup again."
        case ProvisioningReviewFailure.quota: "Too many setup previews are open. Close this sheet and try again."
        case ProvisioningReviewFailure.changed: "The choices saved for the last run are missing or have changed, so they can’t be repeated. Choose a source above to review a new setup."
        default: "The last run’s choices aren’t available to run again. Choose a source above to review a new setup."
        }
    }
    /// Why Run setup didn't start a run. Nothing is retried automatically.
    static func submissionFailure(_ error: any Error) -> String {
        let reason: String = switch error {
        case ProvisioningServiceFailure.alreadyRun: "this plan has already run. Use Run setup again to repeat the same choices."
        case ProvisioningServiceFailure.busy: "another setup run or an unresolved cleanup hold is in progress. Wait for it to finish, then review again."
        case ProvisioningServiceFailure.disabled: "setup execution is disabled in this build."
        case ProvisioningServiceFailure.reviewRequired, ProvisioningReviewFailure.consentRequired, ProvisioningReviewFailure.changed:
            "the guest, its connection or the setup inputs changed after the review. Review this run again."
        case ProvisioningReviewFailure.taskTrustRequired: "the custom tasks need your separate trust."
        case ProvisioningReviewFailure.conflictingConsent: "a different approval was already submitted for this review."
        default: "setup coordination is unavailable."
        }
        return "Setup didn’t start: " + reason + " Nothing was retried automatically."
    }
}
