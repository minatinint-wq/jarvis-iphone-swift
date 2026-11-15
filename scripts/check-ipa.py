import sys, zipfile, plistlib, struct
from pathlib import Path
with zipfile.ZipFile(sys.argv[1]) as z:
 p=next(n for n in z.namelist() if n.startswith("Payload/") and n.endswith(".app/Info.plist") and n.count("/")==2)
 info=plistlib.loads(z.read(p)); root=p.rsplit("/",1)[0]+"/"; binary=z.read(root+info["CFBundleExecutable"])
 assert binary[:4]==bytes.fromhex("cffaedfe") and struct.unpack_from("<I",binary,4)[0]==0x0100000c, "esperado Mach-O arm64"
 assert info["CFBundleIdentifier"]=="com.jarvisxlv.iphone"
 assert all(info.get(key) for key in ["NSCameraUsageDescription","NSMicrophoneUsageDescription","NSSpeechRecognitionUsageDescription"])
 assert any("jarvisiphone" in x["CFBundleURLSchemes"] for x in info["CFBundleURLTypes"])
 assert root+"PrivacyInfo.xcprivacy" in z.namelist()
 mask = z.read(root+"AssistantMask.png")
 assert mask[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack_from(">II",mask,16) == (480,512), "máscara do assistente ausente ou inválida"
 resources = Path(__file__).resolve().parents[1] / "JarvisPhone" / "Resources"
 for name in ["jarvis-greeting.pcm","jarvis-torch-on.pcm","jarvis-torch-off.pcm","JarvisInstruments.sf2","GeneralUser-LICENSE.txt"]:
  expected = (resources / name).read_bytes()
  assert expected and z.read(root + name) == expected, f"recurso local divergente: {name}"
 print("IPA verificado: arm64, permissões, URL de ativação, máscara, voz Fish, instrumentos e privacidade.")
