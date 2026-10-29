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
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                HStack {
                    Image(systemName:"wallet.bifold.fill").font(.system(size:31)).foregroundStyle(.blue)
                    VStack(alignment:.leading,spacing:4) { Text("WalletSkin Studio").font(.largeTitle.bold()); Text(t("עיצוב אישי. על המחשב שלך.","Personal artwork. On your Mac.")).foregroundStyle(.secondary) }
                    Spacer()
                    Toggle("English",isOn:$state.english).toggleStyle(.switch).fixedSize()
                }
                quickStart(proxy)
                if state.needsDeveloperTools { setupHelp }
                if device.isMock {
                    Label(t("מצב הדגמה — אין גישה או כתיבה ל־iPhone","MOCK MODE — no iPhone access or writes"),systemImage:"testtube.2").font(.headline).foregroundStyle(.orange)
                }
                group(t("1 · חיבור ה־iPhone","1 · Connect iPhone"),icon:"iphone") {
                    HStack(alignment:.top,spacing:20) {
                        VStack(alignment:.leading,spacing:9) {
                            Text(t("חברו בכבל USB, פתחו את נעילת ה־iPhone ואשרו ׳לתת אמון׳ אם תתבקשו.","Connect USB, unlock your iPhone, and accept Trust if prompted.")).foregroundStyle(.secondary)
                            if device.devices.isEmpty { Text(t("לא זוהה מכשיר מחובר","No connected device detected")).font(.headline) }
                            ForEach(device.devices) { phone in
                                HStack {
                                    Button { device.selectedDeviceID = phone.id; device.selectedCardID = nil } label: {
                                        Label("\(device.isMock && state.english ? "Demo iPhone" : phone.name) · \(phone.product) · iOS \(phone.version)",systemImage:device.selectedDeviceID == phone.id ? "checkmark.circle.fill":"circle")
                                    }.buttonStyle(.borderless).disabled(device.busy || state.confirmation)
                                    Spacer()
                                    Text(phone.eligible ? t("בטווח המדווח; טרם אומת","Reported range; unverified") : t("לא נתמך או ללא אמון","Unsupported or untrusted")).font(.caption).foregroundStyle(phone.eligible ? Color.blue:Color.orange)
                                }
                            }
                        }
                        Spacer()
                        VStack {
                            Button(t("רענון וחיבור מחדש","Refresh connection")) { device.refresh() }.disabled(device.busy || state.needsDeveloperTools)
                            Toggle(t("מצב הדגמה","Mock mode"),isOn:$device.isMock).toggleStyle(.switch).disabled(device.busy)
                        }.fixedSize(horizontal:true,vertical:false)
                    }
                }
                group(t("2 · בחירת הכרטיס","2 · Choose card"),icon:"rectangle.stack") {
                    VStack(alignment:.leading,spacing:12) {
                        Text(t("לחצו על גילוי ואז פתחו את Wallet ב־iPhone והפעילו את הכרטיס הרצוי. הזיהוי מבוסס על מזהה נכס; שם הבנק והתמונה המקורית אינם נקראים. המספר המקומי אינו סדר הכרטיסים ב־Wallet.","Start discovery, then open Wallet on iPhone and activate the intended card. Discovery identifies an artwork asset; bank names and original artwork are not read. Local numbering does not reflect Wallet card order.")).font(.callout).foregroundStyle(.secondary)
                        Button(t("גילוי כרטיס פעיל (45 שניות)","Discover active card (45 seconds)")) { device.discover() }.disabled(device.busy || device.selectedDeviceID == nil)
                        if device.scanning {
                            HStack {
                                if let seconds = device.scanRemainingSeconds {
                                    Text(t("נותרו \(seconds) שניות", "\(seconds) seconds remaining")).monospacedDigit()
                                } else { Text(t("מתחבר לסריקה…", "Connecting to discovery…")) }
                                ProgressView().controlSize(.small)
                                Spacer()
                                Button(t("עצירת הבדיקה", "Stop discovery")) { device.stopScan() }.disabled(device.stoppingScan)
                            }
                        }
                        if device.cards.isEmpty { Text(t("טרם זוהו כרטיסים","No cards discovered yet")).foregroundStyle(.secondary) }
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:210))],spacing:12) {
                            ForEach(device.cards.filter { $0.deviceID == device.selectedDeviceID }) { card in
                                Button { device.selectedCardID = card.id } label: {
                                    VStack(alignment:.leading,spacing:18) {
                                        ZStack {
                                            if let artwork = library.savedImage(device:card.deviceID,card:card.id) {
                                                Image(nsImage:artwork).resizable().aspectRatio(1536.0/969.0,contentMode:.fit)
                                            } else {
                                                RoundedRectangle(cornerRadius:9).fill(.white.opacity(0.12))
                                                Image(systemName:"creditcard").font(.system(size:32)).foregroundStyle(.white.opacity(0.7))
                                            }
                                        }.aspectRatio(1536.0/969.0,contentMode:.fit).clipShape(RoundedRectangle(cornerRadius:9))
                                        HStack { Image(systemName:"creditcard.fill"); Spacer(); if device.selectedCardID == card.id { Image(systemName:"checkmark.circle.fill") } }
                                        Text(cardTitle(card)).font(.headline)
                                        if card.source == "live" {
                                            Label(t("זוהה בבדיקה הנוכחית", "Discovered in this scan"),systemImage:"checkmark.seal.fill").font(.caption.bold()).padding(7).background(.green.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius:7))
                                        }
                                        if card.source == "history" { Text(t("זוהה בעבר — נוכחותו טרם אומתה מחדש", "Previously discovered — current presence unverified")).font(.caption).foregroundStyle(.orange) }
                                        Text(t("נכס מזוהה · ללא פרטי תשלום","Identified asset · no payment details")).font(.caption)
                                    }.frame(maxWidth:.infinity,alignment:.leading).padding(17).background(LinearGradient(colors:[.blue.opacity(0.9),.indigo.opacity(0.8)],startPoint:.topLeading,endPoint:.bottomTrailing)).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius:15))
                                }.buttonStyle(.plain).disabled(device.busy || state.confirmation)
                            }
                        }
                    }
                }
                group(t("3 · בחירת העיצוב","3 · Choose artwork"),icon:"slider.horizontal.3") {
                    starterDesigns
                    ViewThatFits(in:.horizontal) {
                    HStack(alignment:.top,spacing:24) {
                        ArtworkCanvas(editor:editor).frame(minWidth:400,maxWidth:610).onDrop(of:[UTType.fileURL],isTargeted:nil) { providers in
                            guard let provider = providers.first else { return false }
                            _ = provider.loadObject(ofClass:URL.self) { url,_ in if let url { Task { @MainActor in editor.load(url) } } }
                            return true
                        }
                        VStack(alignment:.leading,spacing:15) {
                            advancedAdjustments
                            Button(t("בחירת תמונה מהמחשב…","Choose image from Mac…")) { editor.choose() }.buttonStyle(.borderedProminent)
                            Text(editor.stretchToFill ? t("התמונה ממלאת את כל הכרטיס. יחס הממדים משתנה לפי הצורך, ללא שוליים שהאפליקציה מוסיפה.","The image fills the entire card. Its aspect ratio changes as needed; the app adds no padding.") : editor.fitWholeImage ? t("התמונה הסופית נשמרת במלואה ללא חיתוך או עיוות. אם היחס שונה מ־1536×969 יתווספו שוליים לבנים.","The final image stays complete without cropping or distortion. Other aspect ratios receive white padding.") : t("גררו להזזה ושנו את הזום לחיתוך. המקור נשאר ללא שינוי.","Drag to reposition and adjust zoom to crop. The original stays unchanged.")).font(.callout).foregroundStyle(.secondary)
                            Text("1536 × 969 · PNG").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Button(t("ייצוא PNG…","Export PNG…")) { library.save(editor); editor.export() }.disabled(editor.image == nil)
                        }.frame(width:245)
                    }
                    VStack(alignment:.leading,spacing:14) {
                        ArtworkCanvas(editor:editor).onDrop(of:[UTType.fileURL],isTargeted:nil) { providers in
                            guard let provider = providers.first else { return false }
                            _ = provider.loadObject(ofClass:URL.self) { url,_ in if let url { Task { @MainActor in editor.load(url) } } }; return true
                        }
                        HStack { Button(t("בחירת תמונה…","Choose image…")) { editor.choose() }; Button(t("ייצוא PNG…","Export PNG…")) { library.save(editor); editor.export() }.disabled(editor.image == nil) }
                        advancedAdjustments
                    }
                    }
                    if let error = editor.error { Text(error).foregroundStyle(.red) }
                }
                group(t("4 · בדיקה ואישור","4 · Review and confirm"),icon:"lock.shield") {
                    VStack(alignment:.leading,spacing:12) {
                        Text(t("החלה ניסיונית באישורכם: קיים סיכון לדריסת שינויים ולשחזור לא עקבי של נתוני Books. הסיכון לא תוקן. נדרשים זיהוי חי ואישור מפורש לכל החלה.","Experimental Apply at your request: Books changes may be overwritten or restored inconsistently. This risk is unresolved. Fresh discovery and explicit acceptance are required for every Apply.")).foregroundStyle(.red)
                        Text(t("ההחלה משתמשת במנגנון הלא רשמי של AirCard וכותבת גם מטא־נתונים וקבצי ביניים של Books/Media. אין גיבוי או שחזור מקורי מאומת; ניתוק עלול להשאיר פעולה חלקית. בכל החלה נדרש אישור מפורש.","Applying uses AirCard’s unofficial mechanism and also writes Books/Media staging files and sync metadata. Original artwork backup and restoration are unavailable; disconnection may leave an incomplete operation. Every Apply requires explicit confirmation.")).foregroundStyle(.orange)
                        Text(t("זהו מנגנון לא רשמי. תאימות לגרסאות iOS חדשות אינה מובטחת, כולל iOS 27.0.1.","This unofficial mechanism can stop working after iOS updates. Compatibility with iOS 27.0.1 is not established.")).font(.callout).foregroundStyle(.secondary)
                        if let card = device.cards.first(where: { $0.id == device.selectedCardID && $0.deviceID == device.selectedDeviceID }) { Text(t("הכרטיס שנבחר: ","Selected card: ")+cardTitle(card)).font(.headline) }
                        HStack {
                            Button(device.isMock ? t("בדיקת תהליך בהדגמה…","Test mock workflow…") : t("החלה על iPhone…","Apply to iPhone…")) { prepareConfirmation() }
                                .buttonStyle(.borderedProminent).disabled(device.busy || !device.canApply || editor.image == nil)
                            if device.busy { ProgressView().controlSize(.small) }
                            Text(state.english ? device.statusEnglish : device.status).font(.callout).textSelection(.enabled)
                        }
                        if device.needsWalletVerification {
                            if let target = state.lastSubmitted { Text(target.deviceTitle + " · " + target.cardTitle).font(.headline) }
                            Text(t("ההעברה הסתיימה, אך תוצאת Wallet טרם אומתה. סגרו ופתחו שוב את Wallet ובדקו את הכרטיס שנבחר. אם התמונה עדיין לא מתעדכנת, הפעילו מחדש את ה־iPhone.","Transfer completed; Wallet appearance is unverified. Close and reopen Wallet and inspect the selected card. If artwork is still stale, restart the iPhone.")).font(.callout)
                            Button(t("ראיתי את העיצוב בכרטיס הנכון ב־Wallet","I see this artwork on the correct Wallet card")) { device.confirmWalletAppearance() }
                        }
                        if !device.canApply || editor.image == nil {
                            Label(nextAction, systemImage:"info.circle").font(.callout).foregroundStyle(.secondary)
                        }
                        if let actionError = state.actionError { Text(actionError).foregroundStyle(.red) }
                    }
                }
            }.padding(28).frame(maxWidth:1300)
        }.background(Color(nsColor:.windowBackgroundColor)).frame(minWidth:720,minHeight:600)
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
        }
    private var nextAction: String {
        if state.needsDeveloperTools && !device.isMock { return t("לפני החיבור הראשון: התקינו את רכיב Apple בעזרת הכפתור למטה.", "Before connecting: install the Apple component using the button below.") }
        if device.selectedDeviceID == nil { return t("השלב הבא: חברו iPhone בכבל ולחצו על ׳רענון וחיבור מחדש׳.", "Next: connect iPhone by USB, then click Refresh connection.") }
        if !device.isMock, let phone = device.devices.first(where: { $0.id == device.selectedDeviceID }), !phone.eligible { return t("המכשיר אינו נתמך או שטרם אושר אמון. בדקו את החיבור ואת הודעת התאימות בסעיף 1.", "Device unsupported or not yet trusted. Check connection and compatibility in step 1.") }
        if !device.canApply { return t("השלב הבא: לחצו על ׳גילוי כרטיס פעיל׳, הציגו את הכרטיס ב־iPhone ובחרו את הכרטיס שזוהה. זיהוי קודם בלבד אינו מספיק להחלה.", "Next: discover an active card, display it on iPhone, and select the discovered card. History alone cannot authorize Apply.") }
        if editor.image == nil { return t("השלב הבא: בחרו עיצוב מוכן או תמונה מהמחשב בסעיף 3.", "Next: choose a starter design or an image from your Mac in step 3.") }
        return t("התמונה מוכנה לבדיקה. עברו לסעיף 4 וקראו את האזהרה לפני אישור.", "Artwork is ready to review. Read the warning in step 4 before confirming.")
    }
    private func quickStart(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment:.leading,spacing:12) {
            Text(t("מתחילים כאן", "Start here")).font(.title2.bold())
            Text(t("1. מחברים iPhone  ←  2. מזהים כרטיס  ←  3. בוחרים עיצוב  ←  4. בודקים ומאשרים", "1. Connect iPhone  →  2. Discover card  →  3. Choose artwork  →  4. Review and confirm")).font(.headline).fixedSize(horizontal:false,vertical:true)
            Text(t("אפשר לבחור עיצוב ולייצא תמונה גם בלי לחבר טלפון. לשינוי ב־Wallet נדרשים Mac ו־iPhone מחובר בכבל USB.", "Choose artwork and export an image without a phone. Changing Wallet requires a Mac and an iPhone connected by USB.")).foregroundStyle(.secondary)
            HStack {
                ForEach(Array([("1 · חיבור", "1 · Connect", "iphone"), ("2 · כרטיס", "2 · Card", "rectangle.stack"), ("3 · עיצוב", "3 · Artwork", "slider.horizontal.3"), ("4 · אישור", "4 · Review", "lock.shield")].enumerated()),id: \.offset) { _, step in
                    Button(t(step.0,step.1)) { withAnimation { proxy.scrollTo(step.2,anchor:.top) } }.buttonStyle(.bordered)
                }
            }
            Label(nextAction,systemImage:"arrow.forward.circle.fill").font(.callout)
            Text(t("החלה על iPhone היא ניסיונית: קיים סיכון לנתוני Books ואין שחזור מאומת לתמונת המקור. עיצוב וייצוא מקומיים זמינים בלי החלה.", "Applying to iPhone is experimental: Books data is at risk and original artwork restoration is unverified. You can design and export locally without applying.")).font(.caption).foregroundStyle(.orange)
            Button(t("איך מתקינים ומשתמשים? מדריך עם תמונות", "Installation and usage guide with pictures")) {
                NSWorkspace.shared.open(URL(string:"https://github.com/razmazlih/walletskin-studio#readme")!)
            }.buttonStyle(.link)
        }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
            .background(Color.accentColor.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius:20))
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
        DisclosureGroup(t("התאמה מתקדמת (לא חובה)", "Advanced adjustments (optional)")) {
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
    private var starterDesigns: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(t("בלי לחפש תמונות: בחרו עיצוב מוכן", "Start with a ready-made design")).font(.headline)
            LazyVGrid(columns:[GridItem(.adaptive(minimum:170))],spacing:12) {
                ForEach(["midnight", "sage", "sunset"],id: \.self) { name in
                    if let url = Bundle.main.url(forResource:name,withExtension:"png",subdirectory:"StarterDesigns"), let image = NSImage(contentsOf:url) {
                        Button { editor.load(url) } label: {
                            VStack(alignment:.leading,spacing:7) {
                                Image(nsImage:image).resizable().aspectRatio(1536.0/969.0,contentMode:.fit).clipShape(RoundedRectangle(cornerRadius:10))
                                HStack {
                                    Text(designTitle(name)).font(.callout.bold()).foregroundStyle(.primary)
                                    Spacer()
                                    if editor.loadedURL == url { Image(systemName:"checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                                }
                            }.padding(8).background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius:14)).overlay(RoundedRectangle(cornerRadius:14).stroke(editor.loadedURL == url ? Color.accentColor : Color.clear,lineWidth:2))
                        }.buttonStyle(.plain).disabled(device.busy || state.confirmation)
                            .accessibilityLabel(t("בחירת עיצוב ", "Choose design ")+designTitle(name))
                            .accessibilityValue(editor.loadedURL == url ? t("נבחר", "Selected") : "")
                    }
                }
            }
            Text(t("עיצובים מקוריים הכלולים באפליקציה. אפשר להחליף ביניהם או לבחור תמונה משלכם.", "Original artwork included with the app. Switch designs or choose your own image.")).font(.caption).foregroundStyle(.secondary)
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
    private func group<Content:View>(_ title:String,icon:String,@ViewBuilder content:() -> Content) -> some View {
        VStack(alignment:.leading,spacing:16) { Label(title,systemImage:icon).font(.title3.bold()); content() }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(Color(nsColor:.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:20)).overlay(RoundedRectangle(cornerRadius:20).stroke(Color.primary.opacity(0.06))).id(icon)
    }
}
