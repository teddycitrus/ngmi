"""Push src/server, src/client and src/shared into the open Studio place when
the Rojo plugin is not connected (for example after Studio reopens a place from
AutoRecovery). Mirrors the default.project.json mapping for scripts only:
creates missing Folders and scripts and rewrites Source where it differs. It
never deletes instances.

Run from the repo root: `python -X utf8 scripts/sync-to-studio.py`
(STUDIO_ID is honoured, as in studio-mcp.py). Must be run in Edit mode.
"""
import json
import os
import subprocess
import sys
import tempfile

ROOTS = {
    "src/server": ["ServerScriptService", "Server"],
    "src/client": ["StarterPlayer", "StarterPlayerScripts", "Client"],
    "src/shared": ["ReplicatedStorage", "Shared"],
}
CHUNK_BYTES = 150_000

LUA_HEAD = """
local HttpService = game:GetService("HttpService")
local entries = HttpService:JSONDecode(%s)
local changed = {}
for _, e in entries do
    local node: Instance = game:GetService(e.path[1])
    for i = 2, #e.path do
        local isLast = i == #e.path
        local child = node:FindFirstChild(e.path[i])
        local want = isLast and e.class or "Folder"
        if child and isLast and not child:IsA(want) then
            child.Name = child.Name .. "_stale"
            child = nil
        end
        if not child then
            child = Instance.new(want)
            child.Name = e.path[i]
            child.Parent = node
            table.insert(changed, "+" .. table.concat(e.path, "."))
        end
        node = child
    end
    local s = node :: any
    if s.Source ~= e.source then
        s.Source = e.source
        table.insert(changed, table.concat(e.path, "."))
    end
end
return #changed .. " changed: " .. table.concat(changed, ", ")
"""


def entries():
    for root, prefix in ROOTS.items():
        for dirpath, _, files in os.walk(root):
            rel = os.path.relpath(dirpath, root)
            parts = [] if rel == "." else rel.replace("\\", "/").split("/")
            for f in sorted(files):
                if not f.endswith(".luau"):
                    continue
                if f.endswith(".server.luau"):
                    name, cls = f[: -len(".server.luau")], "Script"
                elif f.endswith(".client.luau"):
                    name, cls = f[: -len(".client.luau")], "LocalScript"
                else:
                    name, cls = f[: -len(".luau")], "ModuleScript"
                # Raw newlines: Rojo syncs files byte for byte (CRLF included).
                with open(os.path.join(dirpath, f), encoding="utf-8", newline="") as fh:
                    source = fh.read()
                yield {"path": prefix + parts + [name], "class": cls, "source": source}


def main():
    chunks, cur, size = [], [], 0
    for e in entries():
        cur.append(e)
        size += len(e["source"])
        if size > CHUNK_BYTES:
            chunks.append(cur)
            cur, size = [], 0
    if cur:
        chunks.append(cur)

    tmp = tempfile.mkdtemp()
    paths = []
    for i, chunk in enumerate(chunks):
        p = os.path.join(tmp, f"sync{i}.lua")
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(LUA_HEAD % json.dumps(json.dumps(chunk)))
        paths.append(p)
    here = os.path.dirname(os.path.abspath(__file__))
    subprocess.run([sys.executable, "-X", "utf8", os.path.join(here, "studio-mcp.py"), "luau", "Edit", *paths], check=True)


main()
