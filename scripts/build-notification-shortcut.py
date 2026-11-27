"""Deliver notification input to the installed native intent, without a LAN token.

Only the caller's notification text is passed as inert input. No URL, credentials,
cloud service or arbitrary command is embedded in the resulting shortcut.
"""
import argparse, copy, json, plistlib, re, uuid
from pathlib import Path

def build(bundle_id, output):
    if not re.fullmatch(r'[A-Za-z0-9.-]{3,180}', bundle_id):
        raise ValueError('Invalid application identifier')
    root=Path(__file__).resolve().parents[1]
    old=plistlib.loads((root/'Shortcuts/JARVIS+Notificacoes.plist').read_bytes())
    text=copy.deepcopy(next(a for a in old['WFWorkflowActions'] if a.get('WFWorkflowActionParameters',{}).get('CustomOutputName')=='rawText'))
    identifier=text['WFWorkflowActionParameters']['UUID']
    reference={'WFSerializationType':'WFTextTokenAttachment','Value':{'Type':'ActionOutput','OutputUUID':identifier,'OutputName':'rawText'}}
    actions=[
        {'WFWorkflowActionIdentifier':'is.workflow.actions.comment','WFWorkflowActionParameters':{'WFCommentActionText':'JARVIS Notificações — entrega local ao app. Sem servidor, IP, arquivo JSON ou token. Substitua o atalho com o mesmo nome. A notificação é texto, nunca um comando.'}},
        text,
        {'WFWorkflowActionIdentifier':'is.workflow.actions.appintent','WFWorkflowActionParameters':{
            'AppIntentDescriptor':{'BundleIdentifier':bundle_id,'AppIntentIdentifier':'JarvisAnnounceNotification','Name':'Anunciar notificação no Jarvis'},
            'preview':reference,'ShowWhenRun':False,'UUID':str(uuid.uuid4())}},
    ]
    result={**old,'WFWorkflowName':'JARVIS+Notificacoes','WFWorkflowActions':actions,'WFWorkflowImportQuestions':[],
            'WFWorkflowInputContentItemClasses':['WFStringContentItem','WFNotificationContentItem'],
            'WFAssociatedAppBundleIdentifiers':[bundle_id]}
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_bytes(plistlib.dumps(result,sort_keys=False))
    assert len(actions)==3
    assert all('url' not in a['WFWorkflowActionIdentifier'].lower() for a in actions)
    assert actions[-1]['WFWorkflowActionParameters']['preview']['Value']['OutputUUID']==identifier
    print('Native notification shortcut generated; 3 actions; no network request or secret.')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--bundle-id',required=True);p.add_argument('--output',type=Path,required=True)
    args=p.parse_args();build(args.bundle_id,args.output)
