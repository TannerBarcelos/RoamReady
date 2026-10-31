/// Asset requests can outlive a cancelled indexing session. Share the in-flight download, allow later
/// retries after a failure, and prevent one cancelled caller from cancelling another caller's download.
actor EmbeddingAssetPreparation {
    private var inFlight: Task<Bool, Never>?

    func request(_ download: @escaping @Sendable () async -> Bool) async -> Bool {
        if let inFlight { return await inFlight.value }
        let task = Task { await download() }
        inFlight = task
        let available = await task.value
        inFlight = nil
        return available
    }
}
