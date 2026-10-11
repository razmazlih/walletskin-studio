import Foundation
import SwiftUI

struct ConnectedDevice: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let product: String
    let version: String
    let eligible: Bool
    let reason: String
}
struct WalletCard: Codable, Identifiable, Equatable {
    let id: String
    let deviceID: String
    let name: String
    var bindingToken: String? = nil
    var source: String? = nil
}
private struct BridgeResponse: Decodable {
    let ok: Bool
    let error: String?
    let devices: [ConnectedDevice]?
    let cards: [WalletCard]?
    let transportCompleted: Bool?
}
private struct BridgeRequest: Encodable, Sendable {
    let command: String
    var deviceID: String? = nil
    var cardID: String? = nil
    var bindingToken: String? = nil
    var imagePath: String? = nil
    var confirmed: Bool? = nil
    var experimentalRiskAccepted: Bool? = nil
}

private final class ScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var ready = false
    private var cancelled = false
    func attach(_ value: Process) { lock.lock(); process = value; lock.unlock() }
    func markReady() {
        lock.lock(); ready = true; let target = cancelled ? process : nil; lock.unlock()
        if let target, target.isRunning { target.terminate() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let target = ready ? process : nil; lock.unlock()
        if let target, target.isRunning { target.terminate() }
    }
    func finish() { lock.lock(); process = nil; lock.unlock() }
}

@MainActor final class DeviceService: ObservableObject {
    @Published var devices: [ConnectedDevice] = []
    @Published var cards: [WalletCard] = []
    @Published var selectedDeviceID: String? { didSet { if oldValue != selectedDeviceID { cards = []; selectedCardID = nil } } }
    @Published var selectedCardID: String?
    @Published var status = "חברו iPhone באמצעות USB, פתחו אותו ואשרו אמון ב־Finder."
    @Published var busy = false
    @Published var scanning = false
    @Published var scanRemainingSeconds: Int? = nil
    @Published var stoppingScan = false
    private var scanControl: ScanControl?
    private var scanCountdown: Task<Void, Never>?
    private var mockScanTask: Task<Void, Never>?
    @Published var isMock = false {
        didSet {
            if busy { isMock = oldValue; return }
            devices = []; cards = []; selectedDeviceID = nil; selectedCardID = nil; refresh()
        }
    }
    @Published var needsWalletVerification = false
    private var submittedDeviceID: String?
    private var submittedCardID: String?
    var canApply: Bool {
        guard !busy, let card = cards.first(where: { $0.id == selectedCardID && $0.deviceID == selectedDeviceID }) else { return false }
        if isMock { return card.deviceID == "mock-only" }
        return card.source == "live" && card.bindingToken != nil && devices.first(where: { $0.id == selectedDeviceID })?.eligible == true
    }

