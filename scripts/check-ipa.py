import sys, zipfile, plistlib, struct, json, hashlib
from pathlib import Path
with zipfile.ZipFile(sys.argv[1]) as z:
 p=next(n for n in z.namelist() if n.startswith("Payload/") and n.endswith(".app/Info.plist") and n.count("/")==2)
 info=plistlib.loads(z.read(p)); root=p.rsplit("/",1)[0]+"/"; binary=z.read(root+info["CFBundleExecutable"])
 assert binary[:4]==bytes.fromhex("cffaedfe") and struct.unpack_from("<I",binary,4)[0]==0x0100000c, "esperado Mach-O arm64"
 assert info["CFBundleIdentifier"]=="com.jarvisxlv.iphone"
 assert all(info.get(key) for key in ["NSCameraUsageDescription","NSMicrophoneUsageDescription","NSSpeechRecognitionUsageDescription"])
 assert any("jarvisiphone" in x["CFBundleURLSchemes"] for x in info["CFBundleURLTypes"])
 assert root+"PrivacyInfo.xcprivacy" in z.namelist()
 resources = Path(__file__).resolve().parents[1] / "JarvisPhone" / "Resources"
 for item in json.loads((resources/'AR_MATERIALS.json').read_text()):
  assert hashlib.sha256(z.read(root+item['file'])).hexdigest() == item['sha256'], 'AR material missing or altered: '+item['file']
 for name in ["jarvis-greeting.pcm","jarvis-connection.pcm","jarvis-torch-on.pcm","jarvis-torch-off.pcm","JarvisInstruments.sf2","GeneralUser-LICENSE.txt"]:
  expected = (resources / name).read_bytes()
  assert expected and z.read(root + name) == expected, f"recurso local divergente: {name}"
 mesh=z.read(root+"WakeHelmet.mesh")
 assert mesh == (resources/"WakeHelmet.mesh").read_bytes() and mesh[:4]==b'XLV1'
 groups=struct.unpack_from('<I',mesh,4)[0]; offset=8; kinds=set()
 for _ in range(groups):
  kind,verts,faces=struct.unpack_from('<III',mesh,offset); kinds.add(kind)
  assert verts>2 and faces>0
  offset+=12+verts*24+faces*12
 assert offset==len(mesh) and kinds=={0,1,2,3}, "geometria incompleta"
 if "--with-extension" in sys.argv:
  ext=root+"PlugIns/JarvisWake.appex/"
  assert info.get("NSSupportsLiveActivities") and plistlib.loads(z.read(ext+"Info.plist"))["CFBundleIdentifier"]=="com.jarvisxlv.iphone.wake"
  assert plistlib.loads(z.read(ext+"Info.plist"))["CFBundleVersion"] == info["CFBundleVersion"], "extension build differs from app"
  assert ext+"JarvisWake" in z.namelist() and ext+"WakePortrait.png" in z.namelist()
  assert any("Anunciar notifica".encode() in z.read(n) or b"JarvisAnnounceNotification" in z.read(n) for n in z.namelist() if n.startswith(root+"Metadata.appintents/")), "ação de notificação ausente"
 print("IPA verificado: arm64, permissões, máscara 3D, voz, instrumentos e recursos.")
