import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

@main struct WalletSkinStudioApp: App {
    var body: some Scene {
        WindowGroup("WalletSkin Studio") { StudioView() }.defaultSize(width:1120,height:790)
    }
}
struct ApplySnapshot {
    let deviceID: String
    let cardID: String
    let deviceTitle: String
    let cardTitle: String
    let isMock: Bool
    let imageURL: URL
}
@MainActor final class StudioState: ObservableObject {
    @Published var showHelp = false
    @Published var showAdjustments = false
    @Published var english = false
    @Published var confirmation = false
    @Published var actionError: String?
    @Published var pending: ApplySnapshot?
    @Published var lastSubmitted: ApplySnapshot?
    @Published var experimentalRiskAccepted = false
    @Published var needsDeveloperTools = false
}
struct StudioView: View {
    @StateObject private var device = DeviceService()
    @StateObject private var editor = ArtworkEditor()
    @StateObject private var library = ArtworkLibrary()
    @StateObject private var state = StudioState()
    private func t(_ he:String,_ en:String) -> String { state.english ? en : he }
    private func cardTitle(_ card: WalletCard) -> String {
        let fingerprint = SHA256.hash(data:Data(card.id.utf8)).prefix(4).map { String(format:"%02x", $0) }.joined()
        guard state.english else { return card.name + " · " + fingerprint }
        let ordinal = (device.cards.firstIndex(where: { $0.id == card.id }) ?? 0) + 1
        return (device.isMock ? "Demo card \(ordinal)" : "Card \(ordinal)") + " · " + fingerprint
    }
    private var selectedPhone: ConnectedDevice? { device.devices.first { $0.id == device.selectedDeviceID } }
    private var canScan: Bool { !device.busy && (device.isMock || (!state.needsDeveloperTools && selectedPhone?.eligible == true)) }

    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"wallet.bifold.fill").font(.title2).foregroundStyle(.blue)
                Text("WalletSkin Studio").font(.title2.bold())
                Spacer()
                if device.isMock { Label(t("הדגמה", "Demo"),systemImage:"testtube.2").foregroundStyle(.orange) }
                Button { state.showHelp.toggle() } label: { Image(systemName:"questionmark.circle") }.help(t("עזרה קצרה", "Quick help"))
                    .popover(isPresented:$state.showHelp) { helpPanel }
                Toggle("English",isOn:$state.english).toggleStyle(.switch).controlSize(.small).fixedSize()
            }.padding(.horizontal,24).padding(.vertical,16)
            Divider()
            connectionBar.padding(.horizontal,24).padding(.vertical,12)
            Divider()
            HStack(alignment:.top,spacing:20) {
                cardSidebar.frame(width:205)
                Divider()
                VStack(alignment:.leading,spacing:16) {
                    HStack {
                        VStack(alignment:.leading,spacing:4) {
                            Text(t("הכרטיס שלך, בעיצוב שלך", "Make it yours")).font(.title2.bold())
                            Text(t("בחרו עיצוב או הוסיפו תמונה.", "Choose a design or add an image.")).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { editor.choose() } label: { Label(t("תמונה מהמחשב", "Add image"),systemImage:"photo.badge.plus") }
                    }
                    Spacer(minLength:0)
                    ArtworkCanvas(editor:editor)
                        .onDrop(of:[UTType.fileURL],isTargeted:nil) { providers in
                            guard let provider = providers.first else { return false }
                            _ = provider.loadObject(ofClass:URL.self) { url,_ in if let url { Task { @MainActor in editor.load(url) } } }
                            return true
                        }
                    HStack {
                        Label(t("תצוגה מקדימה", "Preview"),systemImage:"eye").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("1536 × 969 · PNG").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength:0)
                    if let error = editor.error { Text(error).font(.caption).foregroundStyle(.red) }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                designSidebar.frame(width:190)
            }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity)
            Divider()
            actionBar.padding(.horizontal,24).padding(.vertical,16)
        }
        .background(Color(nsColor:.windowBackgroundColor))
        .frame(minWidth:1000,minHeight:690)
        .environment(\.layoutDirection,state.english ? .leftToRight:.rightToLeft)
            .sheet(isPresented:$state.confirmation) {
                if let pending = state.pending {
                    VStack(alignment:.leading,spacing:18) {
                        Text(pending.isMock ? t("אישור בדיקת הדגמה","Confirm mock test") : t("אישור שינוי ב־iPhone","Confirm iPhone modification")).font(.title2.bold())
                        Text(pending.deviceTitle + " · " + pending.cardTitle).font(.headline)
                        if let preview = NSImage(contentsOf:pending.imageURL) { Image(nsImage:preview).resizable().aspectRatio(1536.0/969.0,contentMode:.fit).frame(maxWidth:430).clipShape(RoundedRectangle(cornerRadius:16)) }
                        Text(pending.isMock ? t("הדגמה בלבד: אין תקשורת או כתיבה ל־iPhone.","Simulation only: no iPhone communication or writes.") : t("התמונה הזו תוחל על הכרטיס והמכשיר שמוצגים כאן. המנגנון אינו רשמי וכותב גם נתוני Books וקבצי ביניים ב־Media. אין דרך מאומתת לשחזור המקור. ניתוק עלול להשאיר שינוי חלקי. התאימות מבוססת על הטווח שדווח במקור, ולא על אימות של המכשיר שלך.","This exact artwork will target the card and device shown here. The unofficial mechanism also writes Books sync metadata and Media staging files. Original restoration is unavailable. Disconnection may leave an incomplete change. Compatibility reflects upstream’s reported range, not verification of your device.")).foregroundStyle(.orange)
                        if !pending.isMock { Text(t("המספר המקומי אינו סדר הכרטיסים ב־Wallet; אם לא בטוחים שזה הכרטיס הרצוי, בטלו וסרקו כרטיס אחד בלבד.","Local numbering does not match Wallet card order. If you cannot identify the intended card confidently, cancel and discover only one card.")).font(.callout).foregroundStyle(.secondary) }
                        if !pending.isMock {
                            Toggle(t("אני מאשר/ת את הסיכון לאובדן נתוני Books ולשינוי שלא ניתן לשחזר, ומזהה את כרטיס היעד.","I accept possible Books data loss and irreversible artwork changes, and I identify this target card."),isOn:$state.experimentalRiskAccepted)
                        }
                        HStack {
                            Button(t("ביטול","Cancel")) { cancelConfirmation() }.keyboardShortcut(.cancelAction)
                            Spacer()
                            Button(pending.isMock ? t("הפעלת בדיקה","Run mock test") : t("אני מאשר/ת את השינוי","Confirm modification")) { applyConfirmedSnapshot() }.buttonStyle(.borderedProminent).disabled(!pending.isMock && !state.experimentalRiskAccepted)
                        }
                    }.padding(28).frame(width:490).environment(\.layoutDirection,state.english ? .leftToRight:.rightToLeft)
                }
            }
            .onAppear {
                state.needsDeveloperTools = !SetupSupport.toolsAvailable
                if ProcessInfo.processInfo.arguments.contains("--demo") { device.isMock = true }
                else if !state.needsDeveloperTools { device.refresh() }
            }
            .onDisappear { library.save(editor) }
            .onChange(of:device.selectedCardID) { _,_ in library.switchCard(device:device.selectedDeviceID,card:device.selectedCardID,editor:editor) }
            .onChange(of:device.selectedDeviceID) { _,_ in library.switchCard(device:device.selectedDeviceID,card:device.selectedCardID,editor:editor) }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification)) { _ in library.save(editor) }
    }
    private var connectionBar: some View {
        HStack(spacing:14) {
            Image(systemName: selectedPhone == nil ? "iphone" : "iphone.gen3.radiowaves.left.and.right").font(.title2).foregroundStyle(selectedPhone == nil ? Color.secondary : Color.blue)
            VStack(alignment:.leading,spacing:3) {
                if let phone = selectedPhone {
                    Text(device.isMock ? t("iPhone לדוגמה", "Demo iPhone") : phone.displayName).font(.headline)
                    Text(phone.eligible ? t("מחובר · מוכן לזיהוי כרטיס", "Connected · ready to discover") : t("מחובר · iOS \(phone.version) אינו נתמך להחלה. אפשר לעצב ולשמור תמונה.", "Connected · iOS \(phone.version) cannot apply artwork. Design and export are available."))
                        .font(.caption).foregroundStyle(phone.eligible ? Color.secondary : Color.orange)
                } else {
                    Text(t("חברו את האייפון", "Connect your iPhone")).font(.headline)
                    Text(t("כבל USB, פתיחת נעילה ואישור אמון ב־Finder.", "Use USB, unlock, and confirm Trust in Finder.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if device.devices.count > 1 {
                Picker(t("מכשיר", "Device"),selection:$device.selectedDeviceID) {
                    ForEach(device.devices) { phone in Text(phone.displayName).tag(Optional(phone.id)) }
                }.labelsHidden().frame(width:180).disabled(device.busy || state.confirmation)
            }
            if device.busy && !device.scanning { ProgressView().controlSize(.small) }
            if state.needsDeveloperTools {
                Button(t("הכנת החיבור", "Set up connection")) { state.showHelp = true }
            }
            Button { device.refresh() } label: { Label(t("רענון", "Refresh"),systemImage:"arrow.clockwise") }.disabled(device.busy || state.needsDeveloperTools)
        }
    }

    private var cardSidebar: some View {
        VStack(alignment:.leading,spacing:14) {
            Label(t("הכרטיס", "Card"),systemImage:"creditcard").font(.headline)
            Text(t("התחילו זיהוי והציגו את הכרטיס הרצוי ב־Wallet.", "Start discovery and display your card in Wallet.")).font(.callout).foregroundStyle(.secondary)
            if device.scanning {
                ProgressView()
                Text(device.scanRemainingSeconds.map { t("נותרו \($0) שניות", "\($0) seconds left") } ?? t("מתחבר…", "Connecting…")).font(.callout.monospacedDigit())
                Button(t("עצירה", "Stop")) { device.stopScan() }.disabled(device.stoppingScan)
            } else {
                Button { device.discover() } label: { Label(t("זיהוי כרטיס", "Discover card"),systemImage:"wave.3.right") }
                    .buttonStyle(.borderedProminent).disabled(!canScan)
            }
            if device.cards.isEmpty {
                VStack(spacing:10) {
                    Image(systemName:"creditcard").font(.system(size:30)).foregroundStyle(.tertiary)
                    Text(t("עדיין אין כרטיס", "No card yet")).font(.callout)
                    Text(t("אפשר להתחיל לעצב בינתיים", "You can start designing now")).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity).padding(.vertical,28).background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius:14))
            } else {
                ScrollView {
                    VStack(spacing:8) {
                        ForEach(device.cards.filter { $0.deviceID == device.selectedDeviceID }) { card in
                            Button { device.selectedCardID = card.id } label: {
                                VStack(alignment:.leading,spacing:6) {
                                    HStack { Image(systemName: device.selectedCardID == card.id ? "checkmark.circle.fill" : "circle"); Text(cardTitle(card)).lineLimit(1).minimumScaleFactor(0.7) }
                                    Text(card.source == "live" ? t("זוהה עכשיו", "Discovered now") : t("נדרש זיהוי מחדש", "Discover again")).font(.caption).foregroundStyle(card.source == "live" ? Color.secondary : Color.orange)
                                }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                                    .background(device.selectedCardID == card.id ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius:12))
                            }.buttonStyle(.plain).disabled(device.busy || state.confirmation)
                        }
                    }
                }
            }
            Spacer(minLength:0)
            Text(t("המספור מקומי. שם הבנק ותמונת המקור אינם נקראים.", "Numbers are local. Bank names and original artwork are not read.")).font(.caption).foregroundStyle(.secondary)
        }.frame(maxHeight:.infinity)
    }

    private var designSidebar: some View {
        VStack(alignment:.leading,spacing:12) {
            Label(t("עיצובים", "Designs"),systemImage:"paintpalette").font(.headline)
            ForEach(["midnight", "sage", "sunset"],id: \.self) { name in
                if let url = Bundle.main.url(forResource:name,withExtension:"png",subdirectory:"StarterDesigns"), let image = NSImage(contentsOf:url) {
                    Button { editor.load(url) } label: {
                        VStack(alignment:.leading,spacing:5) {
                            Image(nsImage:image).resizable().aspectRatio(1536.0/969.0,contentMode:.fit).clipShape(RoundedRectangle(cornerRadius:9))
                            HStack { Text(designTitle(name)).font(.caption); Spacer(); if editor.loadedURL == url { Image(systemName:"checkmark.circle.fill").foregroundStyle(Color.accentColor) } }
                        }.padding(6).background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius:12))
                            .overlay(RoundedRectangle(cornerRadius:12).stroke(editor.loadedURL == url ? Color.accentColor : Color.clear,lineWidth:2))
                    }.buttonStyle(.plain).disabled(device.busy || state.confirmation)
                }
            }
            Button(t("התאמת התמונה", "Image adjustments")) { state.showAdjustments.toggle() }
                .popover(isPresented:$state.showAdjustments) { advancedAdjustments.padding(20).frame(width:300) }
            Spacer(minLength:0)
        }
    }

    private var actionBar: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:16) {
                VStack(alignment:.leading,spacing:4) {
                    Text(device.needsWalletVerification ? t("בדקו את הכרטיס ב־Wallet", "Check your card in Wallet") : t("מוכנים?", "Ready?")).font(.headline)
                    Text(device.needsWalletVerification ? t("פתחו את Wallet מחדש ובדקו את העיצוב.", "Reopen Wallet and check the artwork.") : shortNextAction).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(t("שמירת תמונה…", "Save image…")) { library.save(editor); editor.export() }.disabled(editor.image == nil)
                if device.needsWalletVerification {
                    Button(t("העיצוב מופיע בכרטיס הנכון", "Artwork is on the correct card")) { device.confirmWalletAppearance() }.buttonStyle(.borderedProminent)
                } else {
                    Button(device.isMock ? t("בדיקת הדגמה…", "Test demo…") : t("בדיקה והחלה…", "Review and apply…")) { prepareConfirmation() }
                        .buttonStyle(.borderedProminent).disabled(device.busy || !device.canApply || editor.image == nil)
                }
            }
            if showOperationStatus { Text(state.english ? device.statusEnglish : device.status).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if let error = state.actionError { Text(error).font(.caption).foregroundStyle(.red) }
            Text(t("ההחלה ניסיונית: סיכון לנתוני Books, ללא שחזור מאומת. אישור נפרד לפני כל שינוי.", "Experimental Apply: Books data is at risk; restoration is unverified. Each change requires confirmation.")).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var showOperationStatus: Bool {
        if device.busy || device.needsWalletVerification { return true }
        if let phone = selectedPhone, device.status == phone.connectionStatus(english:false) { return false }
        return ![
            "חברו iPhone באמצעות USB, פתחו אותו ואשרו אמון ב־Finder.",
            "מצב הדגמה — אין תקשורת עם iPhone ואין שינוי במכשיר.",
            "המכשיר זוהה. טווח הגרסאות מבוסס על טענת AirCard; התאימות לא אומתה במכשיר."
        ].contains(device.status)
    }
    private var shortNextAction: String {
        if editor.image == nil { return t("בחרו עיצוב מוכן או תמונה מהמחשב.", "Choose a design or add an image.") }
        if selectedPhone?.eligible != true && !device.isMock { return t("העיצוב מוכן לשמירה. להחלה נדרש iPhone נתמך.", "Ready to save. Applying requires a supported iPhone.") }
        if !device.canApply { return t("לשינוי ב־Wallet: זהו ובחרו כרטיס תחילה.", "To change Wallet, discover and select a card first.") }
        return t("בדקו את הכרטיס והעיצוב, והמשיכו לאישור.", "Check your card and artwork, then review.")
    }
    private var helpPanel: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(t("איך זה עובד?", "How does it work?")).font(.title3.bold())
            Text(t("1. מחברים iPhone ומזהים כרטיס.\n2. בוחרים עיצוב או תמונה.\n3. בודקים ומאשרים החלה.", "1. Connect iPhone and discover a card.\n2. Choose a design or image.\n3. Review and confirm Apply."))
            Text(t("אפשר לעצב ולשמור תמונה גם בלי טלפון.", "You can design and export without a phone.")).foregroundStyle(.secondary)
            Toggle(t("מצב הדגמה", "Demo mode"),isOn:$device.isMock).disabled(device.busy)
            if state.needsDeveloperTools { setupHelp }
            Button(t("המדריך המלא", "Full guide")) { NSWorkspace.shared.open(URL(string:"https://github.com/razmazlih/walletskin-studio#readme")!) }
        }.padding(24).frame(width:360).environment(\.layoutDirection,state.english ? .leftToRight:.rightToLeft)
    }
    private var setupHelp: some View {
        VStack(alignment:.leading,spacing:10) {
            Label(t("הכנה חד־פעמית למק הזה", "One-time Mac setup"),systemImage:"shippingbox").font(.headline)
            Text(t("לחיבור לאייפון נדרש רכיב כלים של Apple, שכולל Python. לחצו על התקנה ואשרו בחלון של Apple. אחרי שההתקנה תסתיים, חזרו לכאן ולחצו על ׳בדיקת ההתקנה׳. אין צורך לכתוב פקודות.", "iPhone connection needs Apple's tools, including Python. Click Install and confirm Apple's dialog. When installation finishes, return and click Check installation. No commands needed."))
            HStack {
                Button(t("התקנת רכיב Apple…", "Install Apple component…")) {
                    do { try SetupSupport.requestToolsInstallation() }
                    catch { state.actionError = t("לא ניתן לפתוח את מתקין Apple. ראו את פתרון התקלות ב־README.", "Could not open Apple's installer. See README troubleshooting.") }
                }.buttonStyle(.borderedProminent)
                Button(t("בדיקת ההתקנה", "Check installation")) {
                    state.needsDeveloperTools = !SetupSupport.toolsAvailable
                    if !state.needsDeveloperTools && !device.isMock { device.refresh() }
                }
            }
            if let error = state.actionError { Text(error).foregroundStyle(.red) }
        }.padding(20).background(Color.orange.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius:20))
    }
    private var advancedAdjustments: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(t("התאמת התמונה", "Image adjustments")).font(.headline)
            VStack(alignment:.leading,spacing:12) {
                Toggle(t("מילוי מלא ללא שוליים (מתיחה)", "Fill entire card (stretch)"),isOn:$editor.stretchToFill)
                Toggle(t("הסרת שוליים בהירים מהתמונה", "Remove light image margins"),isOn:$editor.removeLightMargins)
                if !editor.stretchToFill { Toggle(t("שמירת יחס מקורי עם שוליים", "Keep original aspect ratio with padding"),isOn:$editor.fitWholeImage) }
                Text(t("זום לחיתוך ידני", "Zoom for manual crop"))
                Slider(value:$editor.zoom,in:1...4).disabled(editor.image == nil || editor.fitWholeImage || editor.stretchToFill)
                Button(t("איפוס חיתוך", "Reset crop")) { editor.zoom = 1; editor.pan = .zero }.disabled(editor.image == nil || editor.fitWholeImage || editor.stretchToFill)
            }.padding(.top,8)
        }
    }
    private func designTitle(_ name:String) -> String {
        switch name {
        case "midnight": return t("לילה כחול", "Midnight")
        case "sage": return t("מרווה", "Sage")
        default: return t("שקיעה", "Sunset")
        }
    }
    private func prepareConfirmation() {
        guard !device.busy, let phone = device.devices.first(where: { $0.id == device.selectedDeviceID }),
              let card = device.cards.first(where: { $0.id == device.selectedCardID && $0.deviceID == phone.id }), editor.image != nil else { return }
        do {
            library.save(editor)
            let prepared = try editor.preparedURL()
            state.pending = ApplySnapshot(deviceID:phone.id,cardID:card.id,deviceTitle:"\(phone.name) · iOS \(phone.version)",cardTitle:cardTitle(card),isMock:device.isMock,imageURL:prepared)
            state.experimentalRiskAccepted = false; state.actionError = nil; state.confirmation = true
        } catch { state.actionError = error.localizedDescription }
    }
    private func cancelConfirmation() {
        if let pending = state.pending { try? FileManager.default.removeItem(at:pending.imageURL) }
        state.pending = nil; state.confirmation = false
    }
    private func applyConfirmedSnapshot() {
        guard let pending = state.pending else { return }
        guard pending.isMock || state.experimentalRiskAccepted else { return }
        guard device.selectedDeviceID == pending.deviceID, device.selectedCardID == pending.cardID, device.isMock == pending.isMock, !device.busy else {
            state.actionError = t("המכשיר או הכרטיס השתנו. בחרו שוב ואשרו מחדש.","Device or card changed. Select again and confirm anew.")
            cancelConfirmation(); return
        }
        state.lastSubmitted = pending
        state.confirmation = false; state.pending = nil
        device.apply(imageURL:pending.imageURL,confirmed:true,experimentalRiskAccepted:state.experimentalRiskAccepted)
    }
}
