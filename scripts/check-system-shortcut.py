"""Reject a stale signature or changes to the signed actions before packaging."""
import hashlib
import json
import plistlib
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'Shortcuts/system-signature.json').read_text())
for name, digest in manifest.items():
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == digest, f'Re-sign changed shortcut: {name}'
signed = (root / 'JarvisPhone/Resources/JARVIS Sistema.shortcut').read_bytes()
assert signed.startswith(b'AEA1'), 'Missing Apple authenticated archive'
if len(sys.argv) > 1:
    actual = plistlib.loads(Path(sys.argv[1]).read_bytes())
    expected = plistlib.loads((root / 'Shortcuts/JARVIS Sistema.plist').read_bytes())
    assert actual['WFWorkflowActions'] == expected['WFWorkflowActions'], 'Signed actions differ from reviewed source'
    for key in ['WFWorkflowInputContentItemClasses', 'WFWorkflowImportQuestions']:
        assert actual.get(key, []) == expected.get(key, []), key
    print('Apple archive decoded; all signed actions match the source.')
else:
    print('Source and signed shortcut hashes match.')
