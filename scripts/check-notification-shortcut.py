import hashlib,json,plistlib,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
for name,digest in json.loads((root/'Shortcuts/notification-native-signature.json').read_text()).items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest,name
expected=plistlib.loads((root/'Shortcuts/JARVIS+Notificacoes-Nativo.plist').read_bytes())
actions=expected['WFWorkflowActions']
assert expected['WFWorkflowName']=='JARVIS+Notificacoes'
assert len(actions)==3
assert actions[-1]['WFWorkflowActionIdentifier']=='is.workflow.actions.appintent'
assert actions[-1]['WFWorkflowActionParameters']['AppIntentDescriptor']['AppIntentIdentifier']=='JarvisAnnounceNotification'
assert all('url' not in a['WFWorkflowActionIdentifier'].lower() for a in actions)
if len(sys.argv)>1:
    actual=plistlib.loads(Path(sys.argv[1]).read_bytes())
    if actual!=expected:
        changed=[k for k in set(actual)|set(expected) if actual.get(k)!=expected.get(k)]
        print('Signed normalization keys:',changed)
        for k in changed:
            if k!='WFWorkflowActions':print(k,repr(expected.get(k))[:240],'->',repr(actual.get(k))[:240])
        assert actual['WFWorkflowActions']==expected['WFWorkflowActions'],'Signed actions differ'
        for k in ['WFWorkflowName','WFWorkflowInputContentItemClasses','WFWorkflowImportQuestions','WFAssociatedAppBundleIdentifiers']:
            assert actual.get(k)==expected.get(k),k

    print('Apple signature verified; signed workflow exactly matches the reviewed native actions.')
else:
    print('Reviewed shortcut hashes verified; no network actions or embedded token.')
