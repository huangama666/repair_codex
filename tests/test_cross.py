import os
import shutil
import sys
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get('CODEX_TEST_PWSH') or shutil.which('pwsh')
WINDOWS = ROOT / 'CodexProxy.ps1'
MAC = ROOT / 'Start-macOS.command'


class Proxy(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(2)
        try:
            request = self.request.recv(4096)
            assert request.startswith(b'CONNECT chatgpt.com:443 HTTP/1.1\r\n')
            self.request.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
        except OSError:
            pass


@unittest.skipUnless(sys.platform == "darwin" and PWSH, "Cross tests require macOS and PowerShell 7 (pwsh)")
class CrossTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.proxy = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Proxy)
        cls.port = cls.proxy.server_address[1]
        threading.Thread(target=cls.proxy.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.proxy.shutdown()
        cls.proxy.server_close()

    def run_case(self, writer, original):
        with tempfile.TemporaryDirectory(prefix='codex-cross-') as folder:
            home = Path(folder).resolve() / '中文 $config'
            if original is not None:
                home.mkdir()
                (home / '.env').write_bytes(original)
            for platform, action in ((writer, 'apply'), ('windows' if writer == 'mac' else 'mac', 'restore')):
                if platform == 'windows':
                    cmd = [str(PWSH), '-NoLogo', '-NoProfile', '-File', str(WINDOWS), '-ConfigHome', str(home), '-Action', action, '-Yes']
                    if action == 'apply':
                        cmd += ['-Port', str(self.port)]
                else:
                    cmd = ['/bin/zsh', str(MAC), '--config-home', str(home), '--' + action, '--yes']
                    if action == 'apply':
                        cmd += ['--port', str(self.port)]
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, platform + ': ' + result.stdout + result.stderr)
            if original is None:
                self.assertFalse((home / '.env').exists())
            else:
                self.assertEqual((home / '.env').read_bytes(), original)

    def test_windows_apply_mac_restore_absence(self):
        self.run_case('windows', None)

    def test_windows_apply_mac_restore_crlf_bom(self):
        self.run_case('windows', b'\xef\xbb\xbfKEEP=1\r\nHTTP_PROXY=old\r\n')

    def test_windows_apply_mac_restore_utf16(self):
        self.run_case('windows', 'KEEP=原文\r\n'.encode('utf-16'))

    def test_mac_apply_windows_restore_absence(self):
        self.run_case('mac', None)

    def test_mac_apply_windows_restore_crlf_bom(self):
        self.run_case('mac', b'\xef\xbb\xbfKEEP=1\r\nHTTP_PROXY=old\r\n')


if __name__ == '__main__':
    unittest.main(verbosity=2)
