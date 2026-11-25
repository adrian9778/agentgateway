#!/usr/bin/env bash
set -euo pipefail

# ── 可配置项(按项目改这里) ──────────────────────────────────────
MAIN_REMOTE="${MAIN_REMOTE:-origin}"                # fork remote 名
MAIN_BRANCH="${MAIN_BRANCH:-main}"                  # fork 主分支(被 GitHub 远程同步)
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"          # 上游分支(GitHub 会把 upstream/<此分支> 合进 MAIN_BRANCH)
DOCS_BRANCH="${DOCS_BRANCH:-adrian}"                # 工作分支(只在这条分支上做对齐)
SYNC_MODE="${SYNC_MODE:-merge}"                     # merge(默认) | rebase
# ──────────────────────────────────────────────────────────────
# main 的同步走 GitHub「Sync fork」API(远程完成, 本地不拉 upstream);
# 工作分支仍需本地对齐(merge/rebase, GitHub 无对应功能): merge 原提交 SHA 不变、
# 普通推送; rebase 历史线性、需强推。两种都不丢独有提交。无论起步在哪个分支, 结束都停在工作分支。

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log()  { printf '\033[1;34m[sync-remote]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[sync-remote]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[sync-remote]\033[0m %s\n' "$*" >&2; exit 1; }

run() { if (( DRY_RUN )); then log "(dry-run) $*"; else log "$*"; "$@"; fi; }

cd_to_git_root() {
  local toplevel
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || die "不在 git 仓库里"
  cd "$toplevel"
}

