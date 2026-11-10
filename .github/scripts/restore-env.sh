#!/usr/bin/env bash
# R573: extracted verbatim from iterate.yml "Restore environment and install bridge".
set -euo pipefail
ENV_SRC="$SESSIONS_DIR/opencode"
mkdir -p "$HOME/.config" "$HOME/.local/share" "$HOME/.opencode"
ENV_TAG="env"

# 1. Restore the WHOLE persisted environment from the release. It is a full
#    package of $HOME (a complete tar, not a delta/overlay), so files the agent
#    put ANYWHERE come back - including files copied or moved with old
#    timestamps, which a "changed-since-the-last-run" scan would silently miss.
#    Exclusions are only reinstallable caches, the work/ tree, the opencode
#    binary, server logs and secrets.
# ROUND 35（降级读取策略）：包可能按「1..N 页 + meta.json」上传（现默认 1500m ⇒ 大包也只占一页），
# 也可能是旧的 90 MiB 多页、甚至无 manifest 的旧包。读侧分三层：
#   ① 页集合按 `sort -V` 定序（`.aa/.ab` 与 `.000/.001` 都能排对）；
#   ② 若有 meta.json，先比对拼接字节数；**不一致就拒绝应用**（半套 $HOME 比不还原本更糟）
#      并给出可操作告警；manifest 缺失/不可解析 ⇒ 退回旧行为（不校验直接解 = 降级）；
#   ③ 压缩格式由**魔数**判定（gzip/xz/zstd/bzip2/未压缩），不再写死 gzip。
# ROUND 44（防数据丢失，关键）：旧版「先删光资产、再上传」的写侧一旦被取消切在中间，
# 就会留下「新卷 + 旧 meta.json」的**撕裂包**；此时旧读侧只告警然后 bootstrap **空环境**
# ⇒ 会话库/桥聊天整体丢失（实测：run 39097256929 被取消 → run 39103651786 读到撕裂包 →
# 空 DB → 会话 ses_eb626522 消失）。现在：主包 'env' 不可用 ⇒ 改从**保险 tag** 'env-safe'
# 还原；两者都不可用才 bootstrap。env-safe 由运营者的 env-backup.sh 维护为「最近一次完好代」。
FALLBACK_TAG="${SESSIONS_FALLBACK_TAG:-env-safe}"
env_try() {
  local tag="$1" dl="/tmp/envdl-$1" vols pages bytes expect hdr tflag
  rm -rf "$dl" && mkdir -p "$dl"
  bash "$GITHUB_WORKSPACE/.github/scripts/fetch-asset.sh" "$SESSIONS_REPO" "$tag" 'env.tar.gz*' "$dl" || return 1
  ls "$dl"/env.tar.gz* >/dev/null 2>&1 || return 1
  gh release download "$tag" --repo "$SESSIONS_REPO" --pattern 'meta.json' --dir "$dl" --clobber >/dev/null 2>&1 || true
  vols=$(ls "$dl"/env.tar.gz* 2>/dev/null | sort -V)
  pages=$(echo "$vols" | wc -l)
  bytes=$(cat $vols 2>/dev/null | wc -c)
  expect=$(jq -r '.env.bytes // empty' "$dl/meta.json" 2>/dev/null || true)
  if [ -n "$expect" ] && [ "$bytes" != "$expect" ]; then
    echo "::warning::$tag package incomplete ($bytes of $expect bytes, $pages page(s)); refusing to apply a partial restore"
    return 1
  fi
  # R2560（D6）：meta 已提供 sha256，旧读侧只比字节数——同长度损坏或换装窗口
  # 的错配代会被当作完好包铺进 $HOME。有 sha 就必须校验；缺失则保持向后兼容。
  expect_sha=$(jq -r '.env.sha256 // empty' "$dl/meta.json" 2>/dev/null || true)
  if [ -n "$expect_sha" ]; then
    got_sha=$(cat $vols 2>/dev/null | sha256sum | cut -d' ' -f1)
    if [ "$got_sha" != "$expect_sha" ]; then
      echo "::warning::$tag package checksum mismatch (got ${got_sha:0:12} expect ${expect_sha:0:12}, $pages page(s)); refusing to apply"
      return 1
    fi
  fi
  hdr=$(head -c 6 "$(echo "$vols" | head -1)" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$hdr" in
    1f8b*)        tflag="-z" ;;
    fd377a585a00) tflag="-J" ;;
    28b52ffd*)    tflag="--zstd" ;;
    425a68*)      tflag="-j" ;;
    *)            tflag="" ;;
  esac
  if cat $vols | tar -xf - -C "$HOME" $tflag 2>/dev/null; then
    echo "environment restored from release '$tag' ($pages page(s), $bytes bytes, tar ${tflag:-plain}${expect:+, size-verified}${expect_sha:+, sha-verified})"
    return 0
  fi
  echo "::warning::$tag package failed to extract (tar ${tflag:-plain}, $bytes bytes)"
  return 1
}
# ROUND 53（取消序列防丢失）：R42 原子换装的窗口（旧代已删、真名新代尚未上传）里，
# release 只剩 stage-* 资产——而那是**已逐个校验过尺寸的当前代**。旧读侧此时会直接
# 退回 env-safe（可能落后数小时 ⇒ 丢最近会话）。新增：真名代不可用时改试 stage 代；
# stage 必须带 stage-meta.json 且字节数完全吻合，半套/无 manifest 的 stage 一律拒绝
# （宁可用旧的 env-safe，也绝不铺半套 $HOME）。
env_try_staged() {
  local tag="$1" dl="/tmp/envdl-$1-staged" vols pages bytes expect hdr tflag
  rm -rf "$dl" && mkdir -p "$dl"
  bash "$GITHUB_WORKSPACE/.github/scripts/fetch-asset.sh" "$SESSIONS_REPO" "$tag" 'stage-env.tar.gz*' "$dl" || return 1
  ls "$dl"/stage-env.tar.gz* >/dev/null 2>&1 || return 1
  gh release download "$tag" --repo "$SESSIONS_REPO" --pattern 'stage-meta.json' --dir "$dl" --clobber >/dev/null 2>&1 || true
  expect=$(jq -r '.env.bytes // empty' "$dl/stage-meta.json" 2>/dev/null || true)
  if [ -z "$expect" ]; then
    echo "::warning::$tag staged generation has no manifest; refusing an unverifiable staged restore"
    return 1
  fi
  vols=$(ls "$dl"/stage-env.tar.gz* 2>/dev/null | sort -V)
  pages=$(echo "$vols" | wc -l)
  bytes=$(cat $vols 2>/dev/null | wc -c)
  if [ "$bytes" != "$expect" ]; then
    echo "::warning::$tag staged generation incomplete ($bytes of $expect bytes, $pages page(s)); refusing"
    return 1
  fi
  # R2560（D6）：stage 代同样校验 sha256（meta 缺失时跳过，保持旧包兼容）。
  expect_sha=$(jq -r '.env.sha256 // empty' "$dl/stage-meta.json" 2>/dev/null || true)
  if [ -n "$expect_sha" ]; then
    got_sha=$(cat $vols 2>/dev/null | sha256sum | cut -d' ' -f1)
    if [ "$got_sha" != "$expect_sha" ]; then
      echo "::warning::$tag staged generation checksum mismatch (got ${got_sha:0:12} expect ${expect_sha:0:12}, $pages page(s)); refusing"
      return 1
    fi
  fi
  hdr=$(head -c 6 "$(echo "$vols" | head -1)" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$hdr" in
    1f8b*)        tflag="-z" ;;
    fd377a585a00) tflag="-J" ;;
    28b52ffd*)    tflag="--zstd" ;;
    425a68*)      tflag="-j" ;;
    *)            tflag="" ;;
  esac
  if cat $vols | tar -xf - -C "$HOME" $tflag 2>/dev/null; then
    echo "environment restored from '$tag' verified staged generation ($pages page(s), $bytes bytes, tar ${tflag:-plain}${expect_sha:+, sha-verified})"
    return 0
  fi
  echo "::warning::$tag staged generation failed to extract ($pages page(s), $bytes bytes)"
  return 1
}
# ROUND 278（运营者「快照优化」— restore 侧）：env-sync 分支是**首选** env 源。
# 运行中插件每 5 分钟 + 保存步 run-end 推终态；校验「克隆/manifest/硬上限
# ENV_SYNC_MAX_AGE_MIN（默认 24h）/db 字节数」全过才应用，并与 release 比新鲜：
# release 的**实际打包时刻**（未携带⇒created_at；携带⇒env.packed_at）若晚于
# 分支 tip 则让位 release；否则取分支（两者中较新者）。任一不满足即整体回落
# 原 release 三层链（env → stage-env → env-safe → bootstrap），语义不变。
ENV_SYNC_MAX_AGE_MIN="${ENV_SYNC_MAX_AGE_MIN:-1440}"
# R2545（token 跨 CI 保存的兜底）：env-sync 分支被拒（release 更新 / 分支过旧）时，
# 分支里仍可能持有 release 包**缺失**的 bot token（典型：某个 release 仍由旧排除集
# 生成，bot5 只在分支上）。这里只补“目标不存在或为空”的文件，绝不覆盖 release
# 已还原的更新 token；注册表只追加缺失的 bot 条目，保留本地已有条目。
BOT_TOKEN_BRANCH=""
bot_token_overlay_from_branch() {
  local d="$1" src base dest added=0
  [ -d "$d/payload" ] || return 0
  mkdir -p "$HOME/.opencode" "$HOME/.config/opencode"
  for src in "$d/payload/.opencode/tg.env" \
             "$d"/payload/.opencode/tg-bot*.env \
             "$d/payload/.config/opencode/tg.env" \
             "$d"/payload/.config/opencode/tg-bot*.env; do
    [ -s "$src" ] || continue
    base=$(basename "$src")
    case "$src" in
      */payload/.opencode/*) dest="$HOME/.opencode/$base" ;;
      *) dest="$HOME/.config/opencode/$base" ;;
    esac
    [ -s "$dest" ] && continue
    cp -pf "$src" "$dest" 2>/dev/null && added=$((added + 1))
  done
  if [ "$added" -gt 0 ] && [ -s "$d/payload/.config/opencode/tg-bots.json" ]; then
    local reg="$HOME/.config/opencode/tg-bots.json"
    [ -s "$reg" ] || printf '{"bots":[]}\n' > "$reg"
    python3 - "$reg" "$d/payload/.config/opencode/tg-bots.json" "$HOME" <<'PY' || true
import json, os, sys
reg, branch, home = sys.argv[1:4]
def load(p):
    try:
        j = json.load(open(p, encoding="utf-8"))
    except Exception:
        return {"bots": []}
    if not isinstance(j, dict):
        return {"bots": []}
    if not isinstance(j.get("bots"), list):
        j["bots"] = []
    return j
cur, br = load(reg), load(branch)
have = {str(b.get("id", "")) for b in cur["bots"] if isinstance(b, dict)}
added = 0
for b in br["bots"]:
    if not isinstance(b, dict):
        continue
    bid = str(b.get("id", ""))
    if not bid or bid in have:
        continue
    base = os.path.basename(str(b.get("envFile", "")))
    if not (base == "tg.env" or (base.startswith("tg-bot") and base.endswith(".env"))):
        continue
    if not (os.path.exists(os.path.join(home, ".config", "opencode", base))
            or os.path.exists(os.path.join(home, ".opencode", base))):
        continue
    cur["bots"].append(b)
    have.add(bid)
    added += 1
if added:
    tmp = reg + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(cur, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.replace(tmp, reg)
    print(f"bot registry merged: +{added} entr(y/ies) from env-sync branch")
PY
    chmod 600 "$reg" 2>/dev/null || true
  fi
  if [ "$added" -gt 0 ]; then
    echo "::notice::rescued $added bot credential file(s) from env-sync branch (release was newer/older)"
  fi
  return 0
}

env_sync_try() {
  local repo="${SESSIONS_REPO:-Xiaobei09/opencode-sessions}"
  local d="/tmp/envsync-restore" json epoch age dbfmt dbexp dbsz sha
  local carried rel_at rel_epoch
  rm -rf "$d" 2>/dev/null
  if ! git clone --depth 1 --single-branch --branch env-sync \
        "https://github.com/$repo.git" "$d" >/dev/null 2>&1; then
    echo "::warning::env-sync branch not available; using release packages"
    return 1
  fi
  sha=$(git -C "$d" rev-parse --short HEAD 2>/dev/null || echo unknown)
  json="$d/env-sync.json"
  if [ ! -s "$json" ] || [ ! -d "$d/payload/.config/opencode" ]; then
    echo "::warning::env-sync payload missing or incomplete; using release packages"
    return 1
  fi
  epoch=$(jq -r '.epoch // empty' "$json" 2>/dev/null || true)
  case "$epoch" in (*[!0-9]*|'') echo "::warning::env-sync manifest epoch invalid; using release packages"; return 1;; esac
  age=$(( ( $(date +%s) - epoch ) / 60 ))
  if [ "$age" -gt "$ENV_SYNC_MAX_AGE_MIN" ]; then
    echo "::warning::env-sync branch too old (${age}min > ${ENV_SYNC_MAX_AGE_MIN}min cap); using release packages"
    # R2545: the branch is stale, but tokens rarely rotate; fill only missing files
    # (applied after the release restore, see the call site below).
    BOT_TOKEN_BRANCH="$d"
    return 1
  fi
  gh release download "$ENV_TAG" --repo "$repo" --pattern 'meta.json' --dir "$d" --clobber >/dev/null 2>&1 || true
  if [ -s "$d/meta.json" ]; then
    carried=$(jq -r '.env.carried // false' "$d/meta.json" 2>/dev/null || echo false)
    if [ "$carried" = "true" ]; then
      rel_at=$(jq -r '.env.packed_at // empty' "$d/meta.json" 2>/dev/null || true)
    else
      rel_at=$(jq -r '.created_at // empty' "$d/meta.json" 2>/dev/null || true)
    fi
    rel_epoch=$(date -u -d "$rel_at" +%s 2>/dev/null || true)
    if [ -n "$rel_epoch" ] && [ "$rel_epoch" -gt "$epoch" ]; then
      echo "::warning::release env (packed ${rel_at}) is newer than the branch tip; using release packages"
      # R2545: don't lose bot creds that only exist on the branch. The overlay is
      # applied AFTER the release restore — doing it here would be overwritten by
      # the release's own tg-bots.json.
      BOT_TOKEN_BRANCH="$d"
      return 1
    fi
  fi
  dbfmt=$(jq -r '.db_format // "raw"' "$json" 2>/dev/null || echo raw)
  dbexp=$(jq -r '.db_bytes // 0' "$json" 2>/dev/null || echo 0)
  case "$dbexp" in (*[!0-9]*) dbexp=0;; esac
  if [ "$dbfmt" = "gzip" ]; then
    if [ ! -f "$d/payload/.local/share/opencode/opencode.db.gz" ]; then
      echo "::warning::env-sync gzip db missing; using release packages"
      return 1
    fi
    if ! gzip -dc "$d/payload/.local/share/opencode/opencode.db.gz" \
          > "$d/payload/.local/share/opencode/opencode.db" 2>/dev/null; then
      echo "::warning::env-sync gzip db decompress failed; using release packages"
      return 1
    fi
    rm -f "$d"/payload/.local/share/opencode/opencode.db.gz 2>/dev/null
    # R579：gzip 形态下若 payload 仍残留旧 chunks（格式切换拍），一并清掉，避免 rsync 进 $HOME
    rm -f "$d"/payload/.local/share/opencode/opencode.db.[0-9][0-9].part 2>/dev/null
  elif [ "$dbfmt" = "chunks" ]; then
    cat "$d"/payload/.local/share/opencode/opencode.db.[0-9][0-9].part \
      > "$d"/payload/.local/share/opencode/opencode.db 2>/dev/null || return 1
    rm -f "$d"/payload/.local/share/opencode/opencode.db.[0-9][0-9].part 2>/dev/null
  fi
  dbsz=$(stat -c%s "$d/payload/.local/share/opencode/opencode.db" 2>/dev/null || echo 0)
  if [ "${dbexp:-0}" -gt 0 ] && [ "$dbsz" != "$dbexp" ]; then
    echo "::warning::env-sync db size mismatch (${dbsz} vs ${dbexp}); using release packages"
    return 1
  fi
  # R2569 (D2): a same-size but corrupt SQLite file must never be applied. The
  # env-sync manifest only carries db_bytes, so a truncated/corrupt branch copy
  # could otherwise replace a healthy local DB and lose the whole session store.
  # quick_check is cheap (measured ~0.04s on 67MB) and rejects before rsync.
  if [ -f "$d/payload/.local/share/opencode/opencode.db" ]; then
    if ! python3 - "$d/payload/.local/share/opencode/opencode.db" <<'PY'
import sqlite3, sys
try:
    c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
    row = c.execute("PRAGMA quick_check").fetchone()
    c.close()
    sys.exit(0 if row and row[0] == "ok" else 1)
except Exception:
    sys.exit(1)
PY
    then
      echo "::warning::env-sync db quick_check failed (corrupt payload); using release packages"
      rm -rf "$d" 2>/dev/null
      return 1
    fi
    echo "env-sync db quick_check ok (${dbsz} bytes)"
  fi
  if ! rsync -a "$d"/payload/ "$HOME"/ 2>/dev/null; then
    echo "::warning::env-sync payload apply failed; using release packages"
    return 1
  fi
  rm -rf "$d" 2>/dev/null
  echo "environment restored from env-sync branch (commit=${sha}, age=${age}min, db=${dbfmt} ${dbsz} bytes)"
  return 0
}
if env_sync_try; then
  echo "environment source: env-sync"
elif env_try "$ENV_TAG"; then
  echo "environment source: $ENV_TAG"
elif env_try_staged "$ENV_TAG"; then
  echo "::warning::primary env was mid-swap; restored the verified staged generation (skipped the stale env-safe)"
elif [ "$FALLBACK_TAG" != "$ENV_TAG" ] && env_try "$FALLBACK_TAG"; then
  echo "::warning::primary env package '$ENV_TAG' unusable; restored the insurance generation '$FALLBACK_TAG'"
else
  echo "no usable environment package; bootstrapping from the repository baseline"
fi

# R2545: token rescue runs AFTER the restore decision. Doing it inside
# env_sync_try would let the release's tg-bots.json overwrite the merged
# registry, silently dropping bots whose token only lived on the branch.
if [ -n "${BOT_TOKEN_BRANCH:-}" ] && [ -d "$BOT_TOKEN_BRANCH/payload" ]; then
  bot_token_overlay_from_branch "$BOT_TOKEN_BRANCH"
  rm -rf "$BOT_TOKEN_BRANCH" 2>/dev/null
fi

# 2. The repository is the clean baseline and stays authoritative for the
#    bridge CODE. Copy it in (except the runtime-state files, which come from
#    the release) so code updates always take effect over a restored env.
#    ROUND 48（真缺陷修复）：跳过表原只列了 5 个文件，其余运行态文件仍被无条件
#    从仓库覆盖到运行态 ⇒ 每轮启动都会用**仓库里那份陈旧状态**盖掉刚从 release
#    还原的**实时状态**（实测：loop-sessions 被盖回 3 会话、漏掉已还原的
#    ses_eb24bf12；inject-card 被盖回旧 session/旧计数；loop-guard 每次被盖回
#    problem:true）。把这些运行态文件一并纳入跳过表，改为「缺失才播种」（见下）。
if [ -d "$ENV_SRC/config" ]; then
  mkdir -p "$HOME/.config/opencode"
  for f in "$ENV_SRC"/config/*; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in
      tg-chats.json|tg-chats-bot*.json|tg-bots.json|loop-ctl.json|loop-marker.json|\
      loop-guard.json|loop-sessions.json|model-windows.json|abort-events.json|\
      inject-card-*.json|botname-*.json|service.json|tg-bot*.env|tg.env|\
      egress-blacklist.json|exit-proxy.json|egress-usage.json) continue ;;
    esac
    cp -a "$f" "$HOME/.config/opencode/" 2>/dev/null || true
  done
fi
# First run only (no release yet): seed runtime state from the repo so the
# existing sessions are not dropped while migrating to release storage.
if [ ! -e "$HOME/.local/share/opencode/opencode.db" ] && [ -d "$ENV_SRC/data" ]; then
  mkdir -p "$HOME/.local/share/opencode"
  cp -a "$ENV_SRC/data/." "$HOME/.local/share/opencode/" 2>/dev/null || true
fi
if [ ! -f "$HOME/.config/opencode/tg-chats.json" ] && [ -f "$ENV_SRC/config/tg-chats.json" ]; then
  cp -a "$ENV_SRC/config/tg-chats.json" "$HOME/.config/opencode/" 2>/dev/null || true
fi
# ROUND 48：运行态文件一律「缺失才播种」（绝不覆盖 release 还原的实时状态）。
for j in loop-ctl.json loop-marker.json service.json \
         loop-guard.json loop-sessions.json model-windows.json \
         abort-events.json botname-sig.json; do
  [ -f "$HOME/.config/opencode/$j" ] || cp -a "$ENV_SRC/config/$j" "$HOME/.config/opencode/" 2>/dev/null || true
done
# Plugin libraries also resolve under ~/.opencode/v2lib.
# ROUND 19：**目标目录必然已存在**（由 env release 还原），此时裸 `cp -a src dst`
# 会把源目录**嵌套**进目标（→ ~/.opencode/v2lib/v2lib），而插件真正加载的
# ~/.opencode/v2lib/*.ts 保持旧内容 → **仓库代码改动在每次重启后都不生效**
# （与"repo 对桥代码权威"的注释相反，实测 mtime 停在旧的 env 还原时间）。
# 改为复制**目录内容**，并清掉历史嵌套产物。
mkdir -p "$HOME/.opencode"
if [ -d "$ENV_SRC/config/v2lib" ]; then
  cp -a "$ENV_SRC/config/v2lib/." "$HOME/.opencode/v2lib/" 2>/dev/null || true
  rm -rf "$HOME/.opencode/v2lib/v2lib" 2>/dev/null || true
fi
# ROUND 63: prove the repo→runtime code sync actually took effect.
# If it silently does not (nested `cp -a`, wrong path, stale extraction),
# the plugin boots the **snapshot's** old code and every repo fix looks
# like it did nothing — a failure mode that costs whole restart cycles
# to diagnose. Compare byte-for-byte and fail loudly instead.
# R2547: also log the success fingerprint. Without it a successful sync is
# invisible in the run log, so "did the new commit actually go live?" still
# needs a manual sha256sum.
sync_checked=0
for d in "$HOME/.config/opencode/v2lib" "$HOME/.opencode/v2lib"; do
  [ -f "$ENV_SRC/config/v2lib/auto-continue.ts" ] || break
  [ -d "$d" ] || continue
  if [ -d "$d/v2lib" ]; then
    echo "::error::nested v2lib copy at $d/v2lib — repo code would not be live"
    exit 1
  fi
  if ! cmp -s "$ENV_SRC/config/v2lib/auto-continue.ts" "$d/auto-continue.ts"; then
    echo "::error::v2lib code sync mismatch at $d/auto-continue.ts (repo != runtime)"
    exit 1
  fi
  if ! cmp -s "$ENV_SRC/config/v2lib/_v2compat.ts" "$d/_v2compat.ts"; then
    echo "::error::v2lib code sync mismatch at $d/_v2compat.ts (repo != runtime)"
    exit 1
  fi
  sync_checked=$((sync_checked + 1))
  echo "v2lib code sync ok: $d/auto-continue.ts matches repo (sha=$(sha256sum "$d/auto-continue.ts" | cut -c1-12))"
done
[ "$sync_checked" -gt 0 ] || echo "::warning::v2lib code sync not verified (source or runtime dir missing)"

if [ ! -d "$HOME/.config/opencode/plugins" ]; then
  echo "::warning::bridge plugins missing; continuing without them"
  exit 0
fi
# 3. Derived registry plus the secret env file, both kept outside the repo.
# R2501 (2026-10-23): **never clobber a restored registry** with the static template.
# The old unconditional `sed template > tg-bots.json` silently dropped every bot
# the operator had added (bot3/bot4) on every boot; after the 2026-10-21 factory
# reset that is exactly why bot4 received no updates. Seed only when missing, then
# merge the bots whose tokens this run received below.
REG="$HOME/.config/opencode/tg-bots.json"
if [ ! -s "$REG" ] && [ -f "$ENV_SRC/templates/tg-bots.json" ]; then
  sed "s#__HOME__#$HOME#g" "$ENV_SRC/templates/tg-bots.json" > "$REG"
fi
if [ ! -s "$REG" ]; then printf '{"bots":[{"id":"primary","label":"CI","envFile":"%s/.opencode/tg.env"}]}\n' "$HOME" > "$REG"; fi
chmod 600 "$REG" 2>/dev/null || true
if [ -n "${TG_BOT_TOKEN:-}" ]; then
  : > "$HOME/.opencode/tg.env"
  printf 'TG_BOT_TOKEN=%s\n' "$TG_BOT_TOKEN" >> "$HOME/.opencode/tg.env"
  if [ -n "${TG_ALLOWED_CHAT:-}" ]; then printf 'TG_ALLOWED_CHAT=%s\n' "$TG_ALLOWED_CHAT" >> "$HOME/.opencode/tg.env"; fi
  if [ -n "${TG_PUSH_CHAT:-}" ]; then printf 'TG_PUSH_CHAT=%s\n' "$TG_PUSH_CHAT" >> "$HOME/.opencode/tg.env"; fi
else
  # R2543：token 应跨 CI 保存。本轮若没有 secret，保留环境包恢复出来的
  # tg.env（旧行为会 `: >` 清空 token，主 Bot 直接失联）。
  [ -f "$HOME/.opencode/tg.env" ] || : > "$HOME/.opencode/tg.env"
  if [ ! -s "$HOME/.opencode/tg.env" ]; then
    echo "::warning::TG_BOT_TOKEN missing and no restored primary tg.env; primary bot will run without a token"
  fi
fi
chmod 600 "$HOME/.opencode/tg.env"
# bot env files + registry merge (2026-10-23): add bots **without touching code**.
# Sources, in order:
#   • TG_BOT3_TOKEN / TG_BOT4_TOKEN (legacy secrets, kept working)
#   • TG_BOTS_EXTRA: one JSON secret with an array of {id,label,token,allowedChat?,pushChat?}
#     — add/rotate any number of bots in one place.
#   • any pre-existing tg-bot<id>.env file (restored from the environment snapshot)
# Every token is written to a 0600 env file (R2543: now included in private
# environment packages so tokens survive across CI runs), then the registry
# is merged atomically instead of being overwritten. Entry discovery in the bridge entry
# additionally picks up tg-bot*.env files, so a single dropped file is enough.
export TG_BOTS_EXTRA="${TG_BOTS_EXTRA:-}"
python3 - <<'PY'
import json, os, re, tempfile

home = os.path.expanduser("~")
reg_path = f"{home}/.config/opencode/tg-bots.json"
allowed = os.environ.get("TG_ALLOWED_CHAT", "")
push = os.environ.get("TG_PUSH_CHAT", "")

def read_json(p, default):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default

data = read_json(reg_path, {"bots": []})
if isinstance(data, list):
    data = {"bots": data}
bots = [b for b in data.get("bots", []) if isinstance(b, dict) and str(b.get("id", "")).strip()]
by = {str(b["id"]).lower(): b for b in bots}

def put(bot):
    bid = re.sub(r"[^a-z0-9_-]", "", str(bot.get("id", "")).lower())
    if not bid or len(bid) > 24:
        return
    bot["id"] = bid
    # R2549（D4）：**合并**而非整条替换。旧实现 `by[bid] = bot` 会把恢复/早先写入的
    # `queueCardOwner: false` 丢掉；判据侧缺字段默认 True（见 tg-bridge registerBot），
    # 于是 bot3/bot4 token 一旦有效，两个 Bot 都会建队列置顶卡 → 同一聊天两条卡互相 400。
    # 保留既有字段，仅用本次显式提供的字段覆盖。
    merged = dict(by.get(bid) or {})
    merged.update(bot)
    # 防御：注册表是索引，不是凭据库；旧版本若误把 token 写进来，合并时清掉。
    merged.pop("token", None)
    # 非主 Bot 默认不拥有队列卡；显式值优先（TG_BOTS_EXTRA 可传 queueCardOwner）。
    if bid != "primary" and "queueCardOwner" not in merged:
        merged["queueCardOwner"] = False
    by[bid] = merged

def write_env(path, token, allowed_chat, push_chat, label=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(f"TG_BOT_TOKEN={token}\n")
        f.write(f"TG_ALLOWED_CHAT={allowed_chat}\n")
        f.write(f"TG_PUSH_CHAT={push_chat}\n")
        if label:
            f.write(f"TG_BOT_LABEL={label}\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)

put({"id": "primary", "label": by.get("primary", {}).get("label", "CI"), "envFile": f"{home}/.opencode/tg.env"})

for n in ("3", "4"):
    tok = os.environ.get(f"TG_BOT{n}_TOKEN", "").strip()
    bid = f"bot{n}"
    envp = f"{home}/.config/opencode/tg-bot{n}.env"
    if tok:
        label = str(by.get(bid, {}).get("label") or bid)
        write_env(envp, tok, allowed, push, label)
        put({"id": bid, "label": label, "envFile": envp, "noFallback": True})
        print(f"bot{n} secret env written")
    elif os.path.isfile(envp):
        print(f"bot{n} env present (no CI secret this run)")
    else:
        print(f"::warning::TG_BOT{n}_TOKEN missing; bot{n} will run without a token")
        by.pop(bid, None)

raw = os.environ.get("TG_BOTS_EXTRA", "").strip()
if raw:
    try:
        j = json.loads(raw)
        extras = j.get("bots", []) if isinstance(j, dict) else j
        if not isinstance(extras, list):
            raise ValueError("expected a JSON array or {bots:[...]}")
    except Exception as e:
        extras = []
        print(f"::warning::TG_BOTS_EXTRA ignored (invalid JSON): {e}")
    for item in extras:
        if not isinstance(item, dict) or not str(item.get("token", "")).strip():
            print("::warning::TG_BOTS_EXTRA entry skipped (missing id/token)")
            continue
        bid = re.sub(r"[^a-z0-9_-]", "", str(item.get("id", "")).lower())
        if not bid:
            print("::warning::TG_BOTS_EXTRA entry skipped (invalid id)")
            continue
        file_id = bid[3:] if bid.startswith("bot") and len(bid) > 3 else bid
        envp = os.path.expanduser(item.get("envFile") or f"{home}/.config/opencode/tg-bot{file_id}.env")
        label = str(item.get("label") or bid)
        write_env(envp, str(item["token"]).strip(), str(item.get("allowedChat") or allowed), str(item.get("pushChat") or push), label)
        entry = {"id": bid, "label": label, "envFile": envp, "noFallback": True}
        # R2549：允许一次性接入多个 Bot 时显式指定队列卡归属；缺省由 put() 设为 False。
        if isinstance(item.get("queueCardOwner"), bool):
            entry["queueCardOwner"] = item["queueCardOwner"]
        put(entry)
        print(f"bot {bid} secret env written (TG_BOTS_EXTRA)")


# Pre-existing tg-bot*.env files (restored snapshot) join the registry automatically.
for d in (f"{home}/.config/opencode", f"{home}/.opencode"):
    try:
        names = sorted(os.listdir(d))
    except OSError:
        continue
    for n in names:
        m = re.match(r"^tg-bot([a-z0-9_-]{1,24})\.env$", n, re.I)
        if not m:
            continue
        sfx = m.group(1).lower()
        bid = sfx if sfx.startswith("bot") else f"bot{sfx}"
        if bid in by:
            continue
        envp = f"{d}/{n}"
        ok, label = False, bid
        try:
            for line in open(envp, encoding="utf-8"):
                if line.startswith("TG_BOT_TOKEN=") and line.split("=", 1)[1].strip():
                    ok = True
                if line.startswith("TG_BOT_LABEL=") and line.split("=", 1)[1].strip():
                    label = line.split("=", 1)[1].strip()
        except OSError:
            continue
        if ok:
            try:
                os.chmod(envp, 0o600)
            except OSError:
                pass
            put({"id": bid, "label": label, "envFile": envp, "noFallback": True})

# Drop entries whose env file vanished: a registered-but-tokenless bot just logs
# MISSING every boot and never answers (the recurring bot4 complaint).
keep = {}
for bid, b in by.items():
    p = b.get("envFile")
    if bid == "primary" or not p:
        keep[bid] = b
        continue
    try:
        txt = open(os.path.expanduser(p), encoding="utf-8").read()
    except OSError:
        print(f"bot registry: drop {bid} (env file missing: {p})")
        continue
    if "TG_BOT_TOKEN=" not in txt:
        print(f"bot registry: drop {bid} (no token in env file)")
        continue
    keep[bid] = b

# Same token must never be polled by two bots: Telegram returns 409 for both and
# the later one silently receives nothing (bot4 symptom on 2026-10-23: the
# TG_BOT3_TOKEN and TG_BOT4_TOKEN secrets hold the same value).
import hashlib
seen_tok = {}
dedup = {}
for bid, b in keep.items():
    p = b.get("envFile")
    tok = ""
    if p:
        try:
            for line in open(os.path.expanduser(p), encoding="utf-8"):
                if line.startswith("TG_BOT_TOKEN="):
                    tok = line.split("=", 1)[1].strip()
                    break
        except OSError:
            tok = ""
    if tok:
        h = hashlib.sha256(tok.encode()).hexdigest()
        if h in seen_tok:
            print(f"::warning::bot registry: drop {bid} (duplicate token of {seen_tok[h]}; set a distinct token secret)")
            continue
        seen_tok[h] = bid
    dedup[bid] = b
keep = dedup

out = {"bots": list(keep.values())}
fd, tmp = tempfile.mkstemp(prefix=".tg-bots.", dir=os.path.dirname(reg_path), text=True)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, reg_path)
print(f"bot registry: {len(keep)} bot(s) -> {', '.join(keep)}")
PY
# Web search without an interactive prompt: CI sessions have no one to answer
# "choose a provider" (every search was cancelled with 'Web search cancelled').
# Exa is a public MCP endpoint and works without a key; pin it globally.
CFGJSON="$HOME/.config/opencode/opencode.json"
if [ ! -s "$CFGJSON" ]; then
  printf '{"$schema":"https://opencode.ai/config.json","websearch":{"provider":"exa"}}\n' > "$CFGJSON"
fi
if command -v jq >/dev/null 2>&1; then
  tmp=$(mktemp)
  jq '.websearch = ((.websearch // {}) + {provider: ((.websearch.provider) // "exa")})' "$CFGJSON" > "$tmp" 2>/dev/null && mv "$tmp" "$CFGJSON" || rm -f "$tmp"
fi
chmod 600 "$CFGJSON" 2>/dev/null || true
# R648：tar 不保留空目录，snapshot gitdir 的 refs/ 会在跨 run 还原时丢失；
# 随后 native snapshot 把 gitdir 判成 unreadable，产生 rebuilding/failed capture 风暴。
# 只给看起来像 gitdir 的二级目录补 refs/，不动对象/索引。
snap_root="$HOME/.local/share/opencode/snapshot"
if [ -d "$snap_root" ]; then
  find "$snap_root" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | while IFS= read -r d; do
    if [ -f "$d/HEAD" ] && [ -d "$d/objects" ]; then
      mkdir -p "$d/refs"
    fi
  done
fi
