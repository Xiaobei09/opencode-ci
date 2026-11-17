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
#
# R2764（启动时序）：restore-env 与 restore-targets 是**并行**的，探测时快照
# gitdir 的 objects/info/alternates 可能指向还没还原出来的工作区 .git/objects。
# git 遇到 broken alternate 会直接 fatal，整库一个对象都 probe 不到。因此：
#   · 探测用临时拼的 gitdir，只软链快照自己的 objects（跳过 info/ ⇒ 不读
#     alternates），快照对象本来就在自己的 pack/loose 里；
#   · ref 直接原子写入 refs/opencode/<hash>（update-ref 同样会加载 alternates，
#     启动时序下会失败），这是本脚本独占的命名空间，格式与 git 完全一致。
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
import shutil
import sqlite3
import subprocess
import sys
import tempfile

root = os.environ["SNAP_ROOT"]
db = os.environ["DB"]

try:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=10)
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
    # R2764（启动时序）：restore-env 与 restore-targets 并行，探测时工作区的
    # .git/objects 可能还不存在，而快照 gitdir 的 objects/info/alternates 正
    # 指向它。broken alternate 会让 `git --git-dir=<gdir> cat-file` 整库报错
    # （fatal: Invalid path），一个对象都 pin 不上。这里临时拼一个**只含
    # 自身 objects** 的 gitdir（info/ 跳过 ⇒ 不读 alternates）来探测；快照
    # 对象本来就在自己的 pack/loose 里。
    probe_dir = tempfile.mkdtemp(prefix="snapshot-pin-")
    try:
        obj_dir = os.path.join(probe_dir, "objects")
        os.makedirs(obj_dir)
        os.makedirs(os.path.join(probe_dir, "refs"))
        # Git requires HEAD/refs/objects to treat --git-dir as a repository;
        # refs themselves are not needed for cat-file.
        with open(os.path.join(probe_dir, "HEAD"), "w", encoding="ascii") as fh:
            fh.write("ref: refs/heads/master\n")
        own = os.path.join(gdir, "objects")
        for entry in os.listdir(own):
            if entry == "info":
                continue
            os.symlink(os.path.join(own, entry), os.path.join(obj_dir, entry))
        probe = subprocess.run(
            ["git", "--git-dir", probe_dir, "cat-file", "--batch-check=%(objectname) %(objecttype)"],
            input="\n".join(ordered) + "\n",
            capture_output=True,
            text=True,
            timeout=120,
        )
    except Exception as exc:  # noqa: BLE001
        print(f"::warning::snapshot pins: {gdir}: cat-file failed: {exc}")
        continue
    finally:
        shutil.rmtree(probe_dir, ignore_errors=True)
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
    # 直接原子写 refs/opencode/<hash>：update-ref 也会加载 alternates，同样会
    # 在启动时序下失败。refs/opencode 是本脚本独占的命名空间，写 loose ref
    # 与 git 自身格式一致；gc/pack-refs 之后仍按普通可达性保留。
    ref_dir = os.path.join(gdir, "refs", "opencode")
    try:
        os.makedirs(ref_dir, exist_ok=True)
        for h in present:
            ref = os.path.join(ref_dir, h)
            content = h + "\n"
            try:
                with open(ref, "r", encoding="ascii") as fh:
                    if fh.read() == content:
                        continue
            except OSError:
                pass
            tmp_ref = ref + f".tmp{os.getpid()}"
            with open(tmp_ref, "w", encoding="ascii") as fh:
                fh.write(content)
            os.replace(tmp_ref, ref)
    except Exception as exc:  # noqa: BLE001
        print(f"::warning::snapshot pins: {gdir}: write refs failed: {exc}")
        continue
    pinned += len(present)
    label = os.path.relpath(gdir, root)
    print(f"snapshot pins: {label} += {len(present)} ref(s)")
print(f"snapshot pins: {pinned} ref(s) across {len(gitdirs)} gitdir(s), {len(ordered)} referenced object(s)")
PY
