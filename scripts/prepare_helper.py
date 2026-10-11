#!/usr/bin/env python3
"""Generate constrained AirCard helpers from pinned MIT source; no device execution."""
from pathlib import Path
src = Path('upstream/AirCard/Sources')
out = Path('build/helper-src')
out.mkdir(parents=True, exist_ok=True)
text = (src / 'device_helper.m').read_text()
text = text.replace('AirCardDeviceNotificationOptions(NO)', 'AirCardDeviceNotificationOptions(YES)')
text = text.replace('if (!AMDeviceIsPaired(info->device)) AMDevicePair(info->device);', '/* Pair in Finder explicitly. */')
text = text.replace('if (!AMDeviceIsPaired(device)) AMDevicePair(device);', '/* Pair in Finder explicitly. */')
text = text.replace('extern int AMDevicePair(AMDeviceRef device);', '')
text = text.replace('@"name": @"DeviceName",', '')
text = text.replace('expectedCount <= 32', 'expectedCount <= 3')
text = text.replace('AMDevicePair(session->device);', '/* Pair in Finder explicitly. */')
start = text.index('static BOOL BuildMatches(')
end = text.index('static BOOL SendAll(', start)
text = text[:start] + r'''static BOOL TargetGate(NSDictionary *summary, BOOL *tested) {
    *tested = NO;
    NSString *version = summary[@"productVersion"];
    NSString *build = summary[@"buildVersion"];
    if (![summary[@"productType"] hasPrefix:@"iPhone"] || !version || !build) return NO;
    NSRegularExpression *v = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+\\.[0-9]+(\\.[0-9]+)?$" options:0 error:nil];
    NSRegularExpression *b = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+[A-Z][0-9]+$" options:0 error:nil];
    if ([v numberOfMatchesInString:version options:0 range:NSMakeRange(0, version.length)] != 1 || [b numberOfMatchesInString:build options:0 range:NSMakeRange(0, build.length)] != 1) return NO;
    return [version compare:@"18.0" options:NSNumericSearch] != NSOrderedAscending && [version compare:@"27.0.1" options:NSNumericSearch] != NSOrderedDescending;
}

''' + text[end:]

needle = 'NSString *command = [NSString stringWithUTF8String:argv[1]];'
text = text.replace(needle, needle + '\n        if (![@[@"list", @"syslog", @"snapshot-books", @"stage", @"finish-write", @"finish-moved-removal"] containsObject:command]) return 64;')
needle = 'static NSDictionary *Stage(DeviceSession *session, NSArray<NSString *> *args) {'
guard = '''static BOOL WalletSkinArchiveAllowed(NSArray<NSString *> *args) {
    NSString *exe = NSProcessInfo.processInfo.arguments[0];
    NSString *validator = [[[exe stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"validate_stage.py"];
    NSTask *task = NSTask.new;
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
    task.arguments = @[@"-I", @"-B", validator, args[3], args[4], args[0], args[1]];
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:nil]) return NO;
    [task waitUntilExit];
    return task.terminationStatus == 0;
}
'''
text = text.replace(needle, guard + needle + '\n    if (!WalletSkinArchiveAllowed(args)) return @{ @"ok": @NO, @"error": @"artwork scope rejected" };')
needle = 'static NSDictionary *FinishWrite(DeviceSession *session, NSArray<NSString *> *args) {'
text = text.replace(needle, needle + '\n    if (!GeneratedNamesMatch(args[0], args[1], args[2])) return @{ @"ok": @NO };')
(out / 'device_helper.m').write_text('// Adapted from AirCard, MIT (c) 2026 Johnny Franks.\n' + text)
for name in ['device_discovery.h', 'os_trace.h', 'airlift_target.h']:
    (out / name).write_bytes((src / name).read_bytes())
host = (src / 'airtraffic_host.m').read_text()
# No generic destination arguments: only generated staging links and fixed artwork/cache leaves.
needle = 'signal(SIGPIPE, SIG_IGN);'
guard = r'''NSString *firstID = assets[0][@"identifier"];
        NSString *firstDestination = assets[0][@"destination"];
        NSRegularExpression *tokenPattern = [NSRegularExpression regularExpressionWithPattern:@"^airlift-link-[0-9a-f]{20}$" options:0 error:nil];
        if ([tokenPattern numberOfMatchesInString:firstDestination options:0 range:NSMakeRange(0, firstDestination.length)] != 1) return 64;
        NSString *source = [firstDestination stringByReplacingOccurrencesOfString:@"airlift-link-" withString:@"airlift-src-"];
        if (![firstID isEqual:[NSString stringWithFormat:@"../../%@/p0/p1/p2/link", source]]) return 64;
        if (assets.count < 2 || assets.count > 4) return 64;
        NSArray *artwork = @[@"cardBackgroundCombined@3x.png", @"cardBackgroundCombined@2x.png", @"cardBackgroundCombined.pdf"];
        NSArray *caches = @[@"FrontFace", @"PlaceHolder", @"Preview"];
        BOOL removal = [assets[1][@"destination"] hasPrefix:[source stringByAppendingString:@"/removed-"]];
        NSMutableSet *seen = NSMutableSet.set;
        NSMutableSet *seenIDs = NSMutableSet.set;
        for (NSUInteger i = 1; i < assets.count; i++) {
            NSString *identifier = assets[i][@"identifier"];
            NSString *destination = assets[i][@"destination"];
            if (removal) {
                if (![destination isEqual:[NSString stringWithFormat:@"%@/removed-%lu", source, (unsigned long)i-1]]) return 64;
                NSString *leaf = identifier.lastPathComponent;
                if (![caches containsObject:leaf] || ![identifier isEqual:[NSString stringWithFormat:@"../../%@/%@", firstDestination, leaf]]) return 64;
            } else {
                NSString *leaf = destination.lastPathComponent;
                if (![artwork containsObject:leaf] || ![destination isEqual:[firstDestination stringByAppendingPathComponent:leaf]]) return 64;
                NSString *batch = [NSString stringWithFormat:@"../../%@/payload_%lu", source, (unsigned long)i-1];
                NSString *single = [NSString stringWithFormat:@"../../%@/payload", source];
                if (![identifier isEqual:batch] && !(assets.count == 2 && [identifier isEqual:single])) return 64;
            }
            if ([seen containsObject:destination] || [seenIDs containsObject:identifier]) return 64;
            [seenIDs addObject:identifier];
            [seen addObject:destination];
        }
        '''
host = host.replace(needle, guard + needle)
(out / 'airtraffic_host.m').write_text(host)
