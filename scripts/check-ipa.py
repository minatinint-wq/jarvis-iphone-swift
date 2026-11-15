import sys, zipfile, plistlib, struct
with zipfile.ZipFile(sys.argv[1]) as z:
 p=next(n for n in z.namelist() if n.startswith("Payload/") and n.endswith(".app/Info.plist") and n.count("/")==2)
 info=plistlib.loads(z.read(p)); root=p.rsplit("/",1)[0]+"/"; binary=z.read(root+info["CFBundleExecutable"])
 assert binary[:4]==bytes.fromhex("cffaedfe") and struct.unpack_from("<I",binary,4)[0]==0x0100000c, "esperado Mach-O arm64"
 assert info["CFBundleIdentifier"]=="com.jarvisxlv.iphone"
 assert info["NSCameraUsageDescription"] and info["NSMicrophoneUsageDescription"]
 assert any("jarvisiphone" in x["CFBundleURLSchemes"] for x in info["CFBundleURLTypes"])
 assert root+"PrivacyInfo.xcprivacy" in z.namelist()
 print("IPA verificado: arm64, identificador, câmera, microfone, URL de ativação e manifesto de privacidade.")
