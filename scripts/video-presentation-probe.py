"""Build a small iOS app from the production video view and frame delivery code.
No ARSession, SceneKit world, full Jarvis build, or UI-testing privileges needed.
The workflow captures the actual app screen using the simulator's screenshot API.
"""
from pathlib import Path
import plistlib, subprocess, platform

source=Path('JarvisPhone/Views/SpatialHeadsetSurface.swift').read_text()
layout=source[source.index('enum SpatialEyeLayout'):source.index('\n}\n',source.index('enum SpatialEyeLayout'))+3]
eye=source[source.index('@MainActor final class SpatialHeadsetEye'):source.index('private struct SpatialHeadsetPacket')]
delivery=source[source.index('    @discardableResult func displayCamera'):source.index('    @objc private func tapHeadset')]
app=Path('/tmp/JarvisVideoProbe.app');app.mkdir(exist_ok=True)
code='''import UIKit
import AVFoundation
import MetalKit
import CoreImage
import CoreMedia
'''+layout+eye+'''
@MainActor final class ProbeHost:UIView {
 let headset=true
 let eyes:[SpatialHeadsetEye]
 override init(frame:CGRect) {
  eyes=[SpatialHeadsetEye(device:MTLCreateSystemDefaultDevice()!),SpatialHeadsetEye(device:MTLCreateSystemDefaultDevice()!)]
  super.init(frame:frame);backgroundColor = .black;clipsToBounds=true
  for eye in eyes { addSubview(eye) }
 }
 required init?(coder:NSCoder) { fatalError() }
 override func layoutSubviews() { super.layoutSubviews();for (eye,rect) in zip(eyes,SpatialEyeLayout.frames(size:bounds.size)) { eye.frame=rect;eye.layoutIfNeeded() } }
'''+delivery+'''
}
final class ProbeController:UIViewController {
 override var supportedInterfaceOrientations:UIInterfaceOrientationMask { .landscape }
 override var preferredInterfaceOrientationForPresentation:UIInterfaceOrientation { .landscapeRight }
}
@main final class ProbeApp:NSObject,UIApplicationDelegate {
 var window:UIWindow?
 func application(_ application:UIApplication,didFinishLaunchingWithOptions options:[UIApplication.LaunchOptionsKey:Any]?=nil)->Bool {
  let window=UIWindow(frame:UIScreen.main.bounds),root=ProbeController();self.window=window
  window.rootViewController=root;window.makeKeyAndVisible()
  let host=ProbeHost(frame:root.view.bounds);host.autoresizingMask=[.flexibleWidth,.flexibleHeight];root.view.addSubview(host)
  Task { @MainActor in
   do {
    try await Task.sleep(for:.seconds(1));host.layoutIfNeeded()
    let w=240,h=max(16,Int(240*host.eyes[0].bounds.height/max(1,host.eyes[0].bounds.width)))
    var optional:CVPixelBuffer?
    let attrs:[CFString:Any]=[kCVPixelBufferIOSurfacePropertiesKey:[:]]
    guard CVPixelBufferCreate(nil,w,h,kCVPixelFormatType_32BGRA,attrs as CFDictionary,&optional)==kCVReturnSuccess,let pixels=optional else { throw CocoaError(.coderInvalidValue) }
    CVPixelBufferLockBaseAddress(pixels,[])
    let ptr=CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to:UInt8.self)
    let colors:[[UInt8]]=[[0,0,255,255],[0,255,0,255],[255,0,0,255],[0,255,255,255]]
    for y in 0..<h { for x in 0..<w { for c in 0..<4 { ptr[y*CVPixelBufferGetBytesPerRow(pixels)+x*4+c]=colors[min(3,x*4/w)][c] } } }
    CVPixelBufferUnlockBaseAddress(pixels,[])
    for tick in 0..<40 {
     guard host.displayCamera(pixels,orientation:.landscapeRight,time:Double(tick)/30) else { throw CocoaError(.coderReadCorrupt) }
     try await Task.sleep(for:.milliseconds(33))
    }
    let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
    let context=CIContext();var pngs:[Data]=[]
    for (i,eye) in host.eyes.enumerated() {
     guard eye.cameraFrames>0,eye.video.isReadyForDisplay,let displayed=eye.video.sampleBufferRenderer.displayedPixelBuffer(),let image=context.createCGImage(CIImage(cvPixelBuffer:displayed),from:CGRect(x:0,y:0,width:w,height:h)),let png=UIImage(cgImage:image).pngData() else { throw CocoaError(.coderReadCorrupt) }
     pngs.append(png);try png.write(to:folder.appendingPathComponent("eye-\\(i).png"))
    }
    guard pngs[0]==pngs[1] else { throw CocoaError(.coderReadCorrupt) }
    let result:[String:Any]=["passed":true,"frames":host.eyes.map{$0.cameraFrames},"width":w,"height":h,"same_displayed_pixels":true,"hosts_clipped":host.eyes.allSatisfy{$0.clipsToBounds}]
    try JSONSerialization.data(withJSONObject:result,options:.prettyPrinted).write(to:folder.appendingPathComponent("result.json"))
   } catch {
    let folder=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
    try? JSONSerialization.data(withJSONObject:["passed":false,"error":String(describing:error)]).write(to:folder.appendingPathComponent("result.json"))
   }
  }
  return true
 }
}
'''
Path('/tmp/VideoProbe.swift').write_text(code)
info={'CFBundleIdentifier':'com.jarvisxlv.video-probe','CFBundleExecutable':'VideoProbe','CFBundleName':'VideoProbe','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','MinimumOSVersion':'17.4','UIDeviceFamily':[1],'LSRequiresIPhoneOS':True,'UISupportedInterfaceOrientations':['UIInterfaceOrientationLandscapeRight','UIInterfaceOrientationLandscapeLeft']}
(app/'Info.plist').write_bytes(plistlib.dumps(info))
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
arch='arm64' if platform.machine()=='arm64' else 'x86_64'
subprocess.run(['xcrun','--sdk','iphonesimulator','swiftc','-parse-as-library','-swift-version','5','-target',f'{arch}-apple-ios17.4-simulator','-sdk',sdk,'/tmp/VideoProbe.swift','-o',str(app/'VideoProbe')],check=True)
print('PRODUCTION_VIDEO_PROBE_BUILT')
