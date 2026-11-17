#!/usr/bin/env bash
# R2763（运营者：「继续」后确认执行）— pin native snapshot objects.
#
# 背景：~/.local/share/opencode/snapshot/<project>/<worktree>/ 是 native
# snapshot 的 gitdir。会话消息里的 snapshot.start/end 记录的是 **tree** 哈希
# （git write-tree 的结果，不是 commit），而 gitdir 的 refs/ 通常是空的（跨
# run 还原后只剩 objects）。没有 ref 指向的 tree 不可达，一旦 opencode/宿主对
# 该 gitdir 跑 `git gc`，文件历史就会被剪掉（实测：当前仓库 518 个引用对象中
# 21 个已缺失）。
#
# 本脚本只做一件事：把 DB 里仍然被引用的 tree（以及历史版本可能出现的 commit）
# 挂到 refs/opencode/<hash>，让它们及其子对象可达。git 允许 ref 直接指向 tree，
# gc 会按普通可达性保留。只增 ref，不删对象、不改工作区、不碰 opencode 自己
# 的 ref。重复运行是幂等的；对象已缺失的 hash 直接跳过。任何失败都只告警，
# 不影响启动。
set -uo pipefail
SNAP_ROOT="${SNAP_ROOT:-$HOME/.local/share/opencode/snapshot}"
DB="${DB:-$HOME/.local/share/opencode/opencode.db}"
[ -d "$SNAP_ROOT" ] || exit 0
[ -s "$DB" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
SNAP_ROOT="$SNAP_ROOT" DB="$DB" python3 - <<'PY'
import json
import os
import sqlite3
import subprocess
import sys

root = os.environ["SNAP_ROOT"]
db = os.environ["DB"]

try:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    rows = con.execute(
        "select data from session_message where data like '%\"snapshot\"%'"
    ).fetchall()
except Exception as exc:  # noqa: BLE001 - restore must never fail because of this helper
    print(f"::warning::snapshot pins: DB read failed: {exc}")
    sys.exit(0)
finally:
    try:
        con.close()
    except Exception:  # noqa: BLE001
        pass

hashes = set()
for (data,) in rows:
    try:
        msg = json.loads(data)
    except Exception:  # noqa: BLE001 - malformed historical row
        continue
    snap = msg.get("snapshot") or {}
    for key in ("start", "end"):
        value = snap.get(key)
        if isinstance(value, str):
            low = value.lower()
            if len(low) == 40 and all(ch in "0123456789abcdef" for ch in low):
                hashes.add(low)
if not hashes:
    sys.exit(0)
ordered = sorted(hashes)

gitdirs = []
for project in sorted(os.listdir(root)):
    pdir = os.path.join(root, project)
    if not os.path.isdir(pdir):
        continue
    for worktree in sorted(os.listdir(pdir)):
        gdir = os.path.join(pdir, worktree)
        if os.path.isdir(os.path.join(gdir, "objects")) and os.path.isfile(os.path.join(gdir, "HEAD")):
            gitdirs.append(gdir)

pinned = 0
for gdir in gitdirs:
    try:
        probe = subprocess.run(
            ["git", "--git-dir", gdir, "cat-file", "--batch-check=%(objectname) %(objecttype)"],
            input="\n".join(ordered) + "\n",
            capture_output=True,
            text=True,
            timeout=120,
        )
    except Exception as exc:  # noqa: BLE001
        print(f"::warning::snapshot pins: {gdir}: cat-file failed: {exc}")
        continue
    if probe.returncode != 0:
        print(f"::warning::snapshot pins: {gdir}: cat-file rc={probe.returncode}: {probe.stderr.strip()[:200]}")
        continue
    present = []
    for line in probe.stdout.splitlines():
        parts = line.split()
        # native snapshot 的值是 tree；兼容早期/未来可能写入的 commit。
        if len(parts) == 2 and parts[1] in ("tree", "commit"):
            present.append(parts[0])
    if not present:
        continue
    # git update-ref --stdin: one `update <ref> <new>` per reachable snapshot.
    updates = "".join(f"update refs/opencode/{h} {h}\n" for h in present)
    try:
        run = subprocess.run(
            ["git", "--git-dir", gdir, "update-ref", "--stdin"],
            input=updates,
            capture_output=True,
            text=True,
            timeout=120,
        )
    except Exception as exc:  # noqa: BLE001
        print(f"::warning::snapshot pins: {gdir}: update-ref failed: {exc}")
        continue
    if run.returncode != 0:
        print(f"::warning::snapshot pins: {gdir}: update-ref rc={run.returncode}: {run.stderr.strip()[:200]}")
        continue
    pinned += len(present)
    label = os.path.relpath(gdir, root)
    print(f"snapshot pins: {label} += {len(present)} ref(s)")
print(f"snapshot pins: {pinned} ref(s) across {len(gitdirs)} gitdir(s), {len(ordered)} referenced object(s)")
PY
