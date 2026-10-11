import importlib.util
import sys
import tempfile
import io
import zipfile
import struct
import plistlib
import warnings
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'upstream/AirCard'))
from apply_card_skin import build_archive, build_archive_multi, build_books
spec = importlib.util.spec_from_file_location('validator', ROOT/'scripts/validate_stage.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)

class StageScopeTests(unittest.TestCase):
    def run_validation(self, target, identifiers=None, batch=False):
        source = 'airlift-src-' + 'a'*20
        link = 'airlift-link-' + 'a'*20
        with tempfile.TemporaryDirectory() as directory:
            archive, books = Path(directory)/'payload.zip', Path(directory)/'Books.plist'
            archive.write_bytes(build_archive_multi(target, [('cardBackgroundCombined@3x.png', b'png'), ('cardBackgroundCombined@2x.png', b'png'), ('cardBackgroundCombined.pdf', b'pdf')]) if batch else build_archive(target, b'png'))
            ids = identifiers or ([f'../../{source}/p0/p1/p2/link'] + ([f'../../{source}/payload_{i}' for i in range(3)] if batch else [f'../../{source}/payload']))
            books.write_bytes(build_books(ids))
            validator.validate(archive, books, source, link)
    def test_single_wallet_artwork(self):
        self.run_validation('/var/mobile/Library/Passes/Cards/'+'A'*28+'.pkpass')
    def test_batch_wallet_artwork(self):
        self.run_validation('/var/mobile/Library/Passes/Cards/'+'A'*28+'.pkpass', batch=True)
    def test_nonwallet_and_traversal_targets_rejected(self):
        for target in ['/var/mobile/Library/Preferences', '/var/mobile/Library/Passes/Cards/../../Preferences', '/var/mobile/Library/Passes/Cards/short.pkpass']:
            with self.subTest(target=target), self.assertRaises(AssertionError): self.run_validation(target)
    def test_unrelated_books_identifier_rejected(self):
        with self.assertRaises(AssertionError):
            self.run_validation('/var/mobile/Library/Passes/Cards/'+'A'*28+'.pkpass', ['../../unrelated', '../../unrelated/payload'])
    def test_cache_fixed_leaves(self):
        source, link = 'airlift-src-'+'a'*20, 'airlift-link-'+'a'*20
        self.run_validation('/var/mobile/Library/Passes/Cards/'+'A'*28+'.cache', [f'../../{source}/p0/p1/p2/link', f'../../{link}/FrontFace'])
        with self.assertRaises(AssertionError):
            self.run_validation('/var/mobile/Library/Passes/Cards/'+'A'*28+'.cache', [f'../../{source}/p0/p1/p2/link', f'../../{link}/credentials'])
    def test_malformed_archives_rejected(self):
        source, link = 'airlift-src-'+'a'*20, 'airlift-link-'+'a'*20
        original = build_archive('/var/mobile/Library/Passes/Cards/'+'A'*28+'.pkpass', b'png')
        def rewrite(kind):
            output = io.BytesIO()
            with zipfile.ZipFile(io.BytesIO(original)) as old, zipfile.ZipFile(output, 'w') as new:
                for info in old.infolist():
                    data = old.read(info)
                    if kind == 'compression': info.compress_type = zipfile.ZIP_DEFLATED
                    if kind == 'metadata' and info.filename.endswith('ZipMetadata.plist'): data = plistlib.dumps({'Version': 99})
                    if kind == 'mode' and info.filename == 'p0/p1/p2/link': info.external_attr = (0o100600 << 16)
                    if kind == 'extra' and info.filename == 'p0/p1/p2/link': info.extra = b''
                    new.writestr(info, data)
                if kind == 'duplicate':
                    with warnings.catch_warnings():
                        warnings.simplefilter('ignore')
                        new.writestr('payload', b'other')
            return output.getvalue()
        local_mismatch = bytearray(original)
        struct.pack_into('<H', local_mismatch, 8, 8)
        cases = [bytes(local_mismatch)] + [rewrite(k) for k in ('compression','metadata','mode','extra','duplicate')]
        with tempfile.TemporaryDirectory() as directory:
            archive, books = Path(directory)/'payload.zip', Path(directory)/'Books.plist'
            books.write_bytes(build_books([f'../../{source}/p0/p1/p2/link', f'../../{source}/payload']))
            for index, data in enumerate(cases):
                archive.write_bytes(data)
                with self.subTest(case=index), self.assertRaises((AssertionError, zipfile.BadZipFile)):
                    validator.validate(archive, books, source, link)
    def test_huge_input_rejected_without_read(self):
        from unittest.mock import patch
        with patch.object(Path, 'stat') as getstat, patch.object(Path, 'read_bytes') as read:
            getstat.return_value.st_size = 65*1024*1024
            with self.assertRaises(AssertionError):
                validator.validate('oversize.zip', 'Books.plist', 'airlift-src-'+'a'*20, 'airlift-link-'+'a'*20)
            read.assert_not_called()
if __name__ == '__main__': unittest.main()
