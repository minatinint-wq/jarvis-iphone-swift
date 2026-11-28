import Foundation
import AVFoundation
import ARKit
import SceneKit

enum SpatialCreatureVoice {
    struct Profile:Sendable { let id:String;let name:String;let aliases:[String];let clip:String
        var sound:String { "Spatial_"+id+"_voice.wav" }
    }
    static let profiles:[Profile]=[
        .init(id:"animated_robot",name:"Atlas",aliases:["atlas"],clip:"Wave"),
        .init(id:"animated_fox",name:"Faísca",aliases:["faisca"],clip:"Survey"),
        .init(id:"animated_dragon",name:"Draco",aliases:["draco"],clip:"DragonArmature|DragonArmature|Dragon_Attack2"),
        .init(id:"animated_treant",name:"Raiz",aliases:["raiz"],clip:"Roar"),
        .init(id:"animated_stone_golem",name:"Granito",aliases:["granito"],clip:"Roar"),
        .init(id:"animated_bog_monster",name:"Lodo",aliases:["lodo"],clip:"Roar")
    ]
    static func profile(_ id:String)->Profile? { profiles.first{$0.id==id} }
    static func named(_ text:String)->Profile? {
        var s=PhoneIntentPhrases.normalized(text)
        for prefix in ["chama o ","chama a ","chame o ","chame a ","chama ","chame ","ola ","oi "] where s.hasPrefix(prefix) { s=String(s.dropFirst(prefix.count));break }
        return profiles.first{$0.aliases.contains(s)}
    }
    static func command(_ text:String)->String? {
        let s=PhoneIntentPhrases.normalized(text)
        if ["silenciar criaturas","silenciar personagens","desativar sons das criaturas"].contains(s) { return "sound:off" }
        if ["ativar sons das criaturas","ativar sons dos personagens","ligar sons das criaturas"].contains(s) { return "sound:on" }
        for prefix in ["silenciar ","calar "] where s.hasPrefix(prefix) { return named(String(s.dropFirst(prefix.count))).map{"mute:"+$0.id} }
        for prefix in ["ativar som de ","ativar som do ","ativar som da ","ativar som "] where s.hasPrefix(prefix) { return named(String(s.dropFirst(prefix.count))).map{"unmute:"+$0.id} }
        return named(s).map{"call:"+$0.id}
    }
}

struct SpatialCreatureCallGate {
    private var calls:[String:Double]=[:]
    mutating func accept(_ model:String,time:Double)->Bool {
        guard time.isFinite else { return false }
        if let last=calls[model],time>=last,time-last<0.7 { return false }
        calls[model]=time;return true
    }
}

/// Short, model-specific effects. Never changes the voice/microphone audio session.
@MainActor final class SpatialCreatureAudio {
    static let shared=SpatialCreatureAudio()
    private var players:[String:AVAudioPlayer]=[:]
    private var gate=SpatialCreatureCallGate()
    private var muted:Set<String> { get { Set(UserDefaults.standard.stringArray(forKey:"spatial.creatures.muted") ?? []) } set { UserDefaults.standard.set(Array(newValue),forKey:"spatial.creatures.muted") } }
    var enabled:Bool { get { UserDefaults.standard.object(forKey:"spatial.creatures.sound") as? Bool ?? true } set { UserDefaults.standard.set(newValue,forKey:"spatial.creatures.sound");if !newValue { stop() } } }
    func setMuted(_ id:String,_ value:Bool) { var names=muted;if value { names.insert(id);players[id]?.stop() } else { names.remove(id) };muted=names }
    @discardableResult func play(_ model:String,position:SIMD3<Float>?,camera:simd_float4x4?)->Bool {
        guard enabled,!muted.contains(model),let profile=SpatialCreatureVoice.profile(model),let url=SpatialAssets.file(profile.sound),gate.accept(model,time:ProcessInfo.processInfo.systemUptime) else { return false }
        do {
            let player:AVAudioPlayer
            if let cached=players[model] { player=cached } else { player=try AVAudioPlayer(contentsOf:url);players[model]=player }
            players.values.forEach{$0.stop()};player.currentTime=0;player.numberOfLoops=0
            if let position,let camera {
                let local=simd_inverse(camera)*SIMD4(position,1),distance=simd_length(SIMD3(local.x,local.y,local.z))
                player.pan=max(-0.75,min(0.75,local.x/max(0.5,distance)));player.volume=max(0.2,0.75/(1+distance*0.25))
            } else { player.pan=0;player.volume=0.65 }
            player.prepareToPlay();return player.play()
        } catch { return false }
    }
    func stop() { players.values.forEach{$0.stop()} }
}
