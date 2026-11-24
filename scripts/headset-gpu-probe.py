from pathlib import Path

source = Path('JarvisPhone/Views/SpatialHeadsetSurface.swift').read_text(encoding='utf-8')
core = source[source.index('enum SpatialEyeLayout'):source.index('@MainActor final class SpatialHeadsetSurface')]

header = '''import Foundation
import AppKit
import MetalKit
import SceneKit
import CoreVideo
import ImageIO

typealias UIColor=NSColor
'''

body = r'''
@main struct GPUProbe {
 @MainActor static func main() throws {
  guard let device=MTLCreateSystemDefaultDevice() else { fatalError("Metal unavailable") }
  let compositor=try SpatialEyeCompositor(device:device)
  var buffer:CVPixelBuffer?
  let attrs:[String:Any]=[kCVPixelBufferMetalCompatibilityKey as String:true,kCVPixelBufferIOSurfacePropertiesKey as String:[:]]
  precondition(CVPixelBufferCreate(nil,32,32,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,attrs as CFDictionary,&buffer)==kCVReturnSuccess)
  let pixels=buffer!
  CVPixelBufferLockBaseAddress(pixels,[])
  let colors:[(UInt8,UInt8,UInt8)]=[(76,85,255),(150,44,21),(29,255,107),(226,0,149)]
  let y=CVPixelBufferGetBaseAddressOfPlane(pixels,0)!.assumingMemoryBound(to:UInt8.self)
  let uv=CVPixelBufferGetBaseAddressOfPlane(pixels,1)!.assumingMemoryBound(to:UInt8.self)
  for row in 0..<32 { for x in 0..<32 { y[row*CVPixelBufferGetBytesPerRowOfPlane(pixels,0)+x]=colors[x/8].0 } }
  for row in 0..<16 { for x in 0..<16 {
   let i=row*CVPixelBufferGetBytesPerRowOfPlane(pixels,1)+x*2
   uv[i]=colors[x/4].1;uv[i+1]=colors[x/4].2
  } }
  CVPixelBufferUnlockBaseAddress(pixels,[])
  let eyes=SpatialEyeLayout.frames(size:CGSize(width:820,height:400),gap:20)
  let scene=SCNScene(),cube=SCNNode(geometry:SCNBox(width:0.16,height:0.16,length:0.16,chamferRadius:0))
  cube.position=SCNVector3(0,0,-1);cube.geometry!.firstMaterial!.lightingModel = .constant;cube.geometry!.firstMaterial!.diffuse.contents=NSColor.white;scene.rootNode.addChildNode(cube)
  let f:Float=1/tan(Float.pi/6)
  let projection=simd_float4x4(SIMD4(f,0,0,0),SIMD4(0,f,0,0),SIMD4(0,0,-1.001,-1),SIMD4(0,0,-0.02001,0))
  for rotated in [false,true] {
   let spec=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:820,height:400,mipmapped:false)
   spec.storageMode = .shared;spec.usage = .renderTarget
   let target=device.makeTexture(descriptor:spec)!,command=compositor.queue.makeCommandBuffer()!
   let world=compositor.renderWorld(scene:scene,transform:matrix_identity_float4x4,projection:projection,size:eyes[0].size,time:0,command:command)!
   let transform=rotated ? CGAffineTransform(a:-1,b:0,c:0,d:-1,tx:1,ty:1) : .identity
   precondition(compositor.compose(pixels:pixels,displayToCamera:transform,world:world,destination:target,eyes:eyes,command:command))
   let completed=DispatchSemaphore(value:0);command.addCompletedHandler { _ in completed.signal() };command.commit()
   precondition(completed.wait(timeout:.now()+20) == .success,"GPU completion timeout")
   precondition(command.status == .completed,"GPU error")
   var bytes=[UInt8](repeating:0,count:820*400*4)
   bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow:820*4,from:MTLRegionMake2D(0,0,820,400),mipmapLevel:0) }
   let provider=CGDataProvider(data:Data(bytes) as CFData)!
   let info=CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue))
   let image=CGImage(width:820,height:400,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:3280,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:info,provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
   let name=rotated ? "JARVIS-VRBOX-GPU-ROTATED.png" : "JARVIS-VRBOX-GPU.png"
   let out=CGImageDestinationCreateWithURL(URL(fileURLWithPath:name) as CFURL,"public.png" as CFString,1,nil)!
   CGImageDestinationAddImage(out,image,nil);precondition(CGImageDestinationFinalize(out))
   var mismatch=0
   for row in 0..<400 { for x in 0..<400 {
    let a=(row*820+x)*4,b=(row*820+420+x)*4
    if bytes[a..<a+4] != bytes[b..<b+4] { mismatch+=1 }
   } }
   precondition(mismatch==0,"Eye pixels differ")
   for x in 400..<420 {
    let offset=(200*820+x)*4
    precondition(bytes[offset]==0 && bytes[offset+1]==0 && bytes[offset+2]==0 && bytes[offset+3]==255,"Gutter is not black")
   }
   let expected:[[Int]]=rotated ? [[1,1,0],[0,0,1],[0,1,0],[1,0,0]] : [[1,0,0],[0,1,0],[0,0,1],[1,1,0]]
   for stripe in 0..<4 {
    let offset=(360*820+stripe*100+50)*4
    let rgb=[bytes[offset+2],bytes[offset+1],bytes[offset]]
    for channel in 0..<3 { precondition(expected[stripe][channel]==1 ? rgb[channel]>180 : rgb[channel]<80,"Camera stripe color missing") }
   }
   let middle=(200*820+200)*4
   precondition(bytes[middle]>200 && bytes[middle+1]>200 && bytes[middle+2]>200,"3D cube missing")
   print("GPU_PASS: rotated=\(rotated); eye_mismatch_pixels=\(mismatch); all_camera_stripes=4; world_cube=present; gutter=black")
  }
 }
}
'''

Path('HeadsetGPUProbe.swift').write_text(header + core + body, encoding='utf-8')
