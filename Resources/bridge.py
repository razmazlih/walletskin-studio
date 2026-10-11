#!/usr/bin/env python3
"""Local AirCard adapter. Artwork-only targets with confirmed, scanned bindings."""
import fcntl
import hashlib
import hmac
import json
import secrets
import stat
import struct
import zlib
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT))
HELPER = ROOT / 'bin' / 'device_helper'
CARD = re.compile(r'/(?:Cards|Passes/Cards)/([-A-Za-z0-9_+=]{20,44})\.(?:pkpass|cache|pkcache)(?=[/\s\"\'\),]|$)')
# Structured pass references adapted from pinned AirCard WalletDiscovery.swift.
# Keep the writer's narrower ID limit; never use its generic fallback/applet parser.
CARD_REFERENCES = (
    CARD,
    re.compile(r'/(?:Cards|Passes/Cards)/([-A-Za-z0-9_+=]{20,44})(?=[/\s\"\'\),]|$)', re.I),
    re.compile(r'PDCardFileManager:\s*writing card\s+([-A-Za-z0-9_+=]{20,44})(?=[\s\"\'\),]|$)', re.I),
    re.compile(r'PDPassLibrary:\s*wrote pass\s+([-A-Za-z0-9_+=]{20,44})(?=[\s\"\'\),]|$)', re.I),
    re.compile(r'selected pass uniqueID\s*:\s*\"?([-A-Za-z0-9_+=]{20,44})(?=[\s\"\'\),]|$)', re.I),
)
SESSION_LIST = re.compile(r'passIDs\[(?:InSession|global)\]\s*:\s*(?:\{\s*)?\(([^)]*)\)', re.I)
LIST_CARD = re.compile(r'(?<![-A-Za-z0-9_+=])[-A-Za-z0-9_+=]{20,44}(?![-A-Za-z0-9_+=])')
PLACEHOLDERS = frozenset(('OM6NYhwXMZrAw0sRUjR62wmF4ZQ=', 'M6nDwZrkYbFlsodLgCbvyFZQ1cc=',
                          'kJL-D0rr-SZhbj2c8nK-OQ9hCMY=', 'hwAtAmHKYwsQrJbT5cTNDsaxVME='))
WALLET_REFERENCES = (
    re.compile(r'/([-A-Za-z0-9_+=]{20,44})\.(?:pkpass|cache|pkcache)(?=[/\s\"\'\),]|$)'),
    re.compile(r'VerificationCheck\.([-A-Za-z0-9_+=]{20,44})(?=[\s\"\'\),]|$)'),
    re.compile(r'Dashboard loading[^:]*:\s*for\s+([-A-Za-z0-9_+=]{20,44})(?=[,\s\"\'\)]|$)'),
    re.compile(r'Dashboard loading[^:]*:\s+([-A-Za-z0-9_+=]{20,44})\s+-'),
)
SUPPORT = Path.home() / 'Library/Application Support/WalletSkin Studio'
SESSION_ROOT = SUPPORT / 'Sessions'
ARTWORK_ROOT = SUPPORT / 'Artwork'
RECOVERY_ROOT = SUPPORT / 'Recovery'
TOKEN = re.compile(r'[a-f0-9]{64}\Z')
CARD_ID = re.compile(r'[-A-Za-z0-9_+=]{20,44}\Z')
UDID = re.compile(r'[A-Za-z0-9-]{8,80}\Z')

def compatibility(version, product, build=''):
    if not product.startswith('iPhone'):
        return False, 'pairing_required'
    if not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', version):
        return False, 'unknown_version'
    parts = tuple(int(v) for v in version.split('.'))
    parts += (0,) * (3-len(parts))
    if not build or re.search(r'[a-z]$', build):
        return False, 'unknown_or_beta_build'
    if not (18, 0, 0) <= parts <= (27, 0, 1):
        return False, 'unsupported_version'
    return True, 'upstream_claim_not_device_verified'

def devices():
    if not HELPER.is_file():
        raise RuntimeError('helper_missing')
    result = subprocess.run([str(HELPER), 'list'], capture_output=True, timeout=35, check=False)
    if result.returncode:
        raise RuntimeError('device_detection_failed')
    rows = json.loads(result.stdout)
    clean = []
    for row in rows:
        ident = row.get('udid', '')
        if not UDID.fullmatch(ident):
            continue
        product = row.get('product', '')
        version = row.get('version', '')
        eligible, reason = compatibility(version, product, row.get('buildVersion', ''))
        clean.append(dict(id=ident, name=product or 'iPhone', product=product,
                          version=version, eligible=eligible, reason=reason))
    return clean

