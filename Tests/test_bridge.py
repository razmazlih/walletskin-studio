import importlib.util
from pathlib import Path
import os
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('bridge', Path(__file__).parents[1] / 'Resources/bridge.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

class BridgeTests(unittest.TestCase):
    def test_versions(self):
        for version in ['18.0', '26.1', '27.0.1']:
            self.assertTrue(bridge.compatibility(version, 'iPhone18,1', '24A100')[0])
        for version in ['17.9', '27.0.2', '28.0', '27.0 beta', 'bad']:
            self.assertFalse(bridge.compatibility(version, 'iPhone18,1', '24A100')[0])
        self.assertFalse(bridge.compatibility('27.0.1', 'iPhone18,1', '24A100a')[0])
        self.assertFalse(bridge.compatibility('27.0.1', '', '24A100')[0])
        self.assertFalse(bridge.compatibility('27.0.1', 'iPhone18,1', '')[0])
    def test_path_only_and_sanitization(self):
        ident = 'a' * 27 + '='
        self.assertEqual(bridge.parse_card('/var/mobile/Library/Passes/Cards/' + ident + '.pkpass/cardBackground.png'), ident)
        for line in ['payment token secret', 'identifier=' + ident, '/Cards/../../etc.pkpass', '/Cards/' + 'a'*45 + '.pkpass']:
            self.assertIsNone(bridge.parse_card(line))
    def test_wallet_context_for_upstream_structured_paths(self):
        ident = 'QwertyUiopAsdfghJklZxcvbnm12='
        for line in [f'passd: /cache/{ident}.pkcache', f'PassKit: VerificationCheck.{ident}', f'Passbook: Dashboard loading card: for {ident},', f'Wallet: Dashboard loading card: {ident} - loaded']:
            self.assertEqual(bridge.parse_cards(line), [ident])
        self.assertEqual(bridge.parse_cards(f'unrelated: /cache/{ident}.pkcache'), [])

    def test_disabled_modifications(self):
        with patch.object(bridge.subprocess, 'run') as run:
            for command in ['apply', 'backup', 'restore', 'probe']:
                with self.assertRaises(RuntimeError):
                    bridge.handle({'command': command, 'deviceID': '../../', 'cardID': '../'})
            run.assert_not_called()
    def test_exact_device_and_disconnect(self):
        with patch.object(bridge, 'devices', return_value=[dict(id='device-111', eligible=True)]):
            self.assertEqual(bridge.require_device('device-111')['id'], 'device-111')
            with self.assertRaisesRegex(RuntimeError, 'disconnected'):
                bridge.require_device('device-222')
            with self.assertRaisesRegex(RuntimeError, 'invalid'):
                bridge.require_device('../device-111')
    def test_structured_upstream_pass_events(self):
        ident = 'G'*27+'='
        for line in [f'PDCardFileManager: writing card {ident}',
                     f'PDPassLibrary: wrote pass {ident}',
                     f'selected pass uniqueID: "{ident}"',
                     f'/var/mobile/Library/Passes/Cards/{ident}/cardBackground.png',
                     f'/Cards/{ident}']:
            self.assertEqual(bridge.parse_cards(line), [ident], line)
    def test_session_lists_all_cards_order_deduplication(self):
        first, second = 'G'*27+'=', 'H'*27+'='
        line = f'passIDs[InSession]: {{ ("{second}", "{first}", "{second}") }}'
        self.assertEqual(bridge.parse_cards(line), [second, first])
        self.assertEqual(bridge.parse_cards(f'passIDs[global]: ({first}, {second})'), [first, second])
    def test_sensitive_generic_and_placeholder_ids_excluded(self):
        ident = 'G'*27+'='
        for line in [f'identifier={ident}', f'payment token {ident}',
                     f'setActivePaymentApplet requestedApplet: identifier = {ident}',
                     'selected pass uniqueID: "'+'G'*45+'"',
                     'PDPassLibrary: wrote pass '+'0123456789ABCDEF'*2,
                     'PDPassLibrary: wrote pass 12345678-1234-1234-1234-123456789abc',
                     f'PDCardFileManager: writing card {next(iter(bridge.PLACEHOLDERS))}']:
            self.assertEqual(bridge.parse_cards(line), [], line)
    def test_failed_pairing(self):
        with patch.object(bridge, 'devices', return_value=[dict(id='device-111', eligible=False, reason='pairing_required')]):
            with self.assertRaisesRegex(RuntimeError, 'pairing_required'):
                bridge.require_device('device-111')

class FakeScanner:
    def __init__(self, lines=b'', exit_code=0):
        read_fd, write_fd = os.pipe()
        os.write(write_fd, lines)
        os.close(write_fd)
        self.stdout = os.fdopen(read_fd, 'rb', buffering=0)
        self.exit_code = exit_code
        self.terminated = False
        self.killed = False
    def poll(self):
        return self.exit_code
    def terminate(self):
        self.terminated = True
    def kill(self):
        self.killed = True
    def wait(self, timeout=None):
        return self.exit_code
    def close(self):
        self.stdout.close()

class ScanTests(unittest.TestCase):
    def run_scan(self, scanner, identifier='device-111', duration=.1):
        with patch.object(bridge.subprocess, 'Popen', return_value=scanner) as process:
            result = bridge.discover(identifier, duration)
            self.assertEqual(process.call_args.args[0], [str(bridge.HELPER), 'syslog', identifier])
            self.assertEqual(process.call_args.kwargs['stderr'], bridge.subprocess.DEVNULL)
            return result
    def test_live_scan_multiple_cards_exact_device_no_credentials(self):
        first, second = 'a'*27+'=', 'b'*27+'='
        lines = (f'PAN 4111111111111111 CVV 123 token TOPSECRET\n'
                 f'/Cards/{first}.pkpass/cardBackgroundCombined@3x.png\n'
                 f'/Cards/{first}.cache/FrontFace\n'
                 f'/Cards/{second}.pkpass/cardBackgroundCombined@2x.png\n').encode()
        scanner = FakeScanner(lines)
        try:
            with patch.object(bridge, 'require_device', return_value=dict(id='device-222', product='iPhone18,1', version='27.0.1')) as require, patch.object(bridge, 'issue_binding', return_value='test-receipt'):
                rows = self.run_scan(scanner, 'device-222')
                self.assertEqual([r['id'] for r in rows], [first])
                self.assertTrue(all(r['source'] == 'live' for r in rows))
                self.assertTrue(all(r['deviceID'] == 'device-222' for r in rows))
                self.assertEqual(require.call_args_list[0].args, ('device-222',))
                self.assertEqual(require.call_args_list[1].args, ('device-222',))
                self.assertNotIn('TOPSECRET', repr(rows))
                self.assertNotIn('4111111111111111', repr(rows))
        finally: scanner.close()
    def test_interrupted_scan_does_not_return_partial_cards(self):
        scanner = FakeScanner(('/Cards/'+'a'*27+'=.pkpass/file\n').encode(), exit_code=2)
        try:
            with patch.object(bridge, 'require_device'):
                with self.assertRaisesRegex(RuntimeError, 'scan_failed'):
                    self.run_scan(scanner)
        finally: scanner.close()
    def test_disconnect_after_scan_discards_results(self):
        scanner = FakeScanner(('/Cards/'+'a'*27+'=.pkpass/file\n').encode())
        try:
            with patch.object(bridge, 'require_device', side_effect=[None, RuntimeError('device_disconnected')]):
                with self.assertRaisesRegex(RuntimeError, 'disconnected'):
                    self.run_scan(scanner)
        finally: scanner.close()
    def test_timeout_stops_child(self):
        scanner = FakeScanner(exit_code=None)
        try:
            with patch.object(bridge, 'require_device', return_value=dict(id='device-111', product='iPhone18,1', version='27.0.1')):
                self.assertEqual(self.run_scan(scanner, duration=0), [])
                self.assertTrue(scanner.terminated)
        finally: scanner.close()
    def test_scan_session_list_returns_every_card_without_raw_log(self):
        first, second = 'G'*27+'=', 'H'*27+'='
        scanner = FakeScanner(f'passIDs[InSession]: ({first}, {second}) secret token TOPSECRET\n'.encode())
        try:
            with patch.object(bridge, 'require_device', return_value=dict(id='device-111', product='iPhone18,1', version='27.0.1')), patch.object(bridge, 'issue_binding', return_value='test-receipt'):
                rows = self.run_scan(scanner)
                self.assertEqual([row['id'] for row in rows], [first, second])
                self.assertNotIn('TOPSECRET', repr(rows))
        finally: scanner.close()
    def test_first_matching_event_ends_scan_and_closes_child(self):
        first, second = 'G'*27+'=', 'H'*27+'='
        scanner = FakeScanner(f'/Cards/{first}.pkpass/file\n/Cards/{second}.pkpass/file\n'.encode(), exit_code=None)
        with patch.object(bridge, 'require_device', return_value=dict(id='device-111', product='iPhone18,1', version='27.0.1')), patch.object(bridge, 'issue_binding', return_value='receipt') as receipt:
            rows = self.run_scan(scanner, duration=45)
            self.assertEqual([row['id'] for row in rows], [first])
            receipt.assert_called_once()
            self.assertTrue(scanner.terminated)
            self.assertTrue(scanner.stdout.closed)

    def test_cancel_at_ready_event_reaps_child_and_issues_no_receipt(self):
        scanner = FakeScanner(exit_code=None)
        original_handler = bridge.signal.getsignal(bridge.signal.SIGTERM)
        def cancel(_phase):
            bridge.signal.getsignal(bridge.signal.SIGTERM)(bridge.signal.SIGTERM, None)
        with patch.object(bridge, 'require_device'), patch.object(bridge, 'progress', side_effect=cancel), patch.object(bridge, 'issue_binding') as receipt:
            with self.assertRaisesRegex(RuntimeError, '^scan_cancelled$'):
                self.run_scan(scanner, duration=45)
            receipt.assert_not_called()
        self.assertTrue(scanner.terminated)
        self.assertTrue(scanner.stdout.closed)
        self.assertEqual(bridge.signal.getsignal(bridge.signal.SIGTERM), original_handler)

    def test_pairing_failure_never_starts_scanner(self):
        with patch.object(bridge, 'require_device', side_effect=RuntimeError('pairing_required')):
            with patch.object(bridge.subprocess, 'Popen') as process:
                with self.assertRaisesRegex(RuntimeError, 'pairing_required'):
                    bridge.discover('device-111')
                process.assert_not_called()
    def test_modifications_never_launch_any_subprocess(self):
        with patch.object(bridge.subprocess, 'Popen') as spawn, patch.object(bridge.subprocess, 'run') as run:
            for command in ['apply', 'backup', 'restore', 'probe']:
                with self.assertRaises(RuntimeError):
                    bridge.handle({'command': command, 'deviceID': 'device-111'})
            spawn.assert_not_called()
            run.assert_not_called()

if __name__ == '__main__':
    unittest.main()
