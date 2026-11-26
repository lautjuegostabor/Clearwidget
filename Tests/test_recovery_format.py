import unittest, json, base64, os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
class TestCapsuleContract(unittest.TestCase):
    def test_authenticated_envelope(self):
        key=bytes(range(32)); nonce=bytes(range(12)); header=b'CLEARRECOVERY1'
        body=json.dumps({'version':1,'request':base64.b64encode(b'{"bundles":[]}').decode(),'files':{}}).encode()
        envelope=header+nonce+AESGCM(key).encrypt(nonce,body,header)
        payload=AESGCM(key).decrypt(envelope[len(header):len(header)+12],envelope[len(header)+12:],header)
        self.assertEqual(json.loads(payload)['version'],1)
        for damaged in [envelope[len(header)+12:-1]+bytes([envelope[-1]^1]), envelope[len(header)+12:]]:
            with self.assertRaises(Exception): AESGCM(bytes(reversed(key))).decrypt(nonce,damaged,header)
        with self.assertRaises(Exception): AESGCM(key).decrypt(nonce,envelope[len(header)+12:-1]+bytes([envelope[-1]^1]),header)
    def test_capsule_source_contract(self):
        from pathlib import Path
        root=Path(__file__).resolve().parents[1]
        swift=(root/'App/ClearRecoveryExport.swift').read_text();rust=(root/'Recovery/clearrecovery.rs').read_text()
        self.assertIn('CLEARRECOVERY1',swift);self.assertIn('CLEARRECOVERY1',rust)
        self.assertIn('AES.GCM.seal',swift);self.assertIn('Aes256Gcm',rust)
        self.assertIn('authenticating: header',swift);self.assertIn('aad:HEADER',rust)
if __name__=='__main__': unittest.main()
