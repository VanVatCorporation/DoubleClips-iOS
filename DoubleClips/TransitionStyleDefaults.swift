import Foundation

// MARK: - Embedded copies of the bundled transition styles
//
// `animations/transitions/*.json` are the source of truth and win when the app bundle has them; these copies are registered only
// for ids the bundle did not provide (a folder that never made it into the target). Keep them equal to the files
// (regenerate by minifying the file).

enum TransitionStyleDefaults {
    static let json: [String: String] = [
        "circleclose": #"""
{"schema":1,"id":"circleclose","name":"Circle Close","description":"A closes toward the centre; B is outside the shrinking circle (mask: circle, inverted).","defaultDuration":0.5,"mode":"mask","mask":{"shape":"circle","reveal":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]},"invert":true}}
"""#,
        "circleopen": #"""
{"schema":1,"id":"circleopen","name":"Circle Open","description":"B opens from the centre as a growing circle (mask: circle).","defaultDuration":0.5,"mode":"mask","mask":{"shape":"circle","reveal":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]}}}
"""#,
        "diagbl": #"""
{"schema":1,"id":"diagbl","name":"Diagonal Bottom-Left Wipe","description":"B is revealed from the bottom-left corner along the diagonal (mask: wipe in canvas proportions).","defaultDuration":0.5,"mode":"mask","mask":{"shape":"wipe","reveal":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]},"angle":45,"normalized":true}}
"""#,
        "diagtl": #"""
{"schema":1,"id":"diagtl","name":"Diagonal Top-Left Wipe","description":"B is revealed from the top-left corner along the diagonal (mask: wipe in canvas proportions).","defaultDuration":0.5,"mode":"mask","mask":{"shape":"wipe","reveal":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]},"angle":-45,"normalized":true}}
"""#,
        "dissolve": #"""
{"schema":1,"id":"dissolve","name":"Dissolve","description":"Every pixel flips from A to B at its own moment (mask: noise).","defaultDuration":0.5,"mode":"mask","mask":{"shape":"noise","reveal":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]}}}
"""#,
        "fade": #"""
{"schema":1,"id":"fade","name":"Cross Fade","description":"B fades in over A. Both pictures are drawn (mode layers).","defaultDuration":0.5,"mode":"layers","from":{"channels":{"opacity":{"kind":"constant","value":1}}},"to":{"channels":{"opacity":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]}}}}
"""#,
        "fadeblack": #"""
{"schema":1,"id":"fadeblack","name":"Fade Black","description":"A darkens to black in the first half, B brightens from black in the second (hard cut at the middle).","defaultDuration":0.5,"cut":0.5,"from":{"channels":{"exposure":{"kind":"knots","interp":"linear","points":[[0,1],[0.5,0]]}}},"to":{"channels":{"exposure":{"kind":"knots","interp":"linear","points":[[0,0],[0.5,0],[1,1]]}}}}
"""#,
        "fadegrays": #"""
{"schema":1,"id":"fadegrays","name":"Fade Gray","description":"Both pictures lose their colour toward the middle while B cross fades in over A.","defaultDuration":0.5,"mode":"layers","from":{"channels":{"saturation":{"kind":"knots","interp":"linear","points":[[0,1],[0.5,0],[1,0]]}}},"to":{"channels":{"saturation":{"kind":"knots","interp":"linear","points":[[0,0],[0.5,0],[1,1]]},"opacity":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]}}}}
"""#,
        "fadewhite": #"""
{"schema":1,"id":"fadewhite","name":"Fade White","description":"A washes out to white in the first half, B comes in from white in the second (hard cut at the middle).","defaultDuration":0.5,"cut":0.5,"from":{"channels":{"whiteMix":{"kind":"knots","interp":"linear","points":[[0,0],[0.5,1]]}}},"to":{"channels":{"whiteMix":{"kind":"knots","interp":"linear","points":[[0,1],[0.5,1],[1,0]]}}}}
"""#,
        "glitchblur": #"""
{"schema":1,"id":"glitchblur","name":"Glitch Blur","description":"A is dark-hit, folds toward the top centre and streaks into a washed-out blur, hard cut at 0.55; B arrives folded, smashes onto the ground (about 5% smaller), bounces up expanding, then settles to 100%. Read off CapCut (60 fps).","defaultDuration":2.3,"cut":0.55,"from":{"channels":{"exposure":{"kind":"knots","interp":"linear","points":[[0.0,0.32],[0.0398,0.335],[0.0615,0.38],[0.1049,0.47],[0.1266,0.62],[0.1701,0.76],[0.2171,0.7],[0.275,0.64],[0.3039,0.64],[0.3257,0.7],[0.3872,1.0],[0.4306,1.15],[0.4523,1.24],[0.474,1.29],[0.5174,1.3],[0.55,1.3]]},"brightness":{"kind":"knots","interp":"linear","points":[[0,0],[0.3872,0],[0.474,0.9],[0.55,1.0]]},"motionBlur":{"kind":"knots","interp":"linear","points":[[0,0],[0.1086,0],[0.2171,0.006],[0.3293,0.034],[0.4342,0.059],[0.55,0.09]]},"blurAngle":{"kind":"constant","value":60},"edgeFill":{"kind":"constant","value":1},"warp.topWidth":{"kind":"knots","interp":"smooth","points":[[0,1],[0.1086,1],[0.55,0.93]]},"warp.bottomWidth":{"kind":"knots","interp":"smooth","points":[[0,1],[0.1086,1],[0.55,0.89]]},"warp.height":{"kind":"knots","interp":"smooth","points":[[0,1],[0.1086,1],[0.55,0.945]]}}},"to":{"channels":{"exposure":{"kind":"knots","interp":"linear","points":[[0.55,1.13],[0.604,1.11],[0.6256,1.08],[0.6472,1.04],[0.6904,1.01],[0.7228,1.0],[1.0,1.0]]},"brightness":{"kind":"knots","interp":"linear","points":[[0.55,0.5],[0.6652,0],[1.0,0]]},"motionBlur":{"kind":"knots","interp":"linear","points":[[0.55,0.09],[0.5788,0.0685],[0.6076,0.049],[0.6364,0.0318],[0.6652,0.0173],[0.694,0.006],[0.7228,0],[1.0,0]]},"blurAngle":{"kind":"constant","value":60},"edgeFill":{"kind":"constant","value":1},"warp.topWidth":{"kind":"knots","interp":"linear","points":[[0.55,0.93],[0.5896,0.935],[0.6148,0.94],[0.64,0.945],[0.6868,0.95],[0.7048,0.952],[0.7336,0.959],[0.7624,0.968],[0.7984,0.983],[0.8092,0.986],[0.8344,0.993],[0.8848,0.998],[0.8956,1.002],[0.9244,1.0],[0.9712,1.0],[1.0,1.0]]},"warp.bottomWidth":{"kind":"knots","interp":"linear","points":[[0.55,0.89],[0.5896,0.915],[0.6148,0.935],[0.64,0.945],[0.6868,0.95],[0.7048,0.952],[0.7336,0.959],[0.7624,0.968],[0.7984,0.983],[0.8092,0.986],[0.8344,0.993],[0.8848,0.998],[0.8956,1.002],[0.9244,1.0],[0.9712,1.0],[1.0,1.0]]},"warp.height":{"kind":"knots","interp":"linear","points":[[0.55,0.945],[0.5896,0.944],[0.6148,0.956],[0.64,0.966],[0.6868,0.969],[0.7048,0.972],[0.7336,0.976],[0.7624,0.978],[0.7984,0.982],[0.8092,0.986],[0.8344,0.988],[0.8848,0.99],[0.8956,0.99],[0.9244,0.992],[0.9712,0.996],[1.0,1.0]]},"offsetY":{"kind":"knots","interp":"linear","points":[[0.55,0.021],[0.5896,0.021],[0.6148,0.022],[0.64,0.0235],[0.6868,0.032],[0.7048,0.032],[0.7336,0.0205],[0.7624,0.0137],[0.7984,0.0076],[0.8092,0.003],[0.8344,0.0008],[0.8848,0],[0.8956,0],[0.9244,0],[0.9712,0],[1.0,0]]}}}}
"""#,
        "hlslice": #"""
{"schema":1,"id":"hlslice","name":"Horizontal Left Slice","description":"Ten vertical strips; in each B grows from the left edge (mask: slices).","defaultDuration":0.5,"mode":"mask","mask":{"shape":"slices","reveal":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]},"angle":0,"count":10}}
"""#,
        "hrslice": #"""
{"schema":1,"id":"hrslice","name":"Horizontal Right Slice","description":"Ten vertical strips; in each B grows from the right edge (mask: slices).","defaultDuration":0.5,"mode":"mask","mask":{"shape":"slices","reveal":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]},"angle":180,"count":10}}
"""#,
        "radial": #"""
{"schema":1,"id":"radial","name":"Radial","description":"B is swept in clockwise from 12 o'clock like a clock hand (mask: clock).","defaultDuration":0.5,"mode":"mask","mask":{"shape":"clock","reveal":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]},"start":0}}
"""#,
        "revealup": #"""
{"schema":1,"id":"revealup","name":"Reveal Up","description":"A slides up and away while B stays put underneath (mask: wipe following A's lower edge).","defaultDuration":0.5,"mode":"mask","from":{"channels":{"offsetY":{"kind":"knots","interp":"linear","points":[[0,0],[1,-1]]}}},"mask":{"shape":"wipe","reveal":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]},"angle":90}}
"""#,
        "slidedown": #"""
{"schema":1,"id":"slidedown","name":"Slide Down","description":"Both pictures move down together; B enters from the top.","defaultDuration":0.5,"mode":"layers","from":{"channels":{"offsetY":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]}}},"to":{"channels":{"offsetY":{"kind":"knots","interp":"linear","points":[[0,-1],[1,0]]}}}}
"""#,
        "slideleft": #"""
{"schema":1,"id":"slideleft","name":"Slide Left","description":"Both pictures move left together; B enters from the right.","defaultDuration":0.5,"mode":"layers","from":{"channels":{"offsetX":{"kind":"knots","interp":"linear","points":[[0,0],[1,-1]]}}},"to":{"channels":{"offsetX":{"kind":"knots","interp":"linear","points":[[0,1],[1,0]]}}}}
"""#,
        "slideright": #"""
{"schema":1,"id":"slideright","name":"Slide Right","description":"Both pictures move right together; B enters from the left.","defaultDuration":0.5,"mode":"layers","from":{"channels":{"offsetX":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]}}},"to":{"channels":{"offsetX":{"kind":"knots","interp":"linear","points":[[0,-1],[1,0]]}}}}
"""#,
        "slideup": #"""
{"schema":1,"id":"slideup","name":"Slide Up","description":"Both pictures move up together; B enters from the bottom.","defaultDuration":0.5,"mode":"layers","from":{"channels":{"offsetY":{"kind":"knots","interp":"linear","points":[[0,0],[1,-1]]}}},"to":{"channels":{"offsetY":{"kind":"knots","interp":"linear","points":[[0,1],[1,0]]}}}}
"""#,
        "vdslice": #"""
{"schema":1,"id":"vdslice","name":"Vertical Down Slice","description":"Ten horizontal strips; in each B grows downward from the top (mask: slices).","defaultDuration":0.5,"mode":"mask","mask":{"shape":"slices","reveal":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]},"angle":-90,"count":10}}
"""#,
        "vuslice": #"""
{"schema":1,"id":"vuslice","name":"Vertical Up Slice","description":"Ten horizontal strips; in each B grows upward from the bottom (mask: slices).","defaultDuration":0.5,"mode":"mask","mask":{"shape":"slices","reveal":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]},"angle":90,"count":10}}
"""#,
        "wipeleft": #"""
{"schema":1,"id":"wipeleft","name":"Wipe Left","description":"B is revealed from the right edge, sweeping left (mask: wipe).","defaultDuration":0.5,"mode":"mask","mask":{"shape":"wipe","reveal":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]},"angle":180}}
"""#,
        "wiperight": #"""
{"schema":1,"id":"wiperight","name":"Wipe Right","description":"B is revealed from the left edge, sweeping right (mask: wipe).","defaultDuration":0.5,"mode":"mask","mask":{"shape":"wipe","reveal":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]},"angle":0}}
"""#,
        "pixelize": #"""
{"schema":1,"id":"pixelize","name":"Pixelize","description":"A breaks into growing square blocks, hard cut at the middle, then B's blocks shrink back to sharp (like xfade pixelize).","defaultDuration":0.8,"cut":0.5,"from":{"channels":{"pixelate":{"kind":"knots","interp":"linear","points":[[0,0],[0.5,0.07]]}}},"to":{"channels":{"pixelate":{"kind":"knots","interp":"linear","points":[[0.5,0.07],[1,0]]}}}}
"""#,
        "hblur": #"""
{"schema":1,"id":"hblur","name":"Horizontal Blur","description":"A smears sideways into a streaked blur, cut at the middle, B comes out of the same blur (like xfade hblur).","defaultDuration":0.8,"cut":0.5,"from":{"channels":{"motionBlur":{"kind":"knots","interp":"smooth","points":[[0,0],[0.5,0.3]]}}},"to":{"channels":{"motionBlur":{"kind":"knots","interp":"smooth","points":[[0.5,0.3],[1,0]]}}}}
"""#,
        "circlecrop": #"""
{"schema":1,"id":"circlecrop","name":"Circle Crop","description":"A is seen through a circle that shrinks to nothing on black, then B through a circle that grows (like xfade circlecrop).","defaultDuration":0.9,"mode":"crop","mask":{"shape":"circle","reveal":{"kind":"knots","interp":"linear","points":[[0,1],[0.5,0],[1,1]]}}}
"""#,
        "rectcrop": #"""
{"schema":1,"id":"rectcrop","name":"Rect Crop","description":"A is seen through a rectangle that shrinks to nothing on black, then B through a rectangle that grows (like xfade rectcrop).","defaultDuration":0.9,"mode":"crop","mask":{"shape":"rect","reveal":{"kind":"knots","interp":"linear","points":[[0,1],[0.5,0],[1,1]]}}}
"""#,
        "distance": #"""
{"schema":1,"id":"distance","name":"Distance","description":"B takes over pixel by pixel, first where the two pictures are closest in colour (mask: distance).","defaultDuration":0.8,"mode":"mask","mask":{"shape":"distance","reveal":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]},"softness":0.04}}
"""#,
        "custom_expose": #"""
{"schema":1,"id":"custom_expose","name":"Expose","description":"B is exposed from the top edge downward as a hard wipe (Android's Expose).","defaultDuration":0.6,"mode":"mask","mask":{"shape":"wipe","reveal":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]},"angle":-90}}
"""#,
        "custom_two-stage-slide": #"""
{"schema":1,"id":"custom_two-stage-slide","name":"Two Stage Slide","description":"Both pictures slide left in two stages with a pause in the middle; B enters from the right.","defaultDuration":1.0,"mode":"layers","from":{"channels":{"offsetX":{"kind":"knots","interp":"smooth","points":[[0,0],[0.4,-0.5],[0.6,-0.5],[1,-1]]}}},"to":{"channels":{"offsetX":{"kind":"knots","interp":"smooth","points":[[0,1],[0.4,0.5],[0.6,0.5],[1,0]]}}}}
"""#,
        "custom_radial-shockwave": #"""
{"schema":1,"id":"custom_radial-shockwave","name":"Radial Shockwave","description":"B bursts out of the centre as a soft ring: a flash on A, B lands slightly enlarged and settles.","defaultDuration":0.9,"mode":"mask","mask":{"shape":"circle","reveal":{"kind":"knots","interp":"smooth","points":[[0,0],[1,1]]},"softness":0.2},"from":{"channels":{"exposure":{"kind":"knots","interp":"smooth","points":[[0,1],[0.4,1.7],[0.8,1]]}}},"to":{"channels":{"scale":{"kind":"knots","interp":"smooth","points":[[0,1.12],[1,1]]},"blur":{"kind":"knots","interp":"smooth","points":[[0,0.012],[1,0]]}}}}
"""#,
        "custom_fake-glass-shatter": #"""
{"schema":1,"id":"custom_fake-glass-shatter","name":"Fake Glass Shatter","description":"B appears in scattered square shards over A while both drift slightly (mask: noise).","defaultDuration":0.9,"mode":"mask","mask":{"shape":"noise","reveal":{"kind":"knots","interp":"linear","points":[[0,0],[1,1]]},"softness":0.03,"grain":36},"from":{"channels":{"scale":{"kind":"knots","interp":"linear","points":[[0,1],[1,1.05]]}}},"to":{"channels":{"scale":{"kind":"knots","interp":"linear","points":[[0,1.05],[1,1]]}}}}
"""#,
        "custom_massive-effect": #"""
{"schema":1,"id":"custom_massive-effect","name":"Massive Effect","description":"A is flung toward the viewer, blurred and blown out, cut at the middle; B lands from far away, spinning back to level.","defaultDuration":1.0,"cut":0.5,"from":{"channels":{"scale":{"kind":"knots","interp":"smooth","points":[[0,1],[0.5,1.7]]},"blur":{"kind":"knots","interp":"smooth","points":[[0,0],[0.5,0.04]]},"exposure":{"kind":"knots","interp":"smooth","points":[[0,1],[0.5,2.6]]},"rotation":{"kind":"knots","interp":"smooth","points":[[0,0],[0.5,8]]}}},"to":{"channels":{"scale":{"kind":"knots","interp":"smooth","points":[[0.5,0.55],[1,1]]},"blur":{"kind":"knots","interp":"smooth","points":[[0.5,0.04],[1,0]]},"exposure":{"kind":"knots","interp":"smooth","points":[[0.5,2.6],[1,1]]},"rotation":{"kind":"knots","interp":"smooth","points":[[0.5,-8],[1,0]]}}}}
"""#
    ]
}
