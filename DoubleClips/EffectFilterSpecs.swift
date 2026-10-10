import Foundation

// GENERATED from the filter registry (work/specs.py): which `filters` ops effect JSON may use, their parameters, ranges and
// whether the strength slider scales them (distance from `neutral`). The drawing code is in EditingView+Effects.swift.

extension EffectFilterOps {
    static let specs: [String: EffectFilterSpec] = [
        "blur": EffectFilterSpec(params: [EffectFilterParam(name: "radius", def: 0.0, neutral: 0.0, min: 0.0, max: 0.2, scaled: true)], flags: [], strings: [:]),
        "colorControls": EffectFilterSpec(params: [EffectFilterParam(name: "brightness", def: 0.0, neutral: 0.0, min: -1.0, max: 1.0, scaled: true), EffectFilterParam(name: "contrast", def: 1.0, neutral: 1.0, min: 0.0, max: 4.0, scaled: true), EffectFilterParam(name: "saturation", def: 1.0, neutral: 1.0, min: 0.0, max: 4.0, scaled: true)], flags: [], strings: [:]),
        "photoEffect": EffectFilterSpec(params: [], flags: [], strings: ["name": EffectFilterString(allowed: ["noir", "chrome", "fade", "instant", "mono", "process", "tonal", "transfer"], def: "noir")]),
        "sepia": EffectFilterSpec(params: [EffectFilterParam(name: "intensity", def: 1.0, neutral: 0.0, min: 0.0, max: 1.0, scaled: true)], flags: [], strings: [:]),
        "vignette": EffectFilterSpec(params: [EffectFilterParam(name: "intensity", def: 1.0, neutral: 0.0, min: 0.0, max: 3.0, scaled: true), EffectFilterParam(name: "radius", def: 1.4, neutral: 1.4, min: 0.0, max: 3.0, scaled: false)], flags: [], strings: [:]),
        "bloom": EffectFilterSpec(params: [EffectFilterParam(name: "radius", def: 0.025, neutral: 0.0, min: 0.0, max: 0.2, scaled: true), EffectFilterParam(name: "intensity", def: 1.0, neutral: 0.6, min: 0.0, max: 1.2, scaled: true)], flags: [], strings: [:]),
        "pixellate": EffectFilterSpec(params: [EffectFilterParam(name: "scale", def: 0.012, neutral: 0.0, min: 0.0, max: 0.2, scaled: true)], flags: [], strings: [:]),
        "dotScreen": EffectFilterSpec(params: [EffectFilterParam(name: "width", def: 0.006, neutral: 0.0, min: 0.0, max: 0.1, scaled: true), EffectFilterParam(name: "angle", def: 0.5, neutral: 0.5, min: -7.0, max: 7.0, scaled: false), EffectFilterParam(name: "sharpness", def: 0.7, neutral: 0.7, min: 0.0, max: 1.0, scaled: false)], flags: [], strings: [:]),
        "kaleidoscope": EffectFilterSpec(params: [EffectFilterParam(name: "count", def: 6.0, neutral: 6.0, min: 1.0, max: 24.0, scaled: false), EffectFilterParam(name: "angle", def: 0.0, neutral: 0.0, min: -100.0, max: 100.0, scaled: true)], flags: [], strings: [:]),
        "twirl": EffectFilterSpec(params: [EffectFilterParam(name: "radius", def: 0.45, neutral: 0.45, min: 0.05, max: 1.0, scaled: false), EffectFilterParam(name: "angle", def: 0.0, neutral: 0.0, min: -12.0, max: 12.0, scaled: true)], flags: [], strings: [:]),
        "bump": EffectFilterSpec(params: [EffectFilterParam(name: "radius", def: 0.45, neutral: 0.45, min: 0.05, max: 1.0, scaled: false), EffectFilterParam(name: "scale", def: 0.0, neutral: 0.0, min: -3.0, max: 3.0, scaled: true)], flags: [], strings: [:]),
        "rgbShift": EffectFilterSpec(params: [EffectFilterParam(name: "dx", def: 0.01, neutral: 0.0, min: 0.0, max: 0.1, scaled: true)], flags: ["randomSign"], strings: [:]),
        "tearSlices": EffectFilterSpec(params: [EffectFilterParam(name: "amount", def: 1.0, neutral: 0.0, min: 0.0, max: 3.0, scaled: true)], flags: [], strings: [:]),
        "crossProcess": EffectFilterSpec(params: [], flags: [], strings: [:]),
        "vhs": EffectFilterSpec(params: [EffectFilterParam(name: "amount", def: 1.0, neutral: 0.0, min: 0.0, max: 2.0, scaled: true)], flags: [], strings: [:])
    ]
}
