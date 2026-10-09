import PlainpostOperations

public enum PlainpostBackgroundAgentJobPolicy {
    public static let userRequestedPauseReason = "user-requested"
    /// Low Power Mode paused the job; the app lifts it when Low Power Mode ends.
    public static let lowPowerPauseReason = "low-power"

    public static let allowedKinds: Set<PlainpostOperationKind> = [
        .inboxSync,
        .historicalSync,
        .approvedDelivery,
        .denySend,
        .aiOperation,
        .searchRebuild,
        .mailboxFlag,
        .mailboxArchive,
    ]

    public static func hasPendingWork(_ jobs: [PlainpostDurableJob]) -> Bool {
        jobs.contains { job in
            allowedKinds.contains(job.kind)
                && (job.state == .queued || job.state == .running
                    || (job.state == .paused
                        && job.pauseReason != LocalOperationRuntime.credentialsUnavailablePauseReason
                        && job.pauseReason != userRequestedPauseReason
                        && job.pauseReason != lowPowerPauseReason))
        }
    }
}
