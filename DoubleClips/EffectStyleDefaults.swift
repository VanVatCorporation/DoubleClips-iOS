import Foundation

// MARK: - Embedded copies of the bundled effect styles
//
// `animations/effects/*.json` are the source of truth and win when the app bundle has them; these copies are registered only
// for ids the bundle did not provide (a folder that never made it into the target). Keep them equal to the files.

enum EffectStyleDefaults {
    static let json: [String: String] = [
        "slow-push": #"""
{"schema":1,"id":"slow-push","name":"Slow Push","description":"A slow push-in toward the centre across the whole effect. Strength scales how far it pushes.","intensity":{"label":"Push","min":0.2,"max":4},"channels":{"scale":{"kind":"knots","interp":"linear","points":[[0,1],[1,1.12]]}}}
"""#,
        "drift-blur": #"""
{"schema":1,"id":"drift-blur","name":"Drift Blur","description":"A streak blur that swells then fades while the picture drifts left, edge pixels stretching into the gap.","intensity":{"label":"Strength","min":0.2,"max":3},"channels":{"motionBlur":{"kind":"knots","interp":"smooth","points":[[0,0],[0.2,0.05],[0.8,0.05],[1,0]]},"blurAngle":{"kind":"constant","value":172},"edgeSlide":{"kind":"knots","interp":"smooth","points":[[0,0],[1,-0.08]]},"edgeFill":{"kind":"constant","value":1}}}
"""#,
        "heartbeat": #"""
{"schema":1,"id":"heartbeat","name":"Heartbeat","description":"A double pulse every second: the picture swells and brightens twice, like a heartbeat.","intensity":{"label":"Strength","min":0.2,"max":3},"period":1.0,"channels":{"scale":{"kind":"knots","interp":"linear","points":[[0,1],[0.12,1.06],[0.24,1],[0.36,1.045],[0.55,1],[1,1]]},"exposure":{"kind":"knots","interp":"linear","points":[[0,1],[0.12,1.12],[0.24,1],[0.36,1.08],[0.55,1],[1,1]]}}}
"""#
    ]
}
