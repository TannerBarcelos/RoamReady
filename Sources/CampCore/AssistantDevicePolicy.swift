/// Product eligibility for generative camping help, separate from Apple's model availability.
public enum AssistantDevicePolicy {
    /// iPhone 15 or newer. `iPhone15,*` covers both the iPhone 14 Pro (`15,2`/`15,3`, excluded) and the
    /// iPhone 15 / 15 Plus (`15,4`/`15,5`, included), so this is not a plain generation check.
    /// Apple Intelligence itself needs an iPhone 15 Pro (`iPhone16,1`) or later; the base 15 and 15 Plus pass
    /// this gate, then Apple's runtime check reports `deviceNotEligible` and the app explains why.
    public static func permitsGenerativeAI(machineIdentifier: String) -> Bool {
        guard machineIdentifier.hasPrefix("iPhone") else { return false }
        let parts = machineIdentifier.dropFirst("iPhone".count).split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let generation = Int(parts[0]), let variant = Int(parts[1]), variant > 0 else { return false }
        if generation == 15 { return iPhone15Variants.contains(variant) }
        return generation >= 16
    }

    /// The global chat tab requires Apple Intelligence hardware, so base iPhone 15/15 Plus
    /// receive only the existing in-trip saved guidance. Apple's runtime check still applies.
    public static func supportsGlobalChat(machineIdentifier: String) -> Bool {
        permitsGenerativeAI(machineIdentifier: machineIdentifier)
            && !["iPhone15,4", "iPhone15,5"].contains(machineIdentifier)
    }

    /// `iPhone15,4` is the iPhone 15 and `iPhone15,5` the iPhone 15 Plus.
    private static let iPhone15Variants: Set<Int> = [4, 5]
}
