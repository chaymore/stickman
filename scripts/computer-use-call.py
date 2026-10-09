#!/usr/bin/env python3
"""Calls one Stickman computer-use tool through the bundled MCP relay, the same path Claude Code uses.

Usage: scripts/computer-use-call.py get_app_state '{"app": "TextEdit"}'
Screenshots are saved under $CU_SHOTS (default $TMPDIR/stickman-cu-shots).
"""
import sys, json, subprocess, base64, time, os
S = os.environ.get("CU_SHOTS", os.path.join(os.environ.get("TMPDIR", "/tmp"), "stickman-cu-shots"))
os.makedirs(S, exist_ok=True)
tool = sys.argv[1]; args = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
p = subprocess.Popen(["/Applications/Stickman.app/Contents/MacOS/stickman-computer-use"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
msgs = [{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}},
        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":tool,"arguments":args}}]
t0 = time.time()
out, _ = p.communicate("\n".join(json.dumps(m) for m in msgs) + "\n", timeout=320)
for line in out.splitlines():
    m = json.loads(line)
    if m.get("id") != 2: continue
    r = m["result"]
    print(f"[{tool}] isError={r.get('isError')} {time.time()-t0:.2f}s")
    for c in r["content"]:
        if c["type"] == "text": print(c["text"][:int(os.environ.get("MAXC", "6000"))])
        else:
            n = len([f for f in os.listdir(S) if f.startswith("shot_")])
            path = f"{S}/shot_{n}.jpg"; open(path, "wb").write(base64.b64decode(c["data"]))
            print(f"(image saved {path}, {len(c['data'])//1024} KB base64)")
