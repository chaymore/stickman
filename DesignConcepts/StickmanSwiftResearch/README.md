# Stickman Swift Animation Research

Research date: 2026-05-29

Goal: restart Stickman's visual design from the constraints of a native macOS implementation instead of forcing a static character concept into AppKit afterward.

## Big Takeaway

The best public desktop-buddy examples do **not** depend on complex procedural drawing. They work because they have a clear animation format:

- A small named state machine.
- A predictable sprite or pose folder structure.
- Short loops for idle/walk/thinking/sleeping/success.
- A transparent always-on-top macOS window.
- Simple source images that look good at tiny sizes.

For Stickman, this argues for starting with an animation-state spec and a character sheet, not with one procedural `draw(_:)` function. Native Swift can still run it, but the art should be authored as clean reusable poses/frames.

## Reference Gallery

### Clyde on Desk

Source: https://clyde.byebug.cn/ and https://github.com/QingJ01/Clyde

![Clyde idle](./screenshots/clyde-idle.gif)
![Clyde thinking](./screenshots/clyde-thinking.gif)
![Clyde typing](./screenshots/clyde-typing.gif)
![Clyde building](./screenshots/clyde-building.gif)
![Clyde happy](./screenshots/clyde-happy.gif)
![Clyde sleeping](./screenshots/clyde-sleeping.gif)

What matters:

- Clyde's site shows 12 named animation states: idle, thinking, typing, building, juggling, conducting, error, happy, notification, sweeping, carrying, sleeping.
- The pet has a strong silhouette and each state changes the prop/pose, not just the face.
- It reportedly uses lightweight SVG animation states. This is a good direction for Stickman if we keep native Swift as the host but make each state explicit.

Lesson for Stickman:

- Do not rely on one "idle blob" with small expression tweaks.
- Give Stickman a small set of recognizable job states: idle, listening, thinking, speaking, working, success, error, sleepy, dragging/reaching.
- Make the state visually readable from across the screen.

### Rover.app

Source: https://roverthe.dog/ and https://github.com/youngjae99/rover-app

![Rover hero](./screenshots/rover-hero.gif)
![Rover states grid](./screenshots/rover-states-grid.png)
![Rover Open Graph image](./screenshots/rover-og-image.png)

What matters:

- Rover's public page emphasizes "twenty-four animation states."
- The appeal comes from a complete sprite-state library, not from smooth vector interpolation.
- The character is recognizable even when the animation is low-frame and small.

Lesson for Stickman:

- A richer state library beats a prettier single idle drawing.
- If we want emotional range, a sprite/pose sheet is the fastest native-compatible path.

### DockCat

Source: https://auwuua.github.io/DockCat/ and https://github.com/Auwuua/DockCat

![DockCat stretch](./screenshots/dockcat-stretch.jpg)
![DockCat walk](./screenshots/dockcat-walk.jpg)
![DockCat water reminder](./screenshots/dockcat-water-reminder.jpg)

What matters:

- DockCat is a macOS companion app built around pose folders and animation frames.
- It supports resting, walking, transition, held, dialogue, and outing states.
- The repo has a simple `SpriteAnimator` that advances frames with a timer, and a `PoseRenderer` that loads `NSImage`s from asset-pack folders with fallback support.

Implementation clues:

- `SpriteAnimator.start(animation:onFrame:onFinish:)` is only a timer, frame index, loop flag, and callback.
- `PoseRenderer` loads images from directories by pose kind.
- `CatStateMachine` keeps visual state separate from rendering.

Lesson for Stickman:

- This is probably the most directly useful architecture for us.
- Build `StickmanAnimation`, `StickmanPoseRenderer`, and `StickmanStateMachine`.
- Use native AppKit windows, but render image poses/frames instead of drawing every detail by hand.

### mmar/Cat

Source: https://github.com/mmar/Cat

![Cat awake](./screenshots/cat-awake.png)
![Cat walking](./screenshots/cat-walk-right.png)
![Cat sleeping](./screenshots/cat-sleep.png)

What matters:

- This is a classic tiny macOS desktop pet.
- It uses `SpriteKit` and `GameplayKit`.
- The app creates a transparent borderless `NSWindow`, embeds an `SKView`, and animates an `SKSpriteNode` with `SKAction.animate`.
- States are classes like `CatIsMoving`, `CatIsSleeping`, `CatIsStopped`, all coordinated by `GKStateMachine`.
- Sprite atlas frame names encode direction and action: `right1`, `right2`, `sleep1`, `sleep2`, etc.

Lesson for Stickman:

- SpriteKit is viable if we want movement and state loops without reinventing timing.
- The state-machine separation is excellent.
- For Stickman specifically, SpriteKit may be heavier than needed, but `GKStateMachine` plus sprite frames is a strong model.

### Sato

Source: https://www.sato.host/ and https://github.com/vitalune/sato

![Sato demo poster](./screenshots/sato-demo-poster.jpg)
![Sato Max idle](./screenshots/sato-max-idle.gif)
![Sato Sky idle](./screenshots/sato-sky-idle.gif)
![Sato Lexi idle](./screenshots/sato-lexi-idle.gif)
![Sato Rover idle](./screenshots/sato-rover-idle.gif)

What matters:

