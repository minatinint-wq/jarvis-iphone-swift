"""Extend the existing local shortcut. No keys, server, or arbitrary command execution.

Action identifiers/parameters checked against Cherri actions/device.cherri and
actions_std.go. Apple Shortcuts must sign the resulting plist on macOS.
"""
import copy
import plistlib
from pathlib import Path
import uuid

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'Shortcuts/JARVIS Sistema.base.plist'
EXTRA = [
    ('carteira', 'Abrir Wallet', 'openapp', {'WFSelectedApp': {'BundleIdentifier': 'com.apple.Passbook'}}, 'Carteira aberta. Autorize o pagamento no Wallet.'),
    ('wifi_ligar', 'Ligar Wi-Fi', 'wifi.set', {'OnValue': True}, 'Wi-Fi: ação de ligar concluída pelo Atalhos.'),
    ('wifi_desligar', 'Desligar Wi-Fi', 'wifi.set', {'OnValue': False}, 'Wi-Fi: ação de desligar concluída pelo Atalhos.'),
    ('bluetooth_ligar', 'Ligar Bluetooth', 'bluetooth.set', {'OnValue': True}, 'Bluetooth: ação de ligar concluída pelo Atalhos.'),
    ('bluetooth_desligar', 'Desligar Bluetooth', 'bluetooth.set', {'OnValue': False}, 'Bluetooth: ação de desligar concluída pelo Atalhos.'),
    ('dados_ligar', 'Ligar dados móveis', 'cellulardata.set', {'OnValue': True}, 'Dados móveis: ação de ligar concluída pelo Atalhos.'),
    ('dados_desligar', 'Desligar dados móveis', 'cellulardata.set', {'OnValue': False}, 'Dados móveis: ação de desligar concluída pelo Atalhos.'),
    ('rotacao_bloquear', 'Travar rotação', 'orientationlock.set', {'OnValue': True}, 'Bloqueio de rotação solicitado.'),
    ('rotacao_liberar', 'Liberar rotação', 'orientationlock.set', {'OnValue': False}, 'Liberação de rotação solicitada.'),
    ('economia_desligar', 'Desativar economia', 'lowpowermode.set', {'OnValue': False}, 'Modo Pouca Energia desativado pelo Atalhos.'),
    ('verificar_atalho', 'Testar versão do atalho', None, {}, 'JARVIS_SISTEMA_14'),
]

def action(name, **params):
    return {'WFWorkflowActionIdentifier': 'is.workflow.actions.' + name,
            'WFWorkflowActionParameters': params}

def uid(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, 'jarvis-system-14/' + name))

def build():
    p = plistlib.loads(BASE.read_bytes())
    a = p['WFWorkflowActions']
    command_input = next(x['WFWorkflowActionParameters']['WFInput'] for x in a
                         if x.get('WFWorkflowActionParameters', {}).get('WFConditionalActionString') == 'reuniao')
    # Add recognition alongside the existing allowlist, before the fallback menu.
    at = next(i for i, x in enumerate(a) if x.get('WFWorkflowActionParameters', {}).get('WFConditionalActionString') == 'reuniao')
    blocks = []
    for raw, _, _, _, _ in EXTRA:
        group = uid('recognize/' + raw)
        blocks += [action('conditional', GroupingIdentifier=group, WFCondition=4,
                          WFConditionalActionString=raw, WFControlFlowMode=0, WFInput=copy.deepcopy(command_input)),
                   action('number', WFNumberActionNumber=1, UUID=uid('number/' + raw)),
                   action('setvariable', WFVariableName='recognized', WFInput={
                       'Value': {'OutputName': 'Number', 'OutputUUID': uid('number/' + raw), 'Type': 'ActionOutput'},
                       'WFSerializationType': 'WFTextTokenAttachment'}),
                   action('conditional', GroupingIdentifier=group, WFControlFlowMode=2)]
    a[at:at] = blocks
    menu = next(x['WFWorkflowActionParameters'] for x in a if x['WFWorkflowActionIdentifier'].endswith('.choosefrommenu'))
    group = menu['GroupingIdentifier']
    menu['WFMenuItems'] += [row[1] for row in EXTRA]
    end = next(i for i, x in enumerate(a) if x.get('WFWorkflowActionParameters', {}).get('GroupingIdentifier') == group
               and x['WFWorkflowActionParameters'].get('WFControlFlowMode') == 2)
    branches = []
    for raw, title, _, _, _ in EXTRA:
        branches += [action('choosefrommenu', GroupingIdentifier=group, WFControlFlowMode=1,
                            WFMenuItemTitle=title, WFMenuItemAttributedTitle=title),
                     action('gettext', WFTextActionText=raw, UUID=uid('text/' + raw)),
                     action('setvariable', WFVariableName='command', WFInput={
                         'Value': {'OutputName': 'Text', 'OutputUUID': uid('text/' + raw), 'Type': 'ActionOutput'},
                         'WFSerializationType': 'WFTextTokenAttachment'})]
    a[end:end] = branches
    blocks = []
    for raw, _, identifier, params, result in EXTRA:
        group = uid('execute/' + raw)
        blocks.append(action('conditional', GroupingIdentifier=group, WFCondition=4,
                             WFConditionalActionString=raw, WFControlFlowMode=0, WFInput=copy.deepcopy(command_input)))
        if identifier:
            blocks.append(action(identifier, **params))
        blocks += [action('output', WFOutput=result), action('conditional', GroupingIdentifier=group, WFControlFlowMode=2)]
    a[-1:-1] = blocks
    a[0]['WFWorkflowActionParameters']['WFCommentActionText'] = 'JARVIS Sistema revisão 14. Controles locais. Wallet exige autenticação. Gerado por scripts/build-system-shortcut.py.'
    out = ROOT / 'Shortcuts/JARVIS Sistema.plist'
    out.write_bytes(plistlib.dumps(p, sort_keys=False))
    print(f'{len(a)} ações; {len(EXTRA)} comandos adicionais; plist gerado.')
    return p

if __name__ == '__main__':
    build()