def require_device(identifier):
    if not isinstance(identifier, str) or not UDID.fullmatch(identifier):
        raise RuntimeError('invalid_device')
    for device in devices():
        if device['id'] == identifier:
            if not device['eligible']:
                raise RuntimeError(device['reason'])
            return device
    raise RuntimeError('device_disconnected')

def parse_card(line):
    cards = parse_cards(line)
    return cards[0] if cards else None

def parse_cards(line):
    # Only explicit pass references. Raw logs, applet identifiers, arbitrary
    # base64 tokens and upstream's placeholder cards are never returned.
    candidates = [(match.start(), match[1]) for regex in CARD_REFERENCES for match in regex.finditer(line)]
    if re.search(r'PassKit|Passbook|passd|PDCard|PDPass|Wallet', line, re.I):
        candidates.extend((match.start(), match[1]) for regex in WALLET_REFERENCES for match in regex.finditer(line))
    for listing in SESSION_LIST.finditer(line):
        candidates.extend((listing.start(1) + match.start(), match[0])
                          for match in LIST_CARD.finditer(listing[1]))
    found = []
    for _, card in sorted(candidates):
        if (card in PLACEHOLDERS or card in found or
                re.fullmatch(r'[A-Fa-f0-9]{10,64}', card) or
                re.fullmatch(r'[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}', card)):
            continue
        found.append(card)
    return found

def known_cards(identifier):
    """Authenticated past discovery, never a fresh receipt or proof of presence."""
    device = require_device(identifier)
    if not SESSION_ROOT.is_dir():
        return []
    secure_directory(SESSION_ROOT)
    key = session_key()
    found = []
    for path in sorted(SESSION_ROOT.glob('*.json')):
        if not TOKEN.fullmatch(path.stem):
            continue
        try:
            document = json.loads(private_read(path, 4096))
            payload = document['payload']
            packed = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
            expected = hmac.new(key, packed, hashlib.sha256).hexdigest()
            card = payload['cardID']
            if (hmac.compare_digest(document['signature'], expected) and
                    payload['deviceID'] == device['id'] and payload['product'] == device['product'] and
                    isinstance(card, str) and CARD_ID.fullmatch(card) and card not in found):
                found.append(card)
        except (OSError, ValueError, KeyError, TypeError, RuntimeError):
            continue
    return [dict(id=card, deviceID=identifier, name=f'כרטיס {i+1}', source='history')
            for i, card in enumerate(found)]

def discover(identifier, duration=45):
    cancelled = False
    proc = None
    buffer = b''

    def cancel_scan(_signal, _frame):
        nonlocal cancelled
        cancelled = True

    def stop_scanner():
        if proc.poll() is None:
            proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        finally:
            proc.stdout.close()

    previous_handler = signal.signal(signal.SIGTERM, cancel_scan)
    try:
        require_device(identifier)
        if cancelled:
            raise RuntimeError('scan_cancelled')
        found = []
        proc = subprocess.Popen([str(HELPER), 'syslog', identifier], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, bufsize=0)
        # The client may safely request cancellation only after this event.
        progress('scanning')
        deadline = time.monotonic() + duration
        while not cancelled and not found and time.monotonic() < deadline:
            ready, _, _ = select.select([proc.stdout], [], [], min(.2, max(0, deadline-time.monotonic())))
            if not ready:
                if proc.poll() is not None:
                    break
                continue
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                break
            buffer += chunk
            while b'\n' in buffer and not cancelled:
                line, buffer = buffer.split(b'\n', 1)
                # Stop at the first matching event, retaining every candidate
                # within that event (a session list is not unique selection).
                found = parse_cards(line.decode('utf-8', errors='replace'))
                if found:
                    break
            if len(buffer) > 262144:
                buffer = b''
        if cancelled:
            raise RuntimeError('scan_cancelled')
        if proc.poll() not in (None, 0):
            raise RuntimeError('scan_failed_unlock_and_trust')
        stop_scanner()
        proc = None
        device = require_device(identifier)
        if cancelled:
            raise RuntimeError('scan_cancelled')
        return [dict(id=card, deviceID=identifier, name=f'כרטיס {i+1}', source='live',
                     bindingToken=issue_binding(device, card)) for i, card in enumerate(found)]
    finally:
        try:
            if proc is not None:
                stop_scanner()
        finally:
            buffer = b''
            signal.signal(signal.SIGTERM, previous_handler)

