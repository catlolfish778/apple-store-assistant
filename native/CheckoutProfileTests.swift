import Foundation

@main
struct CheckoutProfileTests {
    static func main() throws {
        var calls = 0
        var saved = SecureCheckoutProfile()
        saved.surname = "Example"
        let isolated = CheckoutProfileLaunchPolicy.load(isolated: true) {
            calls += 1
            return saved
        }
        guard calls == 0, isolated == SecureCheckoutProfile() else {
            fatalError("Isolated self-test/preview must not read saved Keychain data")
        }
        let normal = CheckoutProfileLaunchPolicy.load(isolated: false) {
            calls += 1
            return saved
        }
        precondition(calls == 1 && normal == saved, "Normal launch must retain saved profile loading")
        enum LoadFailure: Error { case expected }
        do {
            _ = try CheckoutProfileLaunchPolicy.load(isolated: false) { throw LoadFailure.expected }
            fatalError("Normal launch must propagate load failures")
        } catch LoadFailure.expected {}
        print("Checkout profile tests passed: isolated launch never reads Keychain; normal loading and failures preserved")
    }
}
