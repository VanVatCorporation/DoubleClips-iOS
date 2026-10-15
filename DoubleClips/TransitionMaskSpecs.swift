import Foundation

// GENERATED from work/specs.py: the mask shapes a transition style ("mode": "mask") may use and their parameters.

extension EffectFilterOps {
    static let maskSpecs: [String: EffectFilterSpec] = [
        "wipe": EffectFilterSpec(params: [EffectFilterParam(name: "reveal", def: 0.0, neutral: 0.0, min: 0.0, max: 1.0, scaled: false), EffectFilterParam(name: "angle", def: 180.0, neutral: 0.0, min: -360.0, max: 360.0, scaled: false), EffectFilterParam(name: "softness", def: 0.0, neutral: 0.0, min: 0.0, max: 0.5, scaled: false)], flags: ["normalized"], strings: [:]),
        "circle": EffectFilterSpec(params: [EffectFilterParam(name: "reveal", def: 0.0, neutral: 0.0, min: 0.0, max: 1.0, scaled: false), EffectFilterParam(name: "cx", def: 0.5, neutral: 0.5, min: 0.0, max: 1.0, scaled: false), EffectFilterParam(name: "cy", def: 0.5, neutral: 0.5, min: 0.0, max: 1.0, scaled: false), EffectFilterParam(name: "softness", def: 0.0, neutral: 0.0, min: 0.0, max: 1.0, scaled: false)], flags: ["invert"], strings: [:]),
        "noise": EffectFilterSpec(params: [EffectFilterParam(name: "reveal", def: 0.0, neutral: 0.0, min: 0.0, max: 1.0, scaled: false), EffectFilterParam(name: "softness", def: 0.001, neutral: 0.001, min: 0.001, max: 0.5, scaled: false), EffectFilterParam(name: "grain", def: 1.0, neutral: 1.0, min: 1.0, max: 64.0, scaled: false)], flags: [], strings: [:]),
        "slices": EffectFilterSpec(params: [EffectFilterParam(name: "reveal", def: 0.0, neutral: 0.0, min: 0.0, max: 1.0, scaled: false), EffectFilterParam(name: "angle", def: 0.0, neutral: 0.0, min: -360.0, max: 360.0, scaled: false), EffectFilterParam(name: "count", def: 10.0, neutral: 10.0, min: 1.0, max: 64.0, scaled: false)], flags: [], strings: [:]),
        "clock": EffectFilterSpec(params: [EffectFilterParam(name: "reveal", def: 0.0, neutral: 0.0, min: 0.0, max: 1.0, scaled: false), EffectFilterParam(name: "start", def: 0.0, neutral: 0.0, min: -360.0, max: 360.0, scaled: false)], flags: [], strings: [:]),
        // Added by hand (the generator above predates them): "rect" = a centred rectangle that is `reveal` of the canvas
        // in both directions (crop transitions), "distance" = B shows where A and B differ least first (needs both pictures).
        "rect": EffectFilterSpec(params: [EffectFilterParam(name: "reveal", def: 0.0, neutral: 0.0, min: 0.0, max: 1.0, scaled: false), EffectFilterParam(name: "softness", def: 0.0, neutral: 0.0, min: 0.0, max: 0.5, scaled: false)], flags: [], strings: [:]),
        "distance": EffectFilterSpec(params: [EffectFilterParam(name: "reveal", def: 0.0, neutral: 0.0, min: 0.0, max: 1.0, scaled: false), EffectFilterParam(name: "softness", def: 0.04, neutral: 0.04, min: 0.001, max: 0.5, scaled: false)], flags: [], strings: [:]),
    ]
}
