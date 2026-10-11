# עדכון 0.3.0 — החלה ניסיונית באישור המשתמש

המשתמש אישר במפורש להחזיר החלה למרות הסיכון לאובדן נתוני Books. הסיכון לא תוקן; ההסכמה אינה הוכחת בטיחות. החלה דורשת כרטיס מסריקה חיה, confirmed=true וגם experimentalRiskAccepted=true, ואישור נפרד בכל חלון החלה לתמונה, למכשיר ולכרטיס המדויקים. מזהה מהיסטוריה אינו אישור כתיבה. אין שחזור מאומת לתמונת המקור ואין הצלחה פיזית מאומתת בסביבה הזו.

RestoreBooksState עדיין עשוי לדרוס שינוי מקביל או לשחזר SQLite/WAL/SHM באופן לא עקבי. הרכיבים המקומיים אינם גבול אבטחה מול תוכנה שכבר פועלת באותו חשבון. האישור חל על השימוש באפליקציה; אין לבצע החלה אוטומטית מהסקריפטים.

הערות על חסימת כתיבה בהמשך מתארות את גרסאות 0.2.1–0.2.4 בלבד.

# Security and compatibility review

Reviewed upstream: https://github.com/Mak5er/AirCard
Pinned commit: `52ba05dca4bdc590672c19d554701f4438e20338`.
MIT, copyright 2026 Johnny Franks. AirCard and AirLift by 0xjohnny are credited; source and license are preserved in `upstream/AirCard`.

## Real Apply uses the existing upstream mechanism

The user's follow-up requested actual Apply after investigating artwork sites. The app now integrates AirCard's existing artwork-writing mechanism rather than another communication system. Modification requires explicit in-app confirmation for the exact selected device, freshly discovered card and prepared image. The confirmation explains that the operation changes Wallet artwork, temporarily stages files in Media/Airlock and snapshots/replaces/restores fixed Books synchronization metadata. Those auxiliary writes are necessary; the app cannot honestly promise that only artwork paths are touched.

Original-artwork backup remains disabled: upstream `read_file` moves and rewrites the original and may return bytes even after incomplete cleanup. No reliable Restore Original action is exposed. A Books staging snapshot is **not** a backup of original Wallet artwork. Interruption may leave a partially changed card and incomplete staging; never call this successful or replay writes automatically.

## Scope and privacy

Only current USB-connected, trusted iPhones are eligible. The helper is source-built, uses direct connections only, and does not perform automatic pairing. Finder and the phone handle Trust. Fresh live discovery binds each card to its exact device; arbitrary card IDs, paths and filenames are rejected. Artwork assets are fixed to `cardBackgroundCombined@3x.png`, `cardBackgroundCombined@2x.png` and `cardBackgroundCombined.pdf` under the selected `.pkpass`. Cache leaves are fixed to `FrontFace`, `PlaceHolder`, `Preview` under that card's `.cache`/`.pkcache`. Native command/argument checks and bundle-local validation constrain archive targets, generated staging names and sync requests. No generic read command, canary probe, arbitrary file writer or original-artwork recovery command is exposed.

Discovery reads unified logs, which can contain unrelated personal information. Raw lines are consumed transiently, parsed for artwork card paths and discarded. They are never saved or displayed. Output/errors are sanitized. Device IDs/card hashes are local association identifiers, not payment numbers. The app never collects card numbers, CVV, payment tokens, banking passwords or Apple ID credentials, and does not access the Secure Element or transaction databases. Pairing material stays managed by macOS and is not exported.

Local prepared images, discovery bindings and recovery data use private filesystem permissions. Recovery data can contain Books metadata; keep it private and do not attach it to public bug reports. No telemetry, remote API, image uploads, cloud service, account or automatic binary download.

## Compatibility and success evidence

The pinned README claims iOS 18.0–27.0.1 and 27.2 beta 1–2; states beta 3+ patched. WalletSkin conservatively excludes all beta, unknown and newer releases. A version in the range is an upstream claim, not verified support for the user's phone. Native upstream `TargetGate` accepted every iPhone and `probe` proved only AFC/session access; this app adds its own conservative gates and never treats a probe as exploit compatibility.

Header records list only three iOS 27.0 builds. Documented upstream iPhone 15 Pro/iOS 18.6.2 scan validation did not verify artwork writing or on-phone display. No real card modification has been verified in this environment. Backend transport and staging cleanup completion are separate from visible artwork; after reopening Wallet, the user must check the exact card and explicitly confirm whether it appears correctly.

Private Apple frameworks can change after updates. Scan logs may omit/redact identifiers; names/order are not authoritative. Apple Card uses dynamic rendering and is not a suitable static-artwork target. The app does not try to bypass newly patched protections.

## Build and review boundary

Builds use local Xcode/Command Line Tools, Python standard library and Apple frameworks. No sudo, SIP/Gatekeeper changes or quarantine clearing. Generated bundles in File Provider directories can acquire FinderInfo; build cleanup removes only that generated non-security metadata and packages from a normal temporary directory. Ad-hoc signing is free and does not imply notarization or Apple endorsement. Universal compilation does not prove Intel runtime compatibility.

Automated tests use isolated mocks and must never invoke a device modification. Physical Trust, scan, Apply, interrupted cleanup and Wallet appearance require manual testing on an authorized phone. See DEVICE-VALIDATION.md and VALIDATION.md for precise completed/pending evidence.
