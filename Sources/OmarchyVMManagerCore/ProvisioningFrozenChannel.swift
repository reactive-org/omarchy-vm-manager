import Foundation

/// Independent one-shot bulk channel. Source bytes never enter control frames,
/// arguments, environment, status or terminal. The authenticated bootstrap binds
/// the whole blob and its exact size; per-packet lengths are bounded as well.
enum ProvisioningFrozenChannel {
    static func send(_ bytes: Data, over channel: ProvisioningHelperSocket) throws {
        guard bytes.count <= ProvisioningFrozenDelivery.maximumBytes else { throw ProvisioningJobFailure.artifactUnavailable }
        let end = ContinuousClock.now + .seconds(15)
        var offset = 0
        while offset < bytes.count {
            guard ContinuousClock.now < end else { throw ProvisioningHelperIPCFailure.timeout }
            let limit = min(offset + 16 * 1024, bytes.count)
            try channel.send(Data(bytes[offset..<limit]), wait: remaining(end, channel)); offset = limit
        }
        channel.finishSending()
    }
    static func receive(_ expected: ProvisioningFrozenDeliveryReceipt, over channel: ProvisioningHelperSocket) throws -> Data {
        try expected.validate()
        var bytes = Data(); bytes.reserveCapacity(expected.byteCount)
        let end = ContinuousClock.now + .seconds(15)
        while bytes.count < expected.byteCount {
            guard ContinuousClock.now < end else { throw ProvisioningHelperIPCFailure.timeout }
            let packet = try channel.receive(wait: remaining(end, channel))
            guard packet.count <= expected.byteCount - bytes.count else { throw ProvisioningJobFailure.artifactUnavailable }
            bytes.append(packet)
        }
        try channel.requireEOF(wait: remaining(end, channel))
        guard KitVerifier.sha256(bytes) == expected.sha256 else { throw ProvisioningJobFailure.artifactUnavailable }
        return bytes
    }
    private static func remaining(_ end: ContinuousClock.Instant, _ channel: ProvisioningHelperSocket) throws -> Duration {
        let duration = ContinuousClock.now.duration(to: end)
        guard duration > .zero else { throw ProvisioningHelperIPCFailure.timeout }
        return min(duration, channel.timeout)
    }

}