    var statusEnglish: String {
        switch status {
        case "הסריקה נעצרה. לא התקבל זיהוי חדש; כרטיסים קודמים נשמרו.": return "Scan stopped. No new discovery; previous cards were retained."
        case "עוצר את הסריקה…": return "Stopping discovery…"
        case "זוהה כרטיס בסריקה הנוכחית והסריקה הסתיימה.": return "A card was discovered in this scan; discovery finished."
        case "התקבלו כמה מזהים באותו אירוע והסריקה הסתיימה. אין להסיק איזה מהם הכרטיס שהוצג.": return "Multiple identifiers arrived in one event; discovery finished. Their relation to the displayed card is unverified."
        case "לא נקלט מזהה חי. מוצגים כרטיסים שזוהו בעבר במכשיר הזה; נוכחותם טרם אומתה מחדש.":
            return "No live identifier received. Previously discovered cards for this device are shown; current presence is unverified."
        case "חברו iPhone באמצעות USB, פתחו אותו ואשרו אמון ב־Finder.":
            return "Connect your iPhone using USB, unlock it, and confirm Trust in Finder."
        case "מצב הדגמה — אין תקשורת עם iPhone ואין שינוי במכשיר.":
            return "Mock mode: no iPhone communication and no device modification."
        case "לא נמצא iPhone. חברו USB ואשרו אמון ב־Finder.":
            return "No iPhone found. Connect USB and confirm Trust in Finder."
        case "המכשיר זוהה. טווח הגרסאות מבוסס על טענת AirCard; התאימות לא אומתה במכשיר.":
            return "Device detected. The version range is an AirCard claim; compatibility has not been verified on this device."
        case "כרטיסי הדגמה בלבד.":
            return "Mock cards only."
        case "הסריקה חסומה: יש לאשר אמון, ונדרשת גרסה בטווח המתועד ללא גרסת בטא.":
            return "Scanning blocked: confirm Trust and use a documented release version, excluding beta builds."
        case "סריקה במשך 45 שניות: פתחו Apple Pay, הזדהו והציגו כל כרטיס שרוצים לזהות.":
            return "Scanning for 45 seconds: open Apple Pay, authenticate, and activate each card to identify."
        case "לא נקלט מזהה כרטיס. הפעילו כרטיס ב־Apple Pay ונסו שוב.":
            return "No card identifier detected. Activate a card in Apple Pay and retry."
        case "זוהו מזהים מהיומן החי של המכשיר. השמות הם מספרים מקומיים בלבד.":
            return "Identifiers detected from the live device log. Card labels are local numbers only."
        case "בדיקת ההדגמה נכשלה: בחרו כרטיס הדגמה ותמונה מוכנה.":
            return "Mock test failed: select a mock card and prepare an image."
        case "ההחלה חסומה: AirCard משנה גם נתוני Books ונתיבי ביניים. אי אפשר לעמוד במגבלת כתיבה לתמונות בלבד; שחזור בטוח לא הוכח. התמונה ניתנת לייצוא מקומי.":
            return "Apply blocked: AirCard changes Books metadata and staging paths beyond artwork. Safe restoration is unverified. Export your artwork locally."
        case "המכשיר נותק. חברו שוב וסרקו מחדש.":
            return "Device disconnected. Reconnect and scan again."
        case "רכיב USB חסר. בנו את האפליקציה באמצעות סקריפט הבנייה.":
            return "USB helper missing. Build the app using the build script."
        case "לא ניתן לקרוא את היומן. פתחו את המכשיר ואשרו אמון ב־Finder.":
            return "Cannot read device logs. Unlock the iPhone and confirm Trust in Finder."
        case "נדרש אישור מפורש לפני שינוי המכשיר.": return "Explicit confirmation is required before modifying the device."
        case "בחרו מכשיר וכרטיס שזוהה בסריקה חדשה לפני ההחלה.": return "Select a device and a card identified by a fresh scan before Apply."
        case "מאמתים את המכשיר, הכרטיס והתמונה לפני כתיבה.": return "Validating the device, card binding and prepared artwork before writing."
        case "כותבים את תמונת הכרטיס באמצעות AirCard.": return "Writing the selected card artwork using AirCard."
        case "מעדכנים את מטמון התצוגה של הכרטיס שנבחר.": return "Refreshing the display cache for the selected card."
        case "הכתיבה והניקוי הסתיימו. תוצאת Wallet טרם אומתה: סגרו ופתחו את Wallet ובדקו את הכרטיס המדויק.": return "Writing and cleanup completed. Wallet appearance is unverified: close and reopen Wallet, then check the exact card."
        case "בחרו את הכרטיס והמכשיר שנשלחו לפני אישור התוצאה.": return "Select the submitted card and device before confirming the appearance."
        case "אישרתם ידנית שהתמונה נראית בכרטיס שנבחר ב־Wallet. האפליקציה לא אימתה זאת אוטומטית.": return "You manually confirmed the artwork appears on the selected Wallet card. The app did not verify this automatically."
        case "הניקוי לא הושלם או שקיימת פעולת שחזור ממתינה. חומר השחזור נשמר בתיקיית Recovery המקומית; פעולות נוספות חסומות. אין לבצע ניסיון חוזר אוטומטי.": return "Cleanup is incomplete or recovery is pending. Recovery material is retained locally and further Apply operations are blocked. Do not automatically retry."
        case "תמונת הכרטיס נכתבה אך רענון המטמון לא הושלם. ייתכן שינוי חלקי; בדקו Wallet לפני כל ניסיון נוסף.": return "Artwork was written but cache refresh is incomplete. A partial change is possible; inspect Wallet before retrying."
        case "הכתיבה לא הושלמה. ייתכן שינוי חלקי; בדקו את הכרטיס ב־Wallet וסרקו מחדש לפני ניסיון נוסף.": return "Writing was incomplete. A partial change is possible; inspect Wallet and rescan before retrying."
        case "אישור הסריקה אינו תקף לכרטיס ולמכשיר שנבחרו. סרקו מחדש.": return "The scan receipt is invalid for this card and device. Scan again."
        case "התמונה המוכנה אינה תקינה או אינה בקובץ המקומי המאושר. הכינו שוב את התמונה.": return "The prepared artwork is invalid or outside trusted local storage. Prepare it again."
        case "פעולת החלה אחרת פעילה. המתינו לסיום.": return "Another Apply operation is active. Wait for it to finish."
        default:
            if status.hasPrefix("בדיקת הדגמה: התמונה הוכנה עבור ") {
                let number = cards.firstIndex(where: { $0.id == selectedCardID }).map { String($0 + 1) } ?? "?"
                return "Mock test: artwork prepared for demo card \(number). No iPhone write occurred."
            }
            return "Local operation failed. Check USB, unlock the device, confirm Trust, and retry."
        }
    }

