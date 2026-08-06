import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const demosDir = path.join(root, "demos");
const ease = { i: { x: [0.67], y: [1] }, o: { x: [0.33], y: [0] } };

const value = (k) => ({ a: 0, k });
const animated = (keyframes) => ({
  a: 1,
  k: keyframes.map(([t, s], index) =>
    index === keyframes.length - 1 ? { t, s } : { t, s, ...ease }
  ),
});

function transform({
  opacity = value(100),
  rotation = value(0),
  position = value([256, 256, 0]),
  anchor = value([0, 0, 0]),
  scale = value([100, 100, 100]),
} = {}) {
  return { o: opacity, r: rotation, p: position, a: anchor, s: scale };
}

function group(items, name) {
  return {
    ty: "gr",
    nm: name,
    it: [
      ...items,
      {
        ty: "tr",
        p: value([0, 0]),
        a: value([0, 0]),
        s: value([100, 100]),
        r: value(0),
        o: value(100),
      },
    ],
  };
}

function ellipse(size, fill, { position = [0, 0], stroke = null } = {}) {
  const items = [
    { ty: "el", p: value(position), s: value(size) },
    {
      ty: "fl",
      c: typeof fill === "string" ? { sid: fill } : value(fill),
      o: value(100),
    },
  ];
  if (stroke) {
    items.push({
      ty: "st",
      c: value(stroke.color),
      o: value(stroke.opacity ?? 100),
      w: value(stroke.width),
      lc: 2,
      lj: 2,
    });
  }
  return items;
}

function roundedRect(size, radius, fill) {
  return [
    { ty: "rc", p: value([0, 0]), s: value(size), r: value(radius) },
    {
      ty: "fl",
      c: typeof fill === "string" ? { sid: fill } : value(fill),
      o: value(100),
    },
  ];
}

function shapeLayer({ name, index, frames, shapes, layerTransform }) {
  return {
    ddd: 0,
    ind: index,
    ty: 4,
    nm: name,
    sr: 1,
    ks: layerTransform,
    ao: 0,
    shapes,
    ip: 0,
    op: frames,
    st: 0,
    bm: 0,
  };
}

function eyeLayer({ name, index, x, frames, blinkFrames, gazeFrames }) {
  return shapeLayer({
    name,
    index,
    frames,
    layerTransform: transform({
      position: animated(gazeFrames.map(([t, dx, dy]) => [t, [x + dx, 218 + dy, 0]])),
      scale: animated(blinkFrames.map(([t, y]) => [t, [100, y, 100]])),
    }),
    shapes: [
      group(ellipse([40, 70], "eyeColor"), `${name}-group`),
    ],
  });
}

function glintLayer({ name, index, x, frames, blinkFrames, gazeFrames }) {
  return shapeLayer({
    name,
    index,
    frames,
    layerTransform: transform({
      position: animated(gazeFrames.map(([t, dx, dy]) => [t, [x + dx, 218 + dy, 0]])),
      scale: animated(blinkFrames.map(([t, y]) => [t, [100, y, 100]])),
    }),
    shapes: [
      group(ellipse([10, 13], [1, 1, 1, 0.96], { position: [-7, -18] }), `${name}-main`),
      group(ellipse([4, 5], [1, 1, 1, 0.55], { position: [7, -7] }), `${name}-tiny`),
    ],
  });
}