- Sato uses pixel-art pets as AI desktop companions.
- It has multiple companion identities, each with directional idle sprites.
- The visual style is intentionally low-detail, but the format is scalable: named characters, named directions, named states.

Lesson for Stickman:

- Pixel art is not necessarily the target, but the **format discipline** is useful.
- Stickman could have a style pack in the same spirit: `idle/front`, `idle/side`, `thinking`, `speaking`, `success`, `sleep`.

## Swift/AppKit Animation Options

### Option A: Current Procedural AppKit Drawing

Pros:

- No extra runtime.
- Easy to integrate with existing `StickmanView`.
- Good for eyes following cursor, small squash/stretch, and simple mouth variants.

Cons:

- Visual design quality depends entirely on code drawing.
- It is easy to make accidental ugly shapes.
- Hard to author polished acting poses.

Verdict:

- Keep only for simple overlays or fallback, not for the final Stickman redesign.

### Option B: AppKit Image Pose/Frame Renderer

Pattern:

- Transparent `NSPanel` / `NSWindow`.
- Custom `NSView` draws `NSImage` frames.
- Timer advances frame index.
- State machine selects pose folder / frame loop.

Public reference:

- DockCat.

Pros:

- Very native.
- Easy to implement inside current app.
- Lets us design Stickman visually before coding.
- Supports custom asset packs later.
- Works well with generated assets or hand-edited PNGs.

Cons:

- Needs transparent pose/frame assets.
- Less resolution-independent than vectors.

Verdict:

- Best first restart path for Stickman.

### Option C: SpriteKit + GameplayKit

Pattern:

- Transparent window contains `SKView`.
- `SKSpriteNode` displays frames from `SKTextureAtlas`.
- `SKAction.animate` loops frames.
- `GKStateMachine` handles behavior.

Public reference:

- mmar/Cat.

Pros:

- Designed for sprite animation.
- Built-in atlas/frame timing.
- State-machine support is clean.
- Good if Stickman starts walking, turning, hopping, or reacting physically.

Cons:

- More framework surface than Stickman currently needs.
- May complicate chat-panel integration unless carefully isolated.

Verdict:

- Strong option if we want a real desktop-pet engine.

### Option D: Rive

Source: https://rive.app/docs/runtimes/apple

Pattern:

- Rive editor creates `.riv`.
- Swift Apple runtime loads and controls state machines.

Pros:

- Best modern interactive mascot animation tool.
- State-machine model is exactly what Stickman needs conceptually.
- Great for clean geometric characters with expressive transitions.

Cons:

- Requires editor-authored `.riv` assets.
- Less easy for me to author fully in code.
- Adds dependency and asset packaging.

Verdict:

- Best long-term professional animation route if we want an editor-driven mascot.

### Option E: Lottie / dotLottie

Source: https://github.com/airbnb/lottie-ios and https://docs.lottiefiles.com/en/format/lottie-json

Pattern:

- Vector animation JSON/dotLottie rendered by macOS runtime.

Pros:

- Great for clean vector loops.
- Can be authored in animation tools or generated programmatically.
- Good for idle/listening/success loops.

Cons:

- Less natural for live cursor-following and interactive body logic.
- JSON is verbose and fiddly.

Verdict:

- Good for canned loops, not ideal as the whole Stickman engine.

## What Stickman Should Become

I would stop trying to make the current procedural oval prettier. Instead:

1. Define Stickman as a native animation pack with named states.
2. Render the animation pack in AppKit with `NSImage` frames first.
3. Keep the frame format simple enough to swap in SpriteKit later if needed.
4. Design Stickman's character sheet under these constraints:
   - transparent PNG or vector-derived PNG
   - 160 x 160 canvas
   - strong silhouette
   - 8-12 frames per important loop
   - 1-3 frames for static poses
   - no tiny decorative detail
   - distinct body/action shape per state

Recommended initial states:

- `idle`
- `blink`
- `listen`
- `think`
- `speak`
- `work`
- `success`
- `error`
- `sleep`
- `drag`
- `reach`
- `walk`

## Practical Next Step

Build a small local Stickman animation prototype before touching the installed app again:

- `Resources/StickmanV2/manifest.json`
- `Resources/StickmanV2/idle/*.png`
- `Resources/StickmanV2/think/*.png`
- `Resources/StickmanV2/speak/*.png`
- `Sources/StickmanAnimation.swift`
- `Sources/StickmanPoseRenderer.swift`
- `Sources/StickmanAnimationView.swift`

Then generate or draw a first StickmanV2 frame pack against that format. This keeps design and engineering aligned from frame one.

## Sources

- Clyde on Desk: https://clyde.byebug.cn/
- Clyde GitHub: https://github.com/QingJ01/Clyde
- Rover.app: https://roverthe.dog/
- Rover GitHub: https://github.com/youngjae99/rover-app
- DockCat site: https://auwuua.github.io/DockCat/
- DockCat GitHub: https://github.com/Auwuua/DockCat
- mmar/Cat: https://github.com/mmar/Cat
- Sato: https://www.sato.host/
- Sato GitHub: https://github.com/vitalune/sato
- Rive Apple runtime: https://rive.app/docs/runtimes/apple
- Lottie iOS/macOS: https://github.com/airbnb/lottie-ios
- Lottie JSON format: https://docs.lottiefiles.com/en/format/lottie-json
