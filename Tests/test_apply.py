import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import zlib

RESOURCES = Path(__file__).parents[1] / 'Resources'
sys.path.insert(0, str(RESOURCES))
import bridge
import aircard_artwork as upstream

OK = dict(exitCode=0, targetGatePassed=True, operation=dict(ok=True, cleanupAuthorized=True))
FAILED = dict(exitCode=2, targetGatePassed=True, operation=dict(ok=False))
DEVICE = dict(id='device-111', product='iPhone18,1', version='27.0.1', eligible=True)
CARD = 'a'*27 + '='

def png(width=1536, height=969):
    def chunk(kind, content):
        return struct.pack('>I', len(content)) + kind + content + struct.pack('>I', zlib.crc32(kind+content)&0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress((b'\0'+b'\x40\x70\x90\xff'*width)*height)) + chunk(b'IEND', b''))

class LocalStorageTests(unittest.TestCase):
    def test_history_expired_authentic_same_device_without_write_receipt(self):
        token = bridge.issue_binding(DEVICE, CARD)
        path = bridge.SESSION_ROOT / (token + '.json')
        document = json.loads(path.read_bytes())
        document['payload']['expires'] = 0
        packed = json.dumps(document['payload'], sort_keys=True, separators=(',', ':')).encode()
        document['signature'] = bridge.hmac.new(bridge.session_key(), packed, bridge.hashlib.sha256).hexdigest()
        path.write_text(json.dumps(document))
        cards = bridge.known_cards(DEVICE['id'])
        self.assertEqual([c['id'] for c in cards], [CARD])
        self.assertEqual(cards[0]['source'], 'history')
        self.assertNotIn('bindingToken', cards[0])
        document['payload']['cardID'] = 'b'*27+'='
        path.write_text(json.dumps(document))
        self.assertEqual(bridge.known_cards(DEVICE['id']), [])

    def test_history_different_device_never_shown(self):
        bridge.issue_binding(dict(DEVICE, id='device-222'), CARD)
        self.assertEqual(bridge.known_cards(DEVICE['id']), [])

    def test_public_apply_security_block_before_device_access(self):
        with patch.object(bridge, 'require_device', side_effect=AssertionError('device contacted')):
            with self.assertRaisesRegex(RuntimeError, 'experimental_risk_acceptance_required'):
                bridge.apply(dict(confirmed=True))
    def test_experimental_acceptance_must_be_boolean_and_precedes_device_access(self):
        with patch.object(bridge, 'require_device', side_effect=AssertionError('device contacted')):
            for value in [False, 'true', 1, None]:
                with self.assertRaisesRegex(RuntimeError, 'experimental_risk_acceptance_required'):
                    bridge.apply(dict(confirmed=True, experimentalRiskAccepted=value))

    def test_accepted_public_apply_enters_serialized_pipeline_only(self):
        with patch.object(bridge, '_apply_locked', return_value={'transportCompleted': True}) as pipeline:
            request = dict(confirmed=True, experimentalRiskAccepted=True)
            self.assertTrue(bridge.apply(request)['transportCompleted'])
            pipeline.assert_called_once_with(request)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.stack = contextlib.ExitStack()
        self.stack.enter_context(patch.object(Path, 'home', return_value=self.root))
        support = self.root / 'Library/Application Support/WalletSkin Studio'
        for name, path in [('SUPPORT', support), ('SESSION_ROOT', support/'Sessions'), ('ARTWORK_ROOT', support/'Artwork'), ('RECOVERY_ROOT', support/'Recovery')]:
            self.stack.enter_context(patch.object(bridge, name, path))
        bridge.secure_directory(bridge.RECOVERY_ROOT)
        self.stack.enter_context(patch.object(upstream, 'RECOVERY_ROOT', bridge.RECOVERY_ROOT))
        self.stack.enter_context(patch.object(bridge, 'require_device', return_value=DEVICE))
        self.stack.enter_context(patch.object(bridge, 'progress'))
        self.old_umask = os.umask(0o077)
    def tearDown(self):
        os.umask(self.old_umask)
        self.stack.close()
        self.temp.cleanup()
    def artwork(self, data=None):
        bridge.secure_directory(bridge.ARTWORK_ROOT)
        path = bridge.ARTWORK_ROOT/'prepared.png'
        path.write_bytes(png() if data is None else data)
        path.chmod(0o600)
        return path
    def request(self):
        return dict(command='apply', confirmed=True, deviceID=DEVICE['id'], cardID=CARD,
                    bindingToken=bridge.issue_binding(DEVICE, CARD), imagePath=str(self.artwork()))
    def test_receipt_exact_device_card_and_expiry(self):
        token = bridge.issue_binding(DEVICE, CARD)
        bridge.validate_binding(token, DEVICE, CARD)
        with self.assertRaisesRegex(RuntimeError, 'mismatch'):
            bridge.validate_binding(token, dict(DEVICE, id='device-222'), CARD)
        with self.assertRaisesRegex(RuntimeError, 'mismatch'):
            bridge.validate_binding(token, DEVICE, 'b'*27+'=')
        with patch.object(bridge.time, 'time', return_value=10**12):
            with self.assertRaisesRegex(RuntimeError, 'expired'):
                bridge.validate_binding(token, DEVICE, CARD)
        self.assertEqual((bridge.SESSION_ROOT/(token+'.json')).stat().st_mode & 0o777, 0o600)
        self.assertEqual(bridge.SESSION_ROOT.stat().st_mode & 0o777, 0o700)
    def test_receipt_tampering_rejected(self):
        token = bridge.issue_binding(DEVICE, CARD)
        path = bridge.SESSION_ROOT/(token+'.json')
        doc = json.loads(path.read_text()); doc['payload']['cardID'] = 'b'*27+'='
        path.write_text(json.dumps(doc))
        with self.assertRaisesRegex(RuntimeError, 'invalid_card_binding'):
            bridge.validate_binding(token, DEVICE, 'b'*27+'=')
    def test_png_valid_invalid_corrupt_and_symlink(self):
        self.assertEqual(bridge.prepared_png(str(self.artwork())), png())
        for data in [b'junk', png(1535, 969), png()[:-1], png() + b'extra']:
            with self.assertRaises(RuntimeError):
                bridge.prepared_png(str(self.artwork(data)))
        valid = self.artwork(); link = valid.parent/'link.png'; link.symlink_to(valid)
        with self.assertRaisesRegex(RuntimeError, 'untrusted'):
            bridge.prepared_png(str(link))
        valid.chmod(0o644)
        with self.assertRaisesRegex(RuntimeError, 'unsafe'):
            bridge.prepared_png(str(valid))
    def test_no_confirm_no_writer(self):
        with patch.object(upstream, 'write_files_batch') as write:
            with self.assertRaisesRegex(RuntimeError, 'confirmation'):
                bridge._apply_locked(dict(self.request(), confirmed=False))
            write.assert_not_called()
    def test_success_exact_three_assets_transport_not_visual_success(self):
        request = self.request()
        assets = [('cardBackgroundCombined@3x.png', b'png'), ('cardBackgroundCombined@2x.png', b'png'), ('cardBackgroundCombined.pdf', b'%PDF-1.4')]
        with patch.object(upstream, 'build_card_assets', return_value=assets), patch.object(upstream, 'write_files_batch', return_value=True) as write, patch.object(upstream, 'invalidate_cache', return_value=True) as cache:
            response = bridge._apply_locked(request)
            self.assertTrue(response['transportCompleted'])
            self.assertFalse(response['walletAppearanceVerified'])
            self.assertEqual(write.call_args.args, (DEVICE['id'], '/var/mobile/Library/Passes/Cards/'+CARD+'.pkpass', assets))
            self.assertEqual(write.call_args.kwargs, dict(retries=1))
            cache.assert_called_once_with(DEVICE['id'], CARD)
            with self.assertRaisesRegex(RuntimeError, 'invalid_card_binding'):
                bridge._apply_locked(request)
    def test_write_failure_never_runs_cache_or_replays(self):
        with patch.object(upstream, 'build_card_assets', return_value=[]), patch.object(upstream, 'write_files_batch', return_value=False) as write, patch.object(upstream, 'invalidate_cache') as cache:
            with self.assertRaisesRegex(RuntimeError, 'write_incomplete'):
                bridge._apply_locked(self.request())
            write.assert_called_once(); cache.assert_not_called()
    def test_cache_failure_reports_possible_partial(self):
        with patch.object(upstream, 'build_card_assets', return_value=[]), patch.object(upstream, 'write_files_batch', return_value=True), patch.object(upstream, 'invalidate_cache', return_value=False):
            with self.assertRaisesRegex(RuntimeError, 'cache_refresh_incomplete'):
                bridge._apply_locked(self.request())
    def test_unknown_writer_stage_outcome_preserves_without_cleanup(self):
        calls = []
        def native(command, *args):
            calls.append(command)
            if command == 'stage': raise RuntimeError('sensitive diagnostic PAN secret')
            return OK
        with patch.object(upstream, 'native', side_effect=native), patch.object(upstream, 'run_json') as host:
            self.assertFalse(upstream.write_files_batch(DEVICE['id'], '/var/mobile/Library/Passes/Cards/'+CARD+'.pkpass', [('cardBackgroundCombined.pdf', b'pdf')]))
            self.assertEqual(calls, ['snapshot-books', 'stage'])
            host.assert_not_called()
            self.assertTrue(bridge.pending_recovery(DEVICE['id']))
    def call_primitive(self, cache=False):
        target = '/var/mobile/Library/Passes/Cards/'+CARD
        if cache:
            return upstream.remove_files_batch(DEVICE['id'], target+'.cache', ['FrontFace', 'PlaceHolder', 'Preview'])
        return upstream.write_files_batch(DEVICE['id'], target+'.pkpass', [('cardBackgroundCombined.pdf', b'pdf')])
    def explicit_stage_rejection(self, cache):
        calls = []
        def native(command, *args):
            calls.append(command)
            if command == 'stage':
                return dict(exitCode=2, targetGatePassed=True, operation=dict(ok=False, cleanupAuthorized=False))
            return OK
        with patch.object(upstream, 'native', side_effect=native), patch.object(upstream, 'run_json') as host:
            self.assertFalse(self.call_primitive(cache))
            self.assertEqual(calls, ['snapshot-books', 'stage'])
            host.assert_not_called()
            self.assertFalse(bridge.pending_recovery(DEVICE['id']))
    def test_writer_explicit_no_cleanup_authorization_never_restores_books(self):
        self.explicit_stage_rejection(False)
    def test_cache_explicit_no_cleanup_authorization_never_restores_books(self):
        self.explicit_stage_rejection(True)
    def test_unknown_cache_stage_outcome_preserves_without_cleanup(self):
        calls = []
        def native(command, *args):
            calls.append(command)
            if command == 'stage': raise TimeoutError('unknown partial outcome')
            return OK
        with patch.object(upstream, 'native', side_effect=native), patch.object(upstream, 'run_json') as host:
            self.assertFalse(self.call_primitive(True))
            self.assertEqual(calls, ['snapshot-books', 'stage'])
            host.assert_not_called()
        self.assertTrue(bridge.pending_recovery(DEVICE['id']))
    def test_authorized_failed_stage_cleanup_writer_and_cache(self):
        for cache in (False, True):
            with self.subTest(cache=cache):
                calls = []
                def native(command, *args):
                    calls.append(command)
                    if command == 'stage':
                        return dict(exitCode=2, targetGatePassed=True, operation=dict(ok=False, cleanupAuthorized=True))
                    return OK
                with patch.object(upstream, 'native', side_effect=native), patch.object(upstream, 'run_json') as host:
                    self.assertFalse(self.call_primitive(cache))
                    self.assertEqual(calls, ['snapshot-books', 'stage', 'finish-write'])
                    host.assert_not_called()
                self.assertFalse(bridge.pending_recovery(DEVICE['id']))
    def test_interrupted_host_preserves_recovery_if_cleanup_fails(self):
        calls = []
        def native(command, *args):
            calls.append(command)
            if command == 'snapshot-books':
                (Path(args[-1])/'original-books.bin').write_bytes(b'original')
            return FAILED if command == 'finish-write' else OK
        with patch.object(upstream, 'native', side_effect=native), patch.object(upstream, 'run_json', side_effect=TimeoutError('private diagnostic')):
            self.assertFalse(upstream.write_files_batch(DEVICE['id'], '/var/mobile/Library/Passes/Cards/'+CARD+'.pkpass', [('cardBackgroundCombined.pdf', b'pdf')]))
        self.assertEqual(calls, ['snapshot-books', 'stage', 'finish-write'])
        self.assertTrue(bridge.pending_recovery(DEVICE['id']))
        folder = next(bridge.RECOVERY_ROOT.iterdir())
        journal = json.loads((folder/'pending.json').read_text())
        self.assertEqual(journal['deviceID'], DEVICE['id'])
        self.assertEqual(journal['source'].replace('airlift-src-', ''), journal['linkDestination'].replace('airlift-link-', ''))
        self.assertTrue((folder/'books-snapshot/original-books.bin').is_file())
        self.assertEqual(folder.stat().st_mode&0o777, 0o700)
        with patch.object(upstream, 'write_files_batch') as write:
            with self.assertRaisesRegex(RuntimeError, 'pending_recovery'):
                bridge._apply_locked(self.request())
            write.assert_not_called()
    def test_cache_failure_stops_next_target(self):
        with patch.object(upstream, 'remove_files_batch', return_value=False) as remove:
            self.assertFalse(upstream.invalidate_cache(DEVICE['id'], CARD))
            remove.assert_called_once()
    def test_arbitrary_card_or_path_never_writer(self):
        request = self.request()
        with patch.object(upstream, 'write_files_batch') as write:
            with self.assertRaisesRegex(RuntimeError, 'invalid_card_binding'):
                bridge._apply_locked(dict(request, cardID='../credential'))
            with self.assertRaisesRegex(RuntimeError, 'untrusted'):
                bridge._apply_locked(dict(request, imagePath='/etc/passwd'))
            write.assert_not_called()

if __name__ == '__main__': unittest.main()