function createStickmanAsset({ frames, mode }) {
  const idle = mode === "idle";
  const blinkFrames = idle
    ? [[0, 100], [68, 100], [72, 8], [76, 100], [222, 100], [226, 8], [230, 100], [300, 100]]
    : [[0, 100], [70, 100], [75, 118], [82, 100], [86, 12], [90, 100], [120, 100]];
  const gazeFrames = idle
    ? [[0, 0, 0], [150, 0, 0], [190, 5, -5], [238, 5, -5], [265, 0, 0], [300, 0, 0]]
    : [[0, 0, 0], [12, 0, 2], [30, 0, -4], [78, 0, -4], [96, 0, 0], [120, 0, 0]];

  const leftArmRotation = idle
    ? animated([[0, [-16]], [90, [-11]], [170, [-16]], [200, [-34]], [240, [-26]], [300, [-16]]])
    : animated([[0, [-16]], [12, [-8]], [30, [72]], [62, [66]], [82, [24]], [100, [-10]], [120, [-16]]]);
  const rightArmRotation = idle
    ? animated([[0, [16]], [110, [21]], [180, [16]], [205, [28]], [245, [19]], [300, [16]]])
    : animated([[0, [16]], [12, [8]], [30, [-72]], [62, [-66]], [82, [-24]], [100, [10]], [120, [16]]]);

  const mouthPosition = idle
    ? animated([[0, [256, 288, 0]], [180, [256, 288, 0]], [205, [260, 286, 0]], [245, [260, 286, 0]], [275, [256, 288, 0]], [300, [256, 288, 0]]])
    : animated([[0, [256, 288, 0]], [12, [256, 290, 0]], [28, [256, 286, 0]], [76, [256, 286, 0]], [92, [256, 290, 0]], [120, [256, 288, 0]]]);
  const mouthScale = idle
    ? animated([[0, [100, 100, 100]], [180, [100, 100, 100]], [205, [35, 125, 100]], [245, [35, 125, 100]], [275, [100, 100, 100]], [300, [100, 100, 100]]])
    : animated([[0, [100, 100, 100]], [12, [75, 80, 100]], [28, [135, 320, 100]], [72, [135, 320, 100]], [92, [110, 135, 100]], [120, [100, 100, 100]]]);

  return {
    id: "stickman",
    w: 512,
    h: 512,
    fr: 60,
    layers: [
      glintLayer({ name: "left-eye-glints", index: 1, x: 218, frames, blinkFrames, gazeFrames }),
      glintLayer({ name: "right-eye-glints", index: 2, x: 294, frames, blinkFrames, gazeFrames }),
      eyeLayer({ name: "left-eye", index: 3, x: 218, frames, blinkFrames, gazeFrames }),
      eyeLayer({ name: "right-eye", index: 4, x: 294, frames, blinkFrames, gazeFrames }),
      shapeLayer({
        name: "mouth",
        index: 5,
        frames,
        layerTransform: transform({ position: mouthPosition, scale: mouthScale }),
        shapes: [
          ...(idle
            ? []
            : [group(ellipse([12, 2], [1, 1, 1, 0.42], { position: [0, 3.5] }), "mouth-shine")]),
          group(
            idle ? roundedRect([28, 7], 4, "eyeColor") : ellipse([28, 10], "eyeColor"),
            "mouth-group"
          ),
        ],
      }),
      shapeLayer({
        name: "body-highlight",
        index: 6,
        frames,
        layerTransform: transform({
          position: value([220, 170, 0]),
          rotation: value(-18),
        }),
        shapes: [group(ellipse([78, 28], [1, 1, 1, 0.34]), "highlight-group")],
      }),
      shapeLayer({
        name: "body",
        index: 7,
        frames,
        layerTransform: transform(),
        shapes: [
          group(
            ellipse([214, 310], "bodyColor", {
              stroke: { color: [0.08, 0.08, 0.08, 1], width: 5, opacity: 90 },
            }),
            "body-group"
          ),
        ],
      }),
      shapeLayer({
        name: "left-stub",
        index: 8,
        frames,
        layerTransform: transform({
          position: value([157, 286, 0]),
          anchor: value([25, 0, 0]),
          rotation: leftArmRotation,
        }),
        shapes: [
          group(
            ellipse([66, 38], "bodyColor", {
              stroke: { color: [0.08, 0.08, 0.08, 1], width: 4, opacity: 72 },
            }),
            "left-stub-group"
          ),
        ],
      }),
      shapeLayer({
        name: "right-stub",
        index: 9,
        frames,
        layerTransform: transform({
          position: value([355, 286, 0]),
          anchor: value([-25, 0, 0]),
          rotation: rightArmRotation,
        }),
        shapes: [
          group(
            ellipse([66, 38], "bodyColor", {
              stroke: { color: [0.08, 0.08, 0.08, 1], width: 4, opacity: 72 },
            }),
            "right-stub-group"
          ),
        ],
      }),
    ],
  };
}

