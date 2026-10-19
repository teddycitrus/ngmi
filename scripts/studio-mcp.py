"""Talk to the Roblox Studio MCP over stdio when it is not loaded as an MCP
server in the current agent (it is configured for Claude Code only).

Run with `python -X utf8 scripts/studio-mcp.py ...`:
  list                                   tool names, descriptions, arguments
  luau <Edit|Server|Client> <file.lua>.. execute_luau with each file's source,
                                         in order, over one connection
  call <tool> '<json args>'              any tool; args may also be @file.json
  call screen_capture '{}' out.png       a trailing .png path saves images

studio_id is filled in automatically: the instance named "not gonna make it",
or the STUDIO_ID environment variable when names are not reported (null).
"""
import base64
import json
import os
import queue
import subprocess
import sys
import threading
import time

BAT = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Roblox", "mcp.bat")
STUDIO_NAME = "not gonna make it"


def main():
    proc = subprocess.Popen(
        ["cmd.exe", "/c", BAT],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        bufsize=0,
    )
    inbox: "queue.Queue[dict]" = queue.Queue()

    def reader():
        for line in proc.stdout:
            line = line.strip()
            if line:
                try:
                    inbox.put(json.loads(line))
                except ValueError:
                    pass

    threading.Thread(target=reader, daemon=True).start()

    def send(obj):
        proc.stdin.write((json.dumps(obj) + "\n").encode())
        proc.stdin.flush()

    next_id = [0]

    def request(method, params, timeout=600):
        next_id[0] += 1
        send({"jsonrpc": "2.0", "id": next_id[0], "method": method, "params": params})
        while True:
            msg = inbox.get(timeout=timeout)
            if msg.get("id") == next_id[0]:
                return msg

    def call(tool, args):
        return request("tools/call", {"name": tool, "arguments": args})

    request("initialize", {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "studio-mcp.py", "version": "1"},
    })
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    if sys.argv[1] == "list":
        for t in request("tools/list", {})["result"]["tools"]:
            print("==", t["name"])
            print(t.get("description", "")[:400])
            print(json.dumps(t.get("inputSchema", {}).get("properties", {}))[:600])
        proc.kill()
        return

    batch = []
    if sys.argv[1] == "luau":
        tool = "execute_luau"
        batch = sys.argv[3:]
        args = {"datamodel_type": sys.argv[2]}
    else:
        tool = sys.argv[2]
        raw = sys.argv[3] if len(sys.argv) > 3 else "{}"
        if raw.startswith("@"):
            raw = open(raw[1:], encoding="utf-8").read()
        args = json.loads(raw)

    # Each run starts a fresh bridge and Studio takes up to ~40 s to reconnect.
    studios = []
    for _ in range(30):
        listing = call("list_roblox_studios", {})["result"]["content"][0]["text"]
        studios = json.loads(listing)["studios"]
        if studios:
            break
        time.sleep(2)
    if os.environ.get("STUDIO_ID") and "studio_id" not in args:
        args["studio_id"] = os.environ["STUDIO_ID"]
    if tool != "list_roblox_studios" and "studio_id" not in args:
        for s in studios:
            if STUDIO_NAME in (s.get("name") or ""):
                args["studio_id"] = s["id"]
                break

    def run(call_args):
        res = call(tool, call_args)
        if "error" in res:
            print("ERROR", json.dumps(res["error"]))
            return
        for c in res["result"].get("content", []):
            if c.get("type") == "text":
                print(c["text"])
            elif c.get("type") == "image":
                out = sys.argv[-1] if sys.argv[-1].endswith(".png") else "shot.png"
                with open(out, "wb") as f:
                    f.write(base64.b64decode(c["data"]))
                print("image saved to", out)

    if batch:
        for path in batch:
            run(dict(args, code=open(path, encoding="utf-8").read()))
    else:
        run(args)
    proc.kill()


main()
