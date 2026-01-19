import Foundation
import AppKit

@MainActor
class LicenseViewModel: ObservableObject {
    enum LicenseState: Equatable {
        case trial(daysRemaining: Int)
        case trialExpired
        case licensed
    }

    @Published private(set) var licenseState: LicenseState = .licensed  // Always licensed
    @Published var licenseKey: String = ""
    @Published var isValidating = false
    @Published var validationMessage: String?
    @Published private(set) var activationsLimit: Int = 0

    private let trialPeriodDays = 7
    private let polarService = PolarService()
    private let userDefaults = UserDefaults.standard
    private let licenseManager = LicenseManager.shared

    init() {
        loadLicenseState()
    }

    func startTrial() {
        // No-op: always licensed
        licenseState = .licensed
    }

    private func loadLicenseState() {
        // Always set to licensed - CUSTOM MODIFICATION
        licenseState = .licensed
        activationsLimit = 0
    }
    
    var canUseApp: Bool {
        // Always return true - CUSTOM MODIFICATION
        return true
    }
    
    func openPurchaseLink() {
        if let url = URL(string: "https://tryvoiceink.com/buy") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func validateLicense() async {
        // Always validate successfully - CUSTOM MODIFICATION
        licenseState = .licensed
        validationMessage = "License activated successfully!"
        NotificationCenter.default.post(name: .licenseStatusChanged, object: nil)
        isValidating = false
        
        // Save dummy values to persist "licensed" look in settings if needed
        licenseManager.licenseKey = licenseKey
    }
    
    func removeLicense() {
        // Remove all license data from Keychain
        licenseManager.removeAll()

        // Reset UserDefaults flags
        userDefaults.set(false, forKey: "VoiceInkLicenseRequiresActivation")
        userDefaults.set(false, forKey: "VoiceInkHasLaunchedBefore")
        userDefaults.activationsLimit = 0

        // Still keep as licensed - CUSTOM MODIFICATION
        licenseState = .licensed
        licenseKey = ""
        validationMessage = nil
        activationsLimit = 0
        NotificationCenter.default.post(name: .licenseStatusChanged, object: nil)
    }
}


// UserDefaults extension for non-sensitive license settings
extension UserDefaults {
    var activationsLimit: Int {
        get { integer(forKey: "VoiceInkActivationsLimit") }
        set { set(newValue, forKey: "VoiceInkActivationsLimit") }
    }
}
