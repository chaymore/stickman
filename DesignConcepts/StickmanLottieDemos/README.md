# Stickman Lottie Demos

Local Skottie preview harness adapted from
[`diffusionstudio/lottie`](https://github.com/diffusionstudio/lottie).

```bash
npm install
npm run generate:demos
npm run demo -- stickman-idle-thinking
npm run dev
```

Available demos:

- `stickman-idle-thinking`: five-second ambient loop with breathing, blinks, gaze,
  and a thinking beat.
- `stickman-celebrate`: two-second squash-and-stretch jump with raised stubs and a
  clean settle.

Switch demos while the server is running:

```bash
npm run demo -- stickman-celebrate
```

Inspect exact frames with `?frame=48&paused=1`. Editable body, eye, and shadow
controls appear in the properties panel.