def secure_directory(path):
    path = Path(path)
    home = Path.home()
    if not path.is_relative_to(home):
        raise RuntimeError('invalid_local_storage')
    current = home
    for part in path.relative_to(home).parts:
        current = current / part
        if current.is_symlink():
            raise RuntimeError('unsafe_local_storage')
        current.mkdir(mode=0o700, exist_ok=True)
        info = current.stat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise RuntimeError('unsafe_local_storage')
    path.chmod(0o700)
    return path

def private_read(path, limit):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > limit or info.st_mode & 0o077:
            raise RuntimeError('unsafe_local_file')
        with os.fdopen(descriptor, 'rb', closefd=False) as stream:
            return stream.read(limit + 1)
    finally:
        os.close(descriptor)

def session_key():
    root = secure_directory(SESSION_ROOT)
    path = root / 'session.key'
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(secrets.token_bytes(32))
    except FileExistsError:
        pass
    key = private_read(path, 32)
    if len(key) != 32:
        raise RuntimeError('invalid_session_key')
    return key

def issue_binding(device, card):
    if not CARD_ID.fullmatch(card):
        raise RuntimeError('invalid_card')
    token = secrets.token_hex(32)
    payload = dict(deviceID=device['id'], cardID=card, version=device['version'],
                   product=device['product'], expires=time.time()+900)
    packed = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
    signature = hmac.new(session_key(), packed, hashlib.sha256).hexdigest()
    path = SESSION_ROOT / (token + '.json')
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(dict(payload=payload, signature=signature), stream)
    return token

