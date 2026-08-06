# Stickman Clawd-Style Preview

Generated preview for the native AppKit mascot renderer.

Run:

```sh
./stickman --render-avatar-preview DesignConcepts/StickmanPreview/avatar-states.png
./stickman --render-avatar-animation-preview DesignConcepts/StickmanPreview/avatar-states.gif
./stickman --render-window-preview DesignConcepts/StickmanPreview/window-preview.png
./stickman --render-reference-comparison DesignConcepts/StickmanPreview/reference-comparison.png
./stickman --check-preview-artifacts
```

The previews render the same `StickmanView` used by the installed app. In both
artifacts, each row is a mascot state, and each column samples a different time
in that state's loop. The GIF animates those samples forward so timing, bobbing,
blinks, and state-specific accents can be checked without launching the desktop
window. The window preview renders the chat and settings panels offscreen to
check the Anthropic-inspired colors, surfaces, and controls. The QA command
verifies that the generated avatar, animation, window, and reference-comparison
artifacts exist, are decodable, have the expected dimensions, and that the
animated GIF has the expected frame count.
The reference comparison uses the saved public Sticker Mule artwork at
`references/clawd-sticker-reference.png` as a side-by-side visual target for
Stickman's neutral native render.

## States

- `idle`: quiet breathing, blink, low visual activity.
- `listening`: small lift, subtle side pulse.
- `thinking`: slight lean with restrained thought dots.
- `walking`: bob, tilt, and foot-shadow accents.
- `reaching`: lean with one side tab extended.
- `happy`: short hop and smiling pixel eyes.
- `speaking`: small mouth pulse with restrained body movement.
- `working`: tiny terminal cursor cue.
- `error`: brief shake with an exclamation accent.
- `sleeping`: lowered eyelids, slow drift, very low motion.

## Clawd Reference Traits

The native renderer is tuned against public Claude Code mascot references:

- Warm clay-orange pixel body.
- Flat rectangular top and simple block silhouette.
- One square side tab on each side.
- Four short rectangular legs with clean negative space between them.
- Two black square or slightly vertical eyes.
- No default mouth, eyebrows, accessories, or glossy rendering.
- State accents should be temporary and small enough not to change the base
  mascot identity.

Reference sources:

- Anthropic Claude Code product page: https://claude.com/product/claude-code
- Anthropic Claude Code terminal UX article: https://www.anthropic.com/news/enabling-claude-code-to-work-more-autonomously
- Sticker Mule Clawd reference: https://www.stickermule.com/claudecode/item/19156131
- Community Clawd image references from X and fan posts captured during web/image search.

## Review Notes

The sheet should be judged at the rendered size, not zoomed in. The goal is a
Claude Code mascot-inspired desktop companion that reads clearly, stays friendly,
and avoids constant attention-grabbing motion.

## Ambient Behavior

Stickman should not randomly jump or roam around the screen. While collapsed, he may
occasionally perform a quiet in-place personality beat every 75 to 150 seconds:
a thoughtful glance, a brief listening pose, a tiny reach toward the cursor, or
a short celebration. Automatic personality should never relocate the window;
movement is reserved for explicit interactions such as right-click navigation.
