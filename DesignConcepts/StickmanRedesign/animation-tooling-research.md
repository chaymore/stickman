# Stickman Animation Tooling Research

Updated 2026-05-20.

## Short Recommendation

For the refined black-and-white oval Stickman, I should animate him directly in native Swift/AppKit first. The character is simple enough that a procedural renderer gives us the most control with the least new machinery: breathing, blink, eye tracking, leaning, jumping, arm stubs, and hover/listening states can all be authored in code.

If we later want a designer-authored animation system, the best next step is Rive. If we want exportable vector animation files that I can generate or edit with code, the best next step is Lottie.

## What I Can Use Now

Local tools available:

- `swift`: installed, Apple Swift 6.1.2.
- `node`: installed, v25.9.0.
- `npm`: installed.
- `brew`: installed.

Not currently installed:

- `ffmpeg`: needed for convenient video export.
- `magick` / ImageMagick: useful for image post-processing.
- `inkscape`: useful for SVG inspection/conversion.

## Option 1: Native AppKit/Core Animation

This is the best first implementation path.

Apple's Core Animation docs describe layer-based animation as changing layer properties over time, and `CALayer` supports adding `CAAnimation` objects for geometry/content changes. Since Stickman already lives in a custom AppKit `NSView`, I can either keep the current 60 FPS procedural draw loop or split Stickman into `CAShapeLayer` parts and animate transforms/properties.

Why it fits Stickman:

- No runtime dependency.
- Best for interactive states: cursor gaze, click jump, chat-open listening, walking, idle roaming.
- Easy to keep the character at the existing `160 x 160` footprint.
- The refined oval design is just body, eyes, mouth, side stubs, and shadow.

Limitations:

- Animation is code-authored, not timeline-authored.
- Iteration is slower for highly expressive character acting.
- Complex pose libraries would become annoying.

Sources:

- Apple Core Animation Programming Guide: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/index.html
- Apple `CALayer` docs: https://developer.apple.com/documentation/quartzcore/calayer

## Option 2: Rive

Rive is the best candidate if Stickman grows into a real state-machine character. Rive has an Apple runtime, supports Swift Package Manager, and its state machines are designed for interactive animation control. The Apple runtime supports macOS 13.1+ and can be installed with the `rive-ios` Swift package.

Why it fits Stickman:

- Best tool for interactive mascot states.
- Runtime state machines map well to `idle`, `thinking`, `listening`, `happy`, `sleepy`, `walk`, and `reach`.
- Rive files are small and designed for app runtime control.

Practical catch:

- Creating `.riv` files is mainly done in the Rive editor. I can use the web/editor workflow, but I do not currently have a clean command-line path to author polished `.riv` files entirely from code.
- Adding the runtime means changing package dependencies and packaging `.riv` assets.

Sources:

- Rive Apple runtime docs: https://rive.app/docs/runtimes/apple
- Rive state machines: https://rive.app/docs/runtimes/apple/state-machines
- Rive runtimes overview: https://rive.app/runtimes

## Option 3: Lottie / dotLottie

Lottie is the best file-format path if we want portable vector animations. Lottie JSON supports vector shapes, raster assets, masks, expressions, and precompositions. The official `lottie-ios` library supports iOS, macOS, tvOS, and visionOS, and can be added via Swift Package Manager.

Why it fits Stickman:

- I can generate simple Lottie JSON programmatically with Node because the refined Stickman is mostly ellipses and transforms.
- Lottie animations can be looped, resized, reversed, scrubbed, and partially played.
- Good for canned loops: idle, blink, hop, listening pulse.

Limitations:

- Less natural than Rive for interactive state-machine behavior.
- Programmatically writing Lottie is possible, but the format is verbose.
- Real-time cursor-following eye movement would still be easier in native code.

Sources:

- Lottie iOS/macOS runtime: https://github.com/airbnb/lottie-ios
- LottieFiles format docs: https://docs.lottiefiles.com/en/format/lottie-json
- LottieFiles developer portal: https://docs.lottiefiles.com/

## Option 4: Keyshape or LottieFiles Creator

These are good timeline-authoring tools if we want to draw and keyframe animations visually instead of coding them.

Keyshape is a Mac vector animation app with keyframes, easing, SVG export, image sequences, videos, sprite sheets, and limited Lottie plugin support. LottieFiles Creator is a web-based timeline tool for exporting Lottie JSON or dotLottie.

Why they fit:

- Faster visual keyframe iteration.
- Good for preview loops and asset exploration.
- Can export formats that fit app/runtime workflows.

Limitations:

- They are GUI/editor tools, not ideal for fully autonomous code-driven animation.
- Keyshape is a separate Mac app and may require install/trial/purchase.
- Exported Lottie support can have feature limitations, so simple vector shapes are safest.

Sources:

- Keyshape feature/export docs: https://www.keyshapeapp.com/
- Keyshape export docs: https://www.keyshapeapp.com/help/export-and-sharing.html
- LottieFiles docs: https://docs.lottiefiles.com/

## Recommended Animation Plan

1. Implement the refined oval Stickman in native AppKit as procedural parts.
2. Add an explicit animation state enum: `idle`, `hovered`, `jumping`, `walking`, `thinking`, `listening`, `speaking`, `happy`, `sleepy`.
3. Build reusable motion helpers: spring, squash/stretch, blink curve, gaze target, arm reach, shadow reaction.
4. Add a preview/debug mode inside the app or a tiny local preview window so we can tune motion quickly.
5. Re-evaluate Rive only if we want richer timeline-authored poses or designer-editable animation states.

For this design, the practical answer is: I can create the animations myself today in Swift without waiting on external software. Rive and Lottie are worth knowing about, but the current oval Stickman is deliberately simple enough that native animation is the sharpest tool.
