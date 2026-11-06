import DevVMProvisioningCore

public typealias ProvisioningLayoutExampleID = LayoutExampleID
public typealias ProvisioningLayoutExample = LayoutExample
public typealias ProvisioningLayoutWindow = LayoutExampleWindow
extension BundledProvisioning {
    public static func layoutExamples() throws -> [ProvisioningLayoutExample] { try LayoutExamples.catalogue() }
}