# 从 fork remote URL 解析 owner/repo(供 API 调用); 可用 FORK_SLUG 直接覆盖(本地/测试 remote 用)
fork_slug() {
  local url
  if [[ -n "${FORK_SLUG:-}" ]]; then echo "$FORK_SLUG"; return; fi
  url="$(git remote get-url "$MAIN_REMOTE")"
  case "$url" in
    git@github.com:*/*)  echo "${url#git@github.com:}" | sed 's/\.git$//' ;;
    ssh://git@github.com/*) echo "${url#ssh://git@github.com/}" | sed 's/\.git$//' ;;
    https://github.com/*) echo "${url#https://github.com/}" | sed 's/\.git$//' ;;
    *) die "无法从 remote '$MAIN_REMOTE' URL 解析 GitHub owner/repo: $url" ;;
  esac
}

# 用 gh 优先, curl+token 兜底, 调 GitHub Sync-fork(merge-upstream)
# 成功输出 merge_type(fast-forward / merge / none); 失败 die
github_sync_fork() {
  local slug="$1" token
  if command -v gh >/dev/null 2>&1; then
    if (( DRY_RUN )); then
      log "(dry-run) gh api repos/$slug/merge-upstream -f branch=$MAIN_BRANCH"
      echo "fast-forward"; return
    fi
    gh api "repos/$slug/merge-upstream" -f branch="$MAIN_BRANCH" \
      --jq '.merge_type // "none"' && return
    die "gh api merge-upstream 失败(检查 gh auth login / 是否 fork)"
  fi
  token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  [[ -n "$token" ]] || die "gh 不可用且未设置 GITHUB_TOKEN/GH_TOKEN"
  if (( DRY_RUN )); then
    log "(dry-run) curl POST repos/$slug/merge-upstream branch=$MAIN_BRANCH"
    echo "fast-forward"; return
  fi
  local resp
  resp="$(curl -sS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$slug/merge-upstream" \
    -d "{\"branch\":\"$MAIN_BRANCH\"}")" || die "curl 调 merge-upstream 失败"
  local mt
  mt="$(printf '%s' "$resp" | sed -n 's/.*"merge_type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  if [[ -z "$mt" ]]; then
    die "merge-upstream 返回异常(可能非 fork / 无权限 / token 权限不足): $resp"
  fi
  echo "$mt"
}

STASHED=0
STASH_SHA=""      # 本次脚本压入的那一条 stash 的 SHA; 还原时只弹/只删这一条, 不动用户原有的
stash_workdir() {
  if [[ -z "$(git status --porcelain)" ]]; then STASHED=0; return; fi
  if (( DRY_RUN )); then log "(dry-run) git stash push --include-untracked ..."; STASHED=0; return; fi
  local out
  out="$(git stash push --include-untracked -m "sync-remote auto-stash $(date '+%F %T')")" || die "stash 失败"
  log "$out"
  STASHED=1
  STASH_SHA="$(git rev-parse 'stash@{0}' 2>/dev/null || true)"
}
restore_one_stash() {   # 按 SHA 只还原自己那条; 有冲突留在栈里明示, 绝不 clear
  if (( ! STASHED )); then return; fi
  if [[ -z "$STASH_SHA" ]]; then warn "未记录到本次 stash 的 SHA, 跳过自动还原, 请手动 git stash list 检查"; return; fi
  local match
  match="$(git stash list --format='%H %gd' | awk -v s="$STASH_SHA" '$1==s{print $2; exit}')"
  if [[ -z "$match" ]]; then warn "本次 stash 已不在栈中, 跳过还原"; STASHED=0; return; fi
  if git stash apply --index "$match"; then
    git stash drop "$match" >/dev/null 2>&1 || true
    STASHED=0
  else
    warn "stash 还原有冲突, 本次改动仍完整保留在 $match, 请手动处理(不要 git stash clear)"
  fi
}
restore_stash() { restore_one_stash; }

BACKUP_BRANCH=""
cleanup_backup() {
  if [[ -n "$BACKUP_BRANCH" ]] && git show-ref --verify -q "refs/heads/$BACKUP_BRANCH"; then
    run git branch -D "$BACKUP_BRANCH"
  fi
}
restore_on_failure() {
  local rc=$?
  trap - EXIT
  git rebase --abort >/dev/null 2>&1 || true
  git merge --abort >/dev/null 2>&1 || true
  # 无论从哪个分支起步, 现场一律还原到工作分支上
  if [[ -n "$BACKUP_BRANCH" ]] && git show-ref --verify -q "refs/heads/$BACKUP_BRANCH"; then
    git checkout -f "$DOCS_BRANCH" >/dev/null 2>&1 || true
    git reset --hard "$BACKUP_BRANCH" >/dev/null 2>&1 || true
  else
    git checkout -f "$DOCS_BRANCH" >/dev/null 2>&1 || true
    git reset --hard >/dev/null 2>&1 || true
  fi
  if (( STASHED )); then
    warn "中途失败(rc=$rc), 恢复现场与 stash 改动"
    restore_one_stash
  fi
  git checkout -f "$DOCS_BRANCH" >/dev/null 2>&1 || true
  if [[ -n "$BACKUP_BRANCH" ]]; then
    warn "$DOCS_BRANCH 已恢复到同步前状态并停在该分支, $BACKUP_BRANCH 保留作回滚锚点, 确认后 git branch -D $BACKUP_BRANCH"
  else
    warn "已停在工作分支 $DOCS_BRANCH"
  fi
  exit "$rc"
}

# main: 纯远程同步(GitHub Sync fork), 本地只 fetch origin 让 tracking 跟上
sync_main_remote() {
  local slug mt
  slug="$(fork_slug)"
  log "通过 GitHub Sync fork 远程同步 $slug 的 $MAIN_BRANCH ← 上游 $UPSTREAM_BRANCH"
  mt="$(github_sync_fork "$slug")"
  log "GitHub Sync fork 结果: $mt (fast-forward=快进 / merge=合并 / none=已最新)"
  run git fetch "$MAIN_REMOTE" --prune   # 让本地 origin/$MAIN_BRANCH tracking 跟上远程新状态
}

# 工作分支: 对齐到已远程同步的 origin/$MAIN_BRANCH, 按 SYNC_MODE 走 merge/rebase, 逐个保留独有提交
sync_work() {
  if ! git show-ref --verify -q "refs/heads/$DOCS_BRANCH"; then
    if git ls-remote --exit-code --heads "$MAIN_REMOTE" "$DOCS_BRANCH" >/dev/null 2>&1; then
      run git checkout -b "$DOCS_BRANCH" "$MAIN_REMOTE/$DOCS_BRANCH"
    else
      run git checkout -b "$DOCS_BRANCH" "$MAIN_REMOTE/$MAIN_BRANCH"
      run git push -u "$MAIN_REMOTE" "$DOCS_BRANCH"
    fi
    return
  fi
  run git checkout "$DOCS_BRANCH"
  run git fetch "$MAIN_REMOTE" --prune
  if git ls-remote --exit-code --heads "$MAIN_REMOTE" "$DOCS_BRANCH" >/dev/null 2>&1; then
    [[ "$(git rev-parse "$DOCS_BRANCH")" == "$(git rev-parse "$MAIN_REMOTE/$DOCS_BRANCH")" ]] \
      || die "本地 $DOCS_BRANCH 与 $MAIN_REMOTE/$DOCS_BRANCH 不一致, 先手动处理再同步"
  else
    run git push -u "$MAIN_REMOTE" "$DOCS_BRANCH"
  fi
  [[ "$(git rev-parse "$MAIN_REMOTE/$DOCS_BRANCH")" == "$(git rev-parse "$MAIN_REMOTE/$MAIN_BRANCH")" ]] && { log "已一致"; return; }

  local backup="${DOCS_BRANCH}-backup"
  run git branch -f "$backup" "$DOCS_BRANCH"
  BACKUP_BRANCH="$backup"
  local base unique
  base="$(git merge-base "$DOCS_BRANCH" "$MAIN_REMOTE/$MAIN_BRANCH")"
  unique="$(git rev-list --count "$base..$DOCS_BRANCH")"
  [[ "$unique" -eq 0 ]] && { log "$DOCS_BRANCH 无独有提交, 快进到 $MAIN_REMOTE/$MAIN_BRANCH"; run git reset --hard "$MAIN_REMOTE/$MAIN_BRANCH"; cleanup_backup; return; }

  if [[ "$SYNC_MODE" == "rebase" ]]; then
    log "$DOCS_BRANCH 有 $unique 个独有提交, [rebase] 重放到 $MAIN_REMOTE/$MAIN_BRANCH 之后(逐个保留, 历史重写, 需强推)"
    run git rebase "$MAIN_REMOTE/$MAIN_BRANCH"
    run git push --force-with-lease "$MAIN_REMOTE" "$DOCS_BRANCH"
    run git reset --hard "$MAIN_REMOTE/$DOCS_BRANCH"
  else
    log "$DOCS_BRANCH 有 $unique 个独有提交, [merge] 把 $MAIN_REMOTE/$MAIN_BRANCH 合并进来(原提交 SHA 不变, 不重写历史, 普通推送)"
    if git merge-base --is-ancestor "$MAIN_REMOTE/$MAIN_BRANCH" "$DOCS_BRANCH"; then
      log "$MAIN_REMOTE/$MAIN_BRANCH 已包含在 $DOCS_BRANCH 中, 无需合并"
    else
      run git merge "$MAIN_REMOTE/$MAIN_BRANCH" --no-edit -m "merge: 同步 $MAIN_REMOTE/$MAIN_BRANCH 到 $DOCS_BRANCH"
    fi
    run git push "$MAIN_REMOTE" "$DOCS_BRANCH"
  fi
  cleanup_backup
}

main() {
  cd_to_git_root
  [[ -n "$(git branch --show-current)" ]] || die "detached HEAD, 先切到分支"
  case "$SYNC_MODE" in
    merge|rebase) ;;
    *) die "SYNC_MODE 只能是 merge 或 rebase, 当前是 '$SYNC_MODE'" ;;
  esac
  trap restore_on_failure EXIT
  stash_workdir
  sync_main_remote
  sync_work
  trap - EXIT
  restore_stash
  # 收尾保证停在 $DOCS_BRANCH(可配置, 默认 adrian), 不管起步在哪个分支
  git checkout -f "$DOCS_BRANCH" >/dev/null 2>&1 || true
  local END_BRANCH
  END_BRANCH="$(git branch --show-current)"
  [[ "$END_BRANCH" == "$DOCS_BRANCH" ]] || warn "未能停在工作分支 $DOCS_BRANCH, 当前在 $END_BRANCH"
  log "同步完成(SYNC_MODE=$SYNC_MODE): $MAIN_BRANCH 由 GitHub 远程对齐上游, $DOCS_BRANCH 已对齐 $MAIN_REMOTE/$MAIN_BRANCH, 当前分支=$END_BRANCH"
}

main "$@"
