import hashlib
import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import sys
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'Start-macOS.command'


class Proxy(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(2)
        try:
            data = self.request.recv(2048)
            if data.startswith(b'CONNECT chatgpt.com:443 HTTP/1.1\r\n'):
                self.request.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
            else:
                self.request.sendall(b'HTTP/1.1 400 Bad Request\r\n\r\n')
        except (TimeoutError, OSError):
            pass


class NonProxy(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            self.request.recv(2048)
            self.request.sendall(b'HTTP/1.1 403 Forbidden\r\n\r\n')
        except OSError:
            pass


@unittest.skipUnless(sys.platform == "darwin", "macOS shell tests require macOS")
class MacTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.proxy = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Proxy)
        cls.other = socketserver.ThreadingTCPServer(('127.0.0.1', 0), NonProxy)
        cls.port = cls.proxy.server_address[1]
        cls.other_port = cls.other.server_address[1]
        for server in (cls.proxy, cls.other):
            threading.Thread(target=server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        for server in (cls.proxy, cls.other):
            server.shutdown()
            server.server_close()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='codex-proxy-test-')
        self.home = Path(self.temp.name) / '中文 config $dollar'

    def tearDown(self):
        self.temp.cleanup()

    def run_tool(self, *args, input=None):
        return subprocess.run(
            ['/bin/zsh', str(SCRIPT), '--config-home', str(self.home), *args],
            input=input, text=True, capture_output=True, timeout=15,
            env=os.environ.copy(),
        )

    def apply(self):
        r = self.run_tool('--apply', '--port', str(self.port), '--yes')
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        return r

    def manifests(self):
        return sorted((self.home / 'proxy-helper-backups').glob('*/manifest.json'))

    def test_preview_does_not_create_config_directory(self):
        r = self.run_tool('--preview', '--port', str(self.port))
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertIn(f'HTTP_PROXY=http://127.0.0.1:{self.port}', r.stdout)
        self.assertFalse(self.home.exists())

    def test_create_then_restore_original_absence(self):
        self.apply()
        env = self.home / '.env'
        self.assertTrue(env.is_file())
        self.assertEqual(env.stat().st_mode & 0o777, 0o600)
        manifests = self.manifests()
        self.assertEqual(len(manifests), 1)
        manifest = json.loads(manifests[0].read_text())
        self.assertFalse(manifest['existed'])
        self.assertEqual(manifest['after_sha256'], hashlib.sha256(env.read_bytes()).hexdigest())
        r = self.run_tool('--restore', '--yes')
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertFalse(env.exists())
        self.assertIn('restored_at', json.loads(manifests[0].read_text()))

    def test_preserves_unknown_values_bom_crlf_and_restores_exact_bytes(self):
        self.home.mkdir()
        original = (b'\xef\xbb\xbf# keep comment\r\nAPI_KEY=hidden-value\r\n'
                    b'http_proxy=http://old:1\r\nexport HTTPS_PROXY="http://old:2"\r\n'
                    b'NO_PROXY=old\r\nOTHER=no-final-newline')
        env = self.home / '.env'
        env.write_bytes(original)
        env.chmod(0o640)
        self.apply()
        new = env.read_bytes()
        self.assertTrue(new.startswith(b'\xef\xbb\xbf'))
        self.assertIn(b'API_KEY=hidden-value\r\n', new)
        self.assertIn(b'OTHER=no-final-newline\r\n', new)
        self.assertNotIn(b'http://old', new)
        self.assertEqual(new.lower().count(b'http_proxy='), 1)
        self.assertNotIn(b'\n', new.replace(b'\r\n', b''))
        self.assertNotIn('hidden-value', self.run_tool('--preview', '--port', str(self.port)).stdout)
        self.assertEqual((self.manifests()[0].parent / 'original.env').read_bytes(), original)
        r = self.run_tool('--restore', '--yes')
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertEqual(env.read_bytes(), original)
        self.assertEqual(env.stat().st_mode & 0o777, 0o640)

    def test_repeated_apply_does_not_create_extra_backups(self):
        self.apply()
        before = (self.home / '.env').read_bytes()
        self.apply()
        self.assertEqual((self.home / '.env').read_bytes(), before)
        self.assertEqual(len(self.manifests()), 1)

    def test_external_edit_blocks_restore(self):
        self.apply()
        env = self.home / '.env'
        changed = env.read_bytes() + b'USER_ADDED=value\n'
        env.write_bytes(changed)
        r = self.run_tool('--restore', '--yes')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(env.read_bytes(), changed)

    def test_unusable_proxy_does_not_create_or_modify_files(self):
        r = self.run_tool('--apply', '--port', str(self.other_port), '--yes')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(self.home.exists())

    def test_cancel_keeps_original_and_creates_no_backups(self):
        self.home.mkdir()
        env = self.home / '.env'
        env.write_bytes(b'KEEP=1\n')
        r = self.run_tool('--apply', '--port', str(self.port), input='no\n')
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertEqual(env.read_bytes(), b'KEEP=1\n')
        self.assertEqual(self.manifests(), [])

    def test_symlink_env_is_rejected_without_touching_target(self):
        self.home.mkdir()
        target = Path(self.temp.name) / 'outside.env'
        target.write_bytes(b'OUTSIDE=1\n')
        (self.home / '.env').symlink_to(target)
        r = self.run_tool('--apply', '--port', str(self.port), '--yes')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(target.read_bytes(), b'OUTSIDE=1\n')

    def test_uncommitted_record_does_not_block_earlier_valid_restore(self):
        self.apply()
        env = self.home / '.env'
        current = env.read_bytes()
        failed = self.home / 'proxy-helper-backups' / '29991231T235959999-abcdef'
        failed.mkdir()
        (failed / 'original.env').write_bytes(current)
        (failed / 'manifest.json').write_text(json.dumps({
            'schema': 1, 'state': 'pending', 'existed': True,
            'before_sha256': hashlib.sha256(current).hexdigest(),
            'after_sha256': '0' * 64, 'created_at': '2999-12-31T23:59:59Z',
        }))
        r = self.run_tool('--restore', '--yes')
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertFalse(env.exists())

    def test_proxy_like_text_inside_multiline_value_is_preserved(self):
        self.home.mkdir()
        original = b'TOKEN="first\nHTTP_PROXY=literal\nlast"\nHTTPS_PROXY="old\ncontinued"\nKEEP=1\n'
        env = self.home / '.env'
        env.write_bytes(original)
        self.apply()
        result = env.read_bytes()
        self.assertIn(b'TOKEN="first\nHTTP_PROXY=literal\nlast"\n', result)
        self.assertNotIn(b'continued', result)
        self.assertIn(b'KEEP=1\n', result)

    def test_interrupted_restore_can_finish_bookkeeping(self):
        self.apply()
        manifest = self.manifests()[0]
        (manifest.parent / 'manifest.before-restore.json').write_bytes(manifest.read_bytes())
        (self.home / '.env').unlink()
        r = self.run_tool('--restore', '--yes')
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertFalse((self.home / '.env').exists())
        self.assertIn('restored_at', json.loads(manifest.read_text()))

    def test_cr_only_newlines_preserve_other_values(self):
        self.home.mkdir()
        env = self.home / '.env'
        original = b'HTTP_PROXY=old\rKEEP=1\r'
        env.write_bytes(original)
        self.apply()
        result = env.read_bytes()
        self.assertIn(b'KEEP=1\r', result)
        self.assertNotIn(b'\n', result)

    def test_restore_binary_original_from_compatible_backup(self):
        self.home.mkdir()
        original = 'KEEP=原文\r\n'.encode('utf-16')
        after = 'HTTP_PROXY=http://127.0.0.1:7897\r\n'.encode('utf-16')
        (self.home / '.env').write_bytes(after)
        record = self.home / 'proxy-helper-backups' / '20261016T012000000-12345678'
        record.mkdir(parents=True)
        (record / 'original.env').write_bytes(original)
        (record / 'manifest.json').write_text(json.dumps({
            'schema': 1, 'state': 'applied', 'existed': True,
            'before_sha256': hashlib.sha256(original).hexdigest(),
            'after_sha256': hashlib.sha256(after).hexdigest(),
            'created_at': '2026-10-16T01:20:00Z',
        }))
        r = self.run_tool('--restore', '--yes')
        self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        self.assertEqual((self.home / '.env').read_bytes(), original)


if __name__ == '__main__':
    unittest.main(verbosity=2)
