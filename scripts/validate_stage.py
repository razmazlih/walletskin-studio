#!/usr/bin/env python3
"""Fail-closed preflight for the unchanged AirCard archive; never contacts a device."""
import sys, re, zipfile, stat, plistlib, struct
from pathlib import Path

def validate(archive_path, books_path, source, link):
    assert re.fullmatch(r'airlift-src-[0-9a-f]{20}', source)
    assert link == source.replace('airlift-src-', 'airlift-link-', 1)
    assert Path(archive_path).stat().st_size <= 64 * 1024 * 1024
    assert Path(books_path).stat().st_size <= 16384
    with open(archive_path, 'rb') as stream:
        raw = stream.read(64 * 1024 * 1024 + 1)
    assert len(raw) <= 64 * 1024 * 1024
    with zipfile.ZipFile(archive_path) as z:
        infos = z.infolist()
        assert 7 <= len(infos) <= 24
        assert len({i.filename for i in infos}) == len(infos)
        assert all(i.file_size <= 24 * 1024 * 1024 and i.compress_type == zipfile.ZIP_STORED for i in infos)
        assert z.getinfo('p0/p1/p2/link').file_size < 256
        target = z.read('p0/p1/p2/link').decode('ascii')
        match = re.fullmatch(r'\.\./\.\./\.\./var/mobile/Library/Passes/Cards/([-A-Za-z0-9_+=]{20,44})\.(pkpass|cache|pkcache)', target)
        assert match
        tail = target[9:]
        dirs = {'META-INF/', 'p0/', 'p0/p1/', 'p0/p1/p2/'}
        cursor = ''
        for piece in tail.split('/'):
            cursor += piece + '/'
            dirs.add(cursor)
        payloads = {i.filename for i in infos if re.fullmatch(r'payload(?:_[0-2])?', i.filename)}
        assert payloads and 'payload' in payloads
        assert {i.filename for i in infos} == dirs | payloads | {'p0/p1/p2/link', 'META-INF/com.apple.ZipMetadata.plist'}
        offset = 0
        for i in infos:
            assert i.header_offset == offset and i.compress_type == zipfile.ZIP_STORED and i.flag_bits == 0
            assert i.file_size <= 24 * 1024 * 1024
            mode = (i.external_attr >> 16) & 0xffff
            expected = (stat.S_IFDIR | 0o755) if i.filename in dirs else ((stat.S_IFLNK | 0o777) if i.filename == 'p0/p1/p2/link' else (stat.S_IFREG | 0o600))
            assert mode == expected and i.extra == struct.pack('<HHH', 0x5A53, 2, expected)
            assert raw[offset:offset+4] == b'PK\x03\x04'
            flags, method = struct.unpack_from('<HH', raw, offset+6)
            crc, compressed, uncompressed = struct.unpack_from('<III', raw, offset+14)
            assert flags == 0 and method == 0 and crc == i.CRC and compressed == uncompressed == i.file_size
            name_len, extra_len = struct.unpack_from('<HH', raw, offset+26)
            assert raw[offset+30:offset+30+name_len] == i.filename.encode()
            assert raw[offset+30+name_len:offset+30+name_len+extra_len] == i.extra
            data = z.read(i)
            if i.filename in dirs: assert data == b''
            if i.filename == 'META-INF/com.apple.ZipMetadata.plist': assert plistlib.loads(data) == {'Version': 2}
            offset += 30 + name_len + extra_len + i.file_size
        assert raw[offset:offset+4] == b'PK\x01\x02'
    book = plistlib.loads(Path(books_path).read_bytes())
    rows = book['Books']
    identifiers = [r['Persistent ID'] for r in rows]
    assert identifiers[0] == f'../../{source}/p0/p1/p2/link'
    if match[2] == 'pkpass':
        assert 2 <= len(identifiers) <= 4
        assert all(x in {f'../../{source}/{p}' for p in payloads} for x in identifiers[1:])
    else:
        assert 2 <= len(identifiers) <= 4
        assert all(x in {f'../../{link}/{p}' for p in ('FrontFace','PlaceHolder','Preview')} for x in identifiers[1:])
    assert len(identifiers) == len(set(identifiers))

if __name__ == '__main__':
    try:
        validate(*sys.argv[1:])
    except Exception:
        sys.exit(1)
