"""Register native sources and every new, hash-verified model resource."""
from pathlib import Path
import hashlib, json, re

root=Path(__file__).resolve().parents[1]
project=root/'JarvisPhone.xcodeproj/project.pbxproj'
text=project.read_text(encoding='utf-8')
sources=['JarvisPhone/Views/SpatialRig.swift','JarvisPhone/Views/WallImpact.swift']
manifest=json.loads((root/'JarvisPhone/Resources/SPATIAL_ASSETS.json').read_text())
resources=sorted({'JarvisPhone/Resources/'+f['file'] for a in manifest if a['id'].startswith('animated_') for f in a['files']})
main=re.search(r'mainGroup = ([A-F0-9]{24})',text)[1]
for path in sources+resources:
    if 'path = "'+path+'"' in text: continue
    ref=hashlib.sha256(('ref:'+path).encode()).hexdigest()[:24].upper()
    build=hashlib.sha256(('build:'+path).encode()).hexdigest()[:24].upper()
    kind='sourcecode.swift' if path.endswith('.swift') else 'file'
    entries=f'{ref} = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = "{path}"; sourceTree = "<group>"; }};\n{build} = {{isa = PBXBuildFile; fileRef = {ref}; }};\n'
    text=text.replace('objects = {','objects = {\n'+entries,1)
    text,n=re.subn(r'('+main+r' = \{isa = PBXGroup; children = \()',r'\g<1>'+ref+', ',text,count=1)
    assert n==1,('main',path)
    phase='AFF87A50730392B6633ACECE' if path in sources else 'F9187E824FE171A6F0EFAE28'
    text,n=re.subn(r'('+phase+r' = \{isa = PBX(?:Sources|Resources)BuildPhase;[^\n]*?files = \()',r'\g<1>'+build+', ',text,count=1)
    assert n==1,('phase',path)
text=text.replace('CURRENT_PROJECT_VERSION = 25','CURRENT_PROJECT_VERSION = 26')
project.write_text(text,encoding='utf-8')
xtool=root/'xtool.yml';text=xtool.read_text(encoding='utf-8')
for path in resources:
    if '- '+path not in text: text+='\n- '+path
xtool.write_text(text+'\n',encoding='utf-8')
plist=root/'Support/Phone.plist';text=plist.read_text(encoding='utf-8')
text,n=re.subn(r'(<key>CFBundleVersion</key>\s*<string>)25(</string>)',r'\g<1>26\2',text)
assert n==1 or '<string>26</string>' in text
plist.write_text(text,encoding='utf-8')
tests=root/'JarvisPhoneTests/PhoneCommandTests.swift';text=tests.read_text(encoding='utf-8')
text=text.replace('!$0.id.hasPrefix("demo_")','!$0.id.hasPrefix("demo_") && !$0.id.hasPrefix("animated_")')
text=text.replace('.model("demo_human"))','.model("animated_robot"))')
tests.write_text(text,encoding='utf-8')
for asset in manifest:
    for file in asset['files']:
        assert hashlib.sha256((root/'JarvisPhone/Resources'/file['file']).read_bytes()).hexdigest()==file['sha256'],file['file']
print(json.dumps({'registered_sources':len(sources),'registered_resources':len(resources),'verified_assets':len(manifest)}))
