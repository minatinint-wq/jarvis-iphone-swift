import hashlib,json,plistlib,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
for name,digest in json.loads((root/'Shortcuts/notification-pc-signature.json').read_text()).items():
    assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest,name
expected=plistlib.loads((root/'Shortcuts/JARVIS+Notificacoes-PC.plist').read_bytes())
actions=expected['WFWorkflowActions']
assert not any('appintent' in a['WFWorkflowActionIdentifier'] for a in actions)
server=next(a['WFWorkflowActionParameters']['WFTextActionText'] for a in actions if a.get('WFWorkflowActionParameters',{}).get('CustomOutputName')=='serverURL')
assert server=='http://192.168.15.3:9887'
assert expected['WFWorkflowImportQuestions'][0]['ParameterKey']=='WFFile'
assert actions[-1]['WFWorkflowActionIdentifier']=='is.workflow.actions.downloadurl'
assert actions[-1]['WFWorkflowActionParameters']['WFHTTPMethod']=='POST'
if len(sys.argv)>1:
    actual=plistlib.loads(Path(sys.argv[1]).read_bytes())
    assert actual['WFWorkflowActions']==actions,'Signed actions differ'
    assert actual['WFWorkflowImportQuestions']==expected['WFWorkflowImportQuestions'],'Connection file setup question differs'
    assert actual.get('WFWorkflowName') in (None,'JARVIS+Notificacoes')
    print('Apple signature and exact PC delivery actions verified; import selects the existing private connection JSON.')
else:print('PC shortcut hashes, receiver destination, POST and setup question verified. No credential embedded.')
