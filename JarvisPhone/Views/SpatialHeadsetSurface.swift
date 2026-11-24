import UIKit
import ARKit
import SceneKit

/// A monoscopic pass-through viewer for phone holders. Both eyes use the same
/// physical camera viewpoint, scene and ARSession. No snapshots, second capture
/// session or invented binocular depth. Lens correction is not calibrated here.
@MainActor final class SpatialHeadsetSurface: UIView {
    private weak var controller: WallARController?
    private let primary: ARSCNView
    private(set) var secondary: ARSCNView?
    private let divider=UIView()
    private var headset=false
    private var viewport=CGSize.zero

    init(controller: WallARController) {
        self.controller=controller;primary=controller.view
        super.init(frame:.zero)
        backgroundColor = .black;clipsToBounds=true
        addSubview(primary)
        divider.backgroundColor = .black;divider.isUserInteractionEnabled=false
        addSubview(divider)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(headset:Bool) {
        secondary?.preferredFramesPerSecond=primary.preferredFramesPerSecond
        secondary?.isPlaying=primary.isPlaying && controller?.foreground == true && controller?.fatal == false && controller?.stopped == false
        guard self.headset != headset else { return }
        self.headset=headset
        controller?.hands.reset()
        if headset {
            let right=ARSCNView(frame:.zero,options:[SCNView.Option.preferredRenderingAPI.rawValue:SCNRenderingAPI.metal.rawValue])
            right.session=primary.session;right.scene=primary.scene
            right.pointOfView=primary.pointOfView
            right.automaticallyUpdatesLighting=false;right.autoenablesDefaultLighting=false
            right.preferredFramesPerSecond=60;right.antialiasingMode = .multisampling2X
            right.rendersContinuously=true;right.isPlaying=primary.isPlaying
            right.addGestureRecognizer(UITapGestureRecognizer(target:self,action:#selector(tapRight(_:))))
            secondary=right;insertSubview(right,belowSubview:divider)
            primary.antialiasingMode = .multisampling2X
            controller?.hands.mirrorOverlay(in:right)
        } else {
            controller?.hands.mirrorOverlay(in:nil)
            // Detach this renderer from the shared session before releasing it.
            // Pausing the shared session here would also stop the primary eye.
            secondary?.isPlaying=false;secondary?.session=ARSession()
            secondary?.scene=SCNScene();secondary?.removeFromSuperview();secondary=nil
            primary.antialiasingMode = .multisampling4X
        }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let paired=headset && bounds.width>bounds.height
        let width=paired ? floor(bounds.width/2) : bounds.width
        primary.frame=CGRect(x:0,y:0,width:width,height:bounds.height)
        secondary?.frame=CGRect(x:width,y:0,width:bounds.width-width,height:bounds.height)
        secondary?.isHidden = !paired
        divider.frame=CGRect(x:width-1,y:0,width:2,height:bounds.height)
        divider.isHidden = !paired
        if viewport != primary.bounds.size {
            viewport=primary.bounds.size
            controller?.hands.reset()
        }
        secondary?.preferredFramesPerSecond=primary.preferredFramesPerSecond
    }
    @objc private func tapRight(_ gesture:UITapGestureRecognizer) {
        guard let secondary else { return }
        controller?.tap(at:gesture.location(in:secondary))
    }
}