def validate_binding(token, device, card):
    if not isinstance(token, str) or not TOKEN.fullmatch(token) or not isinstance(card, str) or not CARD_ID.fullmatch(card):
        raise RuntimeError('invalid_card_binding')
    secure_directory(SESSION_ROOT)
    try:
        document = json.loads(private_read(SESSION_ROOT / (token + '.json'), 4096))
        payload = document['payload']
        packed = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
        expected = hmac.new(session_key(), packed, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(document['signature'], expected):
            raise RuntimeError('invalid_card_binding')
        if payload['expires'] < time.time():
            raise RuntimeError('scan_binding_expired')
        if payload['deviceID'] != device['id'] or payload['cardID'] != card or payload['version'] != device['version'] or payload['product'] != device['product']:
            raise RuntimeError('card_device_mismatch')
    except (OSError, KeyError, ValueError, TypeError):
        raise RuntimeError('invalid_card_binding')

def prepared_png(path):
    if not isinstance(path, str):
        raise RuntimeError('invalid_image')
    root = secure_directory(ARTWORK_ROOT)
    local = Path(path)
    if local.parent != root or local.suffix.lower() != '.png' or local.is_symlink():
        raise RuntimeError('untrusted_image_path')
    data = private_read(local, 32*1024*1024)
    if not data.startswith(b'\x89PNG\r\n\x1a\n'):
        raise RuntimeError('invalid_png')
    offset, header, image, ended = 8, None, bytearray(), False
    while offset < len(data):
        if offset+12 > len(data):
            raise RuntimeError('invalid_png')
        length = struct.unpack('>I', data[offset:offset+4])[0]
        kind = data[offset+4:offset+8]
        end = offset+12+length
        if end > len(data) or length > 32*1024*1024:
            raise RuntimeError('invalid_png')
        contents = data[offset+8:offset+8+length]
        checksum = struct.unpack('>I', data[offset+8+length:end])[0]
        if zlib.crc32(kind+contents) & 0xffffffff != checksum:
            raise RuntimeError('invalid_png')
        if header is None and kind != b'IHDR':
            raise RuntimeError('invalid_png')
        if kind == b'IHDR':
            if header is not None or length != 13:
                raise RuntimeError('invalid_png')
            header = struct.unpack('>IIBBBBB', contents)
            if header[:2] != (1536, 969) or header[2] != 8 or header[3] not in (2, 6) or header[4:] != (0, 0, 0):
                raise RuntimeError('invalid_png_dimensions_or_format')
        elif kind == b'IDAT':
            image.extend(contents)
        elif kind == b'IEND':
            if length != 0 or end != len(data):
                raise RuntimeError('invalid_png')
            ended = True
        elif not kind[0] & 32:
            raise RuntimeError('unsupported_png_chunk')
        offset = end
    if not ended or header is None or not image:
        raise RuntimeError('invalid_png')
    stride = 1536*(4 if header[3] == 6 else 3)+1
    expected = stride*969
    decoder = zlib.decompressobj()
    raw = decoder.decompress(image, expected+1)
    if len(raw) != expected or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail or any(raw[row*stride] > 4 for row in range(969)):
        raise RuntimeError('invalid_png_pixels')
    return data

def pending_recovery(device_id):
    root = secure_directory(RECOVERY_ROOT)
    for entry in root.iterdir():
        if entry.is_symlink():
            raise RuntimeError('unsafe_recovery_directory')
        if entry.is_dir():
            try:
                journal = json.loads(private_read(entry / 'pending.json', 4096))
                if journal.get('deviceID') == device_id:
                    return True
            except (OSError, ValueError):
                # Unknown recovery material must never be silently discarded.
                raise RuntimeError('recovery_state_unreadable')
    return False

def progress(phase):
    print(json.dumps(dict(type='progress', phase=phase)), flush=True)

def _apply_locked(request):
    if request.get('confirmed') is not True:
        raise RuntimeError('explicit_confirmation_required')
    device = require_device(request.get('deviceID'))
    card = request.get('cardID')
    token = request.get('bindingToken')
    validate_binding(token, device, card)
    if pending_recovery(device['id']):
        raise RuntimeError('pending_recovery_blocks_apply')
    payload = prepared_png(request.get('imagePath'))
    device = require_device(device['id'])
    validate_binding(token, device, card)
    import aircard_artwork as upstream
    upstream.RECOVERY_ROOT = secure_directory(RECOVERY_ROOT)
    try:
        assets = upstream.build_card_assets(payload)
    except Exception:
        raise RuntimeError('image_asset_preparation_failed')
    device = require_device(device['id'])
    validate_binding(token, device, card)
    # Consume the receipt before the first modification: failure requires a rescan.
    (SESSION_ROOT / (token + '.json')).unlink()
    progress('writing_artwork')
    try:
        written = upstream.write_files_batch(device['id'],
                    '/var/mobile/Library/Passes/Cards/' + card + '.pkpass',
                    assets, retries=1)
    except Exception:
        written = False
    if not written:
        if pending_recovery(device['id']):
            raise RuntimeError('cleanup_incomplete_recovery_preserved')
        raise RuntimeError('artwork_write_incomplete_rescan')
    progress('refreshing_wallet_cache')
    try:
        cache = upstream.invalidate_cache(device['id'], card)
    except Exception:
        cache = False
    if not cache:
        if pending_recovery(device['id']):
            raise RuntimeError('cleanup_incomplete_recovery_preserved')
        raise RuntimeError('artwork_written_cache_refresh_incomplete')
    progress('awaiting_wallet_verification')
    return dict(transportCompleted=True, walletAppearanceVerified=False,
                message='Open Wallet and verify the exact selected card; no original artwork backup exists.')

def apply(request):
    if request.get('confirmed') is not True:
        raise RuntimeError('explicit_confirmation_required')
    if request.get('experimentalRiskAccepted') is not True:
        raise RuntimeError('experimental_risk_acceptance_required')
    root = secure_directory(SESSION_ROOT)
    descriptor = os.open(root / 'operation.lock', os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('another_apply_in_progress')
        return _apply_locked(request)
    finally:
        os.close(descriptor)

def handle(request):
    command = request.get('command')
    if command == 'devices':
        return dict(devices=devices())
    if command == 'discover':
        return dict(cards=discover(request.get('deviceID')))
    if command == 'known_cards':
        return dict(cards=known_cards(request.get('deviceID')))
    if command == 'apply':
        return apply(request)
    if command in ('restore', 'backup', 'probe'):
        raise RuntimeError('operation_disabled_no_safe_original_backup')
    raise RuntimeError('invalid_command')

def main():
    os.umask(0o077)
    try:
        request = json.loads(sys.stdin.buffer.read(65537))
        response = handle(request)
        response['ok'] = True
    except RuntimeError as error:
        response = dict(ok=False, error=str(error))
    except Exception:
        response = dict(ok=False, error='local_operation_failed')
    print(json.dumps(response, ensure_ascii=False))

if __name__ == '__main__':
    main()