    func refresh() {
        guard !busy else { return }
        if isMock {
            devices = [ConnectedDevice(id: "mock-only", name: "iPhone לדוגמה", product: "iPhone", version: "27.0.1", eligible: true, reason: "mock")]
            selectedDeviceID = devices.first?.id
            status = "מצב הדגמה — אין תקשורת עם iPhone ואין שינוי במכשיר."
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await Self.execute(BridgeRequest(command: "devices"))
                devices = result.devices ?? []
                if !devices.contains(where: { $0.id == selectedDeviceID }) { selectedDeviceID = (devices.first(where: { $0.eligible }) ?? devices.first)?.id }
                if let identifier = selectedDeviceID, devices.first(where: { $0.id == identifier })?.eligible == true {
                    let known = try await Self.execute(BridgeRequest(command: "known_cards", deviceID: identifier))
                    if selectedDeviceID == identifier { cards = known.cards ?? []; selectedCardID = cards.first?.id }
                }
                status = devices.isEmpty ? "לא נמצא iPhone. חברו USB ואשרו אמון ב־Finder." : "המכשיר זוהה. טווח הגרסאות מבוסס על טענת AirCard; התאימות לא אומתה במכשיר."
            } catch { devices = []; selectedDeviceID = nil; status = Self.message(error) }
        }
    }

    func discover() {
        guard !busy, let deviceID = selectedDeviceID else { return }
        if isMock {
            busy = true; scanning = true; stoppingScan = false
            startScanCountdown()
            status = "מצב הדגמה — אין תקשורת עם iPhone ואין שינוי במכשיר."
            mockScanTask = Task {
                defer { busy = false; scanning = false; stoppingScan = false; scanRemainingSeconds = nil; scanCountdown?.cancel(); mockScanTask = nil }
                do { try await Task.sleep(for: .seconds(15)) }
                catch { status = "הסריקה נעצרה. לא התקבל זיהוי חדש; כרטיסים קודמים נשמרו."; return }
                cards = [WalletCard(id: "mock-card-1", deviceID: deviceID, name: "כרטיס הדגמה 1", source: "live")]
                selectedCardID = cards.first?.id
                status = "כרטיסי הדגמה בלבד."
            }
            return
        }
        guard devices.first(where: { $0.id == deviceID })?.eligible == true else {
            status = "הסריקה חסומה: יש לאשר אמון, ונדרשת גרסה בטווח המתועד ללא גרסת בטא."
            return
        }
        busy = true
        scanning = true; stoppingScan = false; scanRemainingSeconds = nil
        cards = cards.map { card in var old = card; old.source = "history"; old.bindingToken = nil; return old }
        let control = ScanControl(); scanControl = control
        status = "סריקה במשך 45 שניות: פתחו Apple Pay, הזדהו והציגו כל כרטיס שרוצים לזהות."
        Task { [self] in
            defer { busy = false; scanning = false; stoppingScan = false; scanRemainingSeconds = nil; scanCountdown?.cancel(); scanControl = nil }
            do {
                let result = try await Self.execute(BridgeRequest(command: "discover", deviceID: deviceID), progress: { [weak self] phase in
                    if phase == "scanning" { Task { @MainActor in self?.startScanCountdown() } }
                }, control: control)
                guard selectedDeviceID == deviceID, !isMock else { return }
                let live = result.cards ?? []
                let previous = cards.filter { previous in previous.deviceID == deviceID && !live.contains(where: { $0.id == previous.id }) }.map { card in
                    var previous = card; previous.bindingToken = nil; previous.source = "history"; return previous
                }
                cards = live + previous
                selectedCardID = cards.first?.id
                status = live.isEmpty ? (cards.isEmpty ? "לא נקלט מזהה כרטיס. הפעילו כרטיס ב־Apple Pay ונסו שוב." : "לא נקלט מזהה חי. מוצגים כרטיסים שזוהו בעבר במכשיר הזה; נוכחותם טרם אומתה מחדש.") : (live.count == 1 ? "זוהה כרטיס בסריקה הנוכחית והסריקה הסתיימה." : "התקבלו כמה מזהים באותו אירוע והסריקה הסתיימה. אין להסיק איזה מהם הכרטיס שהוצג.")
            } catch {
                if (error as NSError).domain == "scan_cancelled" { status = "הסריקה נעצרה. לא התקבל זיהוי חדש; כרטיסים קודמים נשמרו." }
                else { cards = []; selectedCardID = nil; status = Self.message(error) }
            }
        }
    }

    func stopScan() {
        guard scanning, !stoppingScan else { return }
        stoppingScan = true; status = "עוצר את הסריקה…"; scanControl?.cancel()
        if isMock { mockScanTask?.cancel() }
    }

    private func startScanCountdown() {
        guard scanning else { return }
        let deadline = Date().addingTimeInterval(45)
        scanRemainingSeconds = 45
        scanCountdown = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.scanning else { return }
                self.scanRemainingSeconds = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func apply(imageURL: URL, confirmed: Bool = false, experimentalRiskAccepted: Bool = false) {
        guard confirmed else { status = "נדרש אישור מפורש לפני שינוי המכשיר."; return }
        guard canApply, let card = cards.first(where: { $0.id == selectedCardID && $0.deviceID == selectedDeviceID }) else {
            status = "בחרו מכשיר וכרטיס שזוהה בסריקה חדשה לפני ההחלה."; return
        }
        if isMock {
            guard FileManager.default.fileExists(atPath: imageURL.path) else {
                status = "בדיקת ההדגמה נכשלה: בחרו כרטיס הדגמה ותמונה מוכנה."; return
            }
            status = "בדיקת הדגמה: התמונה הוכנה עבור \(card.name). לא בוצעה כתיבה ל־iPhone."
            return
        }
        guard let token = card.bindingToken else { return }
        guard experimentalRiskAccepted else { status = "נדרש אישור מפורש לסיכון הניסיוני לנתוני Books."; return }
        let request = BridgeRequest(command: "apply", deviceID: card.deviceID, cardID: card.id,
                                    bindingToken: token, imagePath: imageURL.path, confirmed: true, experimentalRiskAccepted: true)
        busy = true
        needsWalletVerification = false
        status = "מאמתים את המכשיר, הכרטיס והתמונה לפני כתיבה."
        Task { [self] in
            defer { busy = false }
            do {
                let result = try await Self.execute(request) { [weak self] phase in
                    Task { @MainActor in
                        switch phase {
                        case "writing_artwork": self?.status = "כותבים את תמונת הכרטיס באמצעות AirCard."
                        case "refreshing_wallet_cache": self?.status = "מעדכנים את מטמון התצוגה של הכרטיס שנבחר."
                        default: break
                        }
                    }
                }
                if let index = cards.firstIndex(where: { $0.id == card.id && $0.deviceID == card.deviceID }) { cards[index].bindingToken = nil }
                guard result.transportCompleted == true else { throw NSError(domain: "artwork_write_incomplete_rescan", code: 1) }
                submittedDeviceID = card.deviceID; submittedCardID = card.id
                needsWalletVerification = true
                status = "הכתיבה והניקוי הסתיימו. תוצאת Wallet טרם אומתה: סגרו ופתחו את Wallet ובדקו את הכרטיס המדויק."
            } catch {
                if let index = cards.firstIndex(where: { $0.id == card.id && $0.deviceID == card.deviceID }) { cards[index].bindingToken = nil }
                status = Self.message(error)
            }
        }
    }

    func confirmWalletAppearance() {
        guard needsWalletVerification, selectedDeviceID == submittedDeviceID, selectedCardID == submittedCardID else {
            status = "בחרו את הכרטיס והמכשיר שנשלחו לפני אישור התוצאה."; return
        }
        needsWalletVerification = false
        status = "אישרתם ידנית שהתמונה נראית בכרטיס שנבחר ב־Wallet. האפליקציה לא אימתה זאת אוטומטית."
    }

    private nonisolated static func execute(_ request: BridgeRequest, progress: (@Sendable (String) -> Void)? = nil, control: ScanControl? = nil) async throws -> BridgeResponse {
        try await Task.detached {
            let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
            let bridge = resources.appendingPathComponent("bridge.py")
            let runtime = resources.appendingPathComponent("runtime/bin/python3")
            let process = Process()
            process.executableURL = FileManager.default.isExecutableFile(atPath: runtime.path) ? runtime : URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", "-B", bridge.path]
            // Isolated Python ignores user PYTHONPATH/site hooks; add sibling modules explicitly in bridge.
            process.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"]
            let input = Pipe(), output = Pipe()
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            control?.attach(process)
            defer { control?.finish() }
            try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(request))
            try input.fileHandleForWriting.close()
            var pending = Data()
            var final: BridgeResponse?
            while let chunk = try output.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                pending.append(chunk)
                guard pending.count <= 1_048_576 else { process.terminate(); throw NSError(domain: "invalid_bridge_output", code: 1) }
                while let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
                    if let event = try? JSONSerialization.jsonObject(with: line) as? [String: String],
                       event["type"] == "progress", let phase = event["phase"] { if phase == "scanning" { control?.markReady() }; progress?(phase) }
                    else if let response = try? JSONDecoder().decode(BridgeResponse.self, from: line) { final = response }
                }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0, let response = final else { throw NSError(domain: "local_operation_failed", code: 1) }
            guard response.ok else { throw NSError(domain: response.error ?? "local_operation_failed", code: 1) }
            return response
        }.value
    }
    private static func message(_ error: Error) -> String {
        switch (error as NSError).domain {
        case "device_disconnected": return "המכשיר נותק. חברו שוב וסרקו מחדש."
        case "helper_missing": return "רכיב USB חסר. בנו את האפליקציה באמצעות סקריפט הבנייה."
        case "scan_failed_unlock_and_trust": return "לא ניתן לקרוא את היומן. פתחו את המכשיר ואשרו אמון ב־Finder."
        case "pending_recovery_blocks_apply", "cleanup_incomplete_recovery_preserved", "recovery_state_unreadable":
            return "הניקוי לא הושלם או שקיימת פעולת שחזור ממתינה. חומר השחזור נשמר בתיקיית Recovery המקומית; פעולות נוספות חסומות. אין לבצע ניסיון חוזר אוטומטי."
        case "artwork_written_cache_refresh_incomplete":
            return "תמונת הכרטיס נכתבה אך רענון המטמון לא הושלם. ייתכן שינוי חלקי; בדקו Wallet לפני כל ניסיון נוסף."
        case "artwork_write_incomplete_rescan":
            return "הכתיבה לא הושלמה. ייתכן שינוי חלקי; בדקו את הכרטיס ב־Wallet וסרקו מחדש לפני ניסיון נוסף."
        case "scan_binding_expired", "invalid_card_binding", "card_device_mismatch":
            return "אישור הסריקה אינו תקף לכרטיס ולמכשיר שנבחרו. סרקו מחדש."
        case "invalid_png", "invalid_png_pixels", "invalid_png_dimensions_or_format", "untrusted_image_path", "unsafe_local_file":
            return "התמונה המוכנה אינה תקינה או אינה בקובץ המקומי המאושר. הכינו שוב את התמונה."
        case "another_apply_in_progress": return "פעולת החלה אחרת פעילה. המתינו לסיום."
        case "explicit_confirmation_required": return "נדרש אישור מפורש לפני שינוי המכשיר."
        default: return "הפעולה המקומית נכשלה. בדקו USB, פתיחת המכשיר ואישור אמון ונסו שוב."
        }
    }
}