function precompLayer({ frames, mode }) {
  const idle = mode === "idle";
  return {
    ddd: 0,
    ind: 1,
    ty: 0,
    nm: idle ? "Stickman idle and thinking" : "Stickman celebration",
    refId: "stickman",
    w: 512,
    h: 512,
    sr: 1,
    ks: transform({
      position: idle
        ? animated([[0, [256, 260, 0]], [80, [256, 254, 0]], [150, [256, 260, 0]], [190, [256, 255, 0]], [235, [260, 252, 0]], [275, [256, 258, 0]], [300, [256, 260, 0]]])
        : animated([[0, [256, 260, 0]], [12, [256, 272, 0]], [24, [256, 235, 0]], [48, [256, 180, 0]], [66, [256, 208, 0]], [78, [256, 276, 0]], [90, [256, 246, 0]], [104, [256, 263, 0]], [120, [256, 260, 0]]]),
      anchor: value([256, 256, 0]),
      rotation: idle
        ? animated([[0, [0]], [150, [0]], [205, [-4]], [245, [-4]], [280, [1]], [300, [0]]])
        : animated([[0, [0]], [12, [-3]], [32, [4]], [60, [-2]], [78, [0]], [92, [2]], [120, [0]]]),
      scale: idle
        ? animated([[0, [100, 100, 100]], [80, [102, 98, 100]], [150, [100, 100, 100]], [235, [101, 99, 100]], [300, [100, 100, 100]]])
        : animated([[0, [100, 100, 100]], [12, [112, 86, 100]], [24, [91, 114, 100]], [48, [97, 105, 100]], [66, [96, 108, 100]], [78, [118, 80, 100]], [90, [94, 108, 100]], [104, [103, 97, 100]], [120, [100, 100, 100]]]),
    }),
    ao: 0,
    ip: 0,
    op: frames,
    st: 0,
    bm: 0,
  };
}

function shadowLayer({ frames, mode }) {
  const idle = mode === "idle";
  return shapeLayer({
    name: "floor-shadow",
    index: 2,
    frames,
    layerTransform: transform({
      opacity: { sid: "shadowOpacity" },
      position: value([256, 430, 0]),
      scale: idle
        ? animated([[0, [100, 100, 100]], [80, [96, 92, 100]], [150, [100, 100, 100]], [235, [97, 94, 100]], [300, [100, 100, 100]]])
        : animated([[0, [100, 100, 100]], [12, [112, 108, 100]], [32, [70, 55, 100]], [48, [48, 38, 100]], [66, [62, 46, 100]], [78, [120, 112, 100]], [92, [92, 84, 100]], [120, [100, 100, 100]]]),
    }),
    shapes: [group(ellipse([180, 28], [0, 0, 0, 0.18]), "shadow-group")],
  });
}

function createDemo({ name, mode, frames }) {
  return {
    v: "5.7.0",
    fr: 60,
    ip: 0,
    op: frames,
    w: 512,
    h: 512,
    nm: name,
    ddd: 0,
    assets: [createStickmanAsset({ frames, mode })],
    slots: {
      bodyColor: { p: { a: 0, k: [0.94, 0.94, 0.94, 1] } },
      eyeColor: { p: { a: 0, k: [0.02, 0.02, 0.02, 1] } },
      shadowOpacity: { p: { a: 0, k: 70 } },
    },
    layers: [precompLayer({ frames, mode }), shadowLayer({ frames, mode })],
  };
}

const controls = {
  controls: [
    { sid: "bodyColor", label: "Body color" },
    { sid: "eyeColor", label: "Eye color" },
    { sid: "shadowOpacity", label: "Shadow", min: 0, max: 100, step: 1 },
  ],
};

const demos = [
  {
    slug: "stickman-idle-thinking",
    doc: createDemo({ name: "Stickman - Idle Thinking Loop", mode: "idle", frames: 300 }),
  },
  {
    slug: "stickman-celebrate",
    doc: createDemo({ name: "Stickman - Celebration", mode: "celebrate", frames: 120 }),
  },
];

for (const demo of demos) {
  const dir = path.join(demosDir, demo.slug);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "lottie.json"), `${JSON.stringify(demo.doc, null, 2)}\n`);
  fs.writeFileSync(path.join(dir, "controls.json"), `${JSON.stringify(controls, null, 2)}\n`);
}

console.log(`Generated ${demos.length} Stickman demos in ${demosDir}`);
