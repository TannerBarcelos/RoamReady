/// Product eligibility for generative camping help, separate from Apple's model availability.
public enum AssistantDevicePolicy {
    /// iPhone 16 / 16 Plus / 16 Pro / 16 Pro Max / 16e use iPhone17,* identifiers.
    /// Later identifier generations still require Apple's runtime model availability check.
    public static func permitsGenerativeAI(machineIdentifier: String) -> Bool {
        guard machineIdentifier.hasPrefix("iPhone") else { return false }
        let parts = machineIdentifier.dropFirst("iPhone".count).split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let generation = Int(parts[0]), let variant = Int(parts[1]), variant > 0 else { return false }
        return generation >= 17
    }
}
