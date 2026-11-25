#!/usr/bin/env bash
set -euo pipefail

# ════════════════════════════════════════════════════════════════
#  用法 / 两种同步模式
# ────────────────────────────────────────────────────────────────
#  这个脚本做两件事:
#    1) 把 fork 的 main 严格对齐官方上游(只读上游, 绝不改官方源)
#    2) 把工作分支(默认 adrian)对齐到最新 main 之后, 保留你的独有提交
#
#  第 2 步有两种模式, 用环境变量 SYNC_MODE 选:
#
#    SYNC_MODE=merge   (默认)  把 main 合并进工作分支
#        git merge main
#        ✓ 工作分支原有提交原封不动, SHA 不变, 历史不被重写
#        ✓ 普通 push 即可, 不强推、无覆盖风险
#        ✗ 每同步一次多一个 merge commit, 历史是分叉图不是直线
#        适合: 在乎「历史绝不被改写」
#
#    SYNC_MODE=rebase           把工作分支 rebase 到 main 之后
#        git rebase main
#        ✓ 历史线性、干净, 没有 merge commit
#        ✗ 每个独有提交换新 SHA(历史被重写), 必须强推 --force-with-lease
#        适合: 在乎「历史干净」, 且接受改写历史
#
#  两种模式都不丢工作分支的独有提交, 区别只在「SHA 变不变 / 要不要强推」。
#
#  怎么跑:
#    ./sync.sh --dry-run          # 先看将做什么, 不改任何状态
#    ./scripts/sync.sh            # 默认 merge 模式
#    SYNC_MODE=rebase ./scripts/sync.sh
#    SYNC_MODE=merge  ./scripts/sync.sh
#    UPSTREAM_URL=git@github.adrian9778:xxx/yyy.git ./scripts/sync.sh   # 换上游(用有权限的 SSH host 别名)
#
#  安全边界:
#    - 上游(官方源)只读, 从不 push, 你的操作不会影响别人
#    - 所有写操作只落在你自己的 fork
#    - main 严格等于上游; 工作分支的处理只在 <DOCS_BRANCH> 上做
# ════════════════════════════════════════════════════════════════

# ── 可配置项(按项目改这里) ──────────────────────────────────────
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"                                # 上游 remote 名
UPSTREAM_URL="${UPSTREAM_URL:-git@github.adrian9778:agentgateway/agentgateway.git}"   # 上游 URL(用有权限的 SSH host 别名)
MAIN_REMOTE="${MAIN_REMOTE:-origin}"                                          # 推送目标 remote(fork)
MAIN_BRANCH="${MAIN_BRANCH:-main}"                                            # 主分支名(严格等于上游)
DOCS_BRANCH="${DOCS_BRANCH:-adrian}"                                          # 工作分支名(只在这条分支上做对齐)
SYNC_MODE="${SYNC_MODE:-merge}"                                               # merge | rebase
# ──────────────────────────────────────────────────────────────

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log()  { printf '\033[1;34m[sync]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[sync]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[sync]\033[0m %s\n' "$*" >&2; exit 1; }

run() {
  if (( DRY_RUN )); then log "(dry-run) $*"; else log "$*"; "$@"; fi
}

cd_to_git_root() {
  local toplevel
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "不在 git 仓库里"
  cd "$toplevel"
}

ensure_upstream() {
  if git remote | grep -qx "$UPSTREAM_REMOTE"; then
    log "上游 remote '$UPSTREAM_REMOTE' 已存在"
    return
  fi
  if [[ -z "$UPSTREAM_URL" ]]; then
    die "上游 remote '$UPSTREAM_REMOTE' 未配置且未设置 UPSTREAM_URL, 请在脚本顶部填 UPSTREAM_URL"
  fi
  run git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
}

STASHED=0
STASH_SHA=""      # 本次脚本压入的那一条 stash 的 commit SHA; 还原时只弹/只删这一条, 绝不动用户原有的 stash
stash_workdir() {
  if [[ -z "$(git status --porcelain)" ]]; then STASHED=0; return; fi
  if (( DRY_RUN )); then
    log "(dry-run) git stash push --include-untracked -m \"sync.sh auto-stash ...\""
    STASHED=0
    return
  fi
  local out
  out="$(git stash push --include-untracked -m "sync.sh auto-stash $(date '+%F %T')")" || die "stash 失败"
  log "$out"
  STASHED=1
  STASH_SHA="$(git rev-parse 'stash@{0}' 2>/dev/null || true)"   # 刚压入的在栈顶, 记下它的 SHA
}

# 只还原本次压入的那一条 stash(SHA 匹配), 不碰用户原有的 stash
# 成功还原后删掉这一条; 有冲突则原样留在栈里, 绝不静默丢
restore_one_stash() {
  if (( ! STASHED )); then return; fi
  if [[ -z "$STASH_SHA" ]]; then
    warn "未记录到本次 stash 的 SHA, 跳过自动还原, 请手动 git stash list 检查"
    return
  fi
  local match
  match="$(git stash list --format='%H %gd' | awk -v s="$STASH_SHA" '$1==s{print $2; exit}')"
  if [[ -z "$match" ]]; then
    warn "本次 stash($STASH_SHA) 已不在 stash 栈中, 跳过还原"
    STASHED=0
    return
  fi
  if git stash apply --index "$match"; then
    git stash drop "$match" >/dev/null 2>&1 || true
    STASHED=0
  else
    warn "stash 还原有冲突, 本次改动仍完整保留在 $match, 请手动处理(不要 git stash clear, 会连你原有的 stash 一起清掉)"
  fi
}

restore_stash() {   # 仅成功路径调用: 把工作改动弹回
  restore_one_stash
}

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
  # 无论从哪个分支起步、无论失败在哪一步, 现场一律还原到工作分支上
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
  # 收尾保证停在 $DOCS_BRANCH(可配置, 默认 adrian), 与成功路径一致
  git checkout -f "$DOCS_BRANCH" >/dev/null 2>&1 || true
  if [[ -n "$BACKUP_BRANCH" ]]; then
    warn "$DOCS_BRANCH 已恢复到同步前状态并停在该分支, $BACKUP_BRANCH 保留作回滚锚点, 确认后 git branch -D $BACKUP_BRANCH"
  else
    warn "已停在工作分支 $DOCS_BRANCH"
  fi
  exit "$rc"
}

# main: 严格对齐上游. 只碰 main, 不碰工作分支.
sync_main() {
  run git fetch "$UPSTREAM_REMOTE" --prune
  run git fetch "$MAIN_REMOTE" --prune
  if (( DRY_RUN )); then
    log "(dry-run) 跳过 main 与上游比对/硬重置(需要真实 fetch 后的新 ref)"
    run git push --force-with-lease "$MAIN_REMOTE" "$MAIN_BRANCH"
    return
  fi
  local local_main upstream_main
  local_main="$(git rev-parse "$MAIN_BRANCH")"
  upstream_main="$(git rev-parse "$UPSTREAM_REMOTE/$MAIN_BRANCH")"
  if [[ "$local_main" == "$upstream_main" ]]; then
    log "$MAIN_BRANCH 已与上游一致"
  else
    run git checkout "$MAIN_BRANCH"
    local ahead
    ahead="$(git rev-list --count "${UPSTREAM_REMOTE}/${MAIN_BRANCH}..${MAIN_BRANCH}")"
    if [[ "$ahead" -gt 0 ]]; then
      warn "本地 $MAIN_BRANCH 有 $ahead 个 fork 独有提交, 将被 reset --hard 丢弃(reflog 可找回)"
    fi
    run git reset --hard "$UPSTREAM_REMOTE/$MAIN_BRANCH"   # 严格一致, 不 merge; 落后也一并快进
  fi
  run git push --force-with-lease "$MAIN_REMOTE" "$MAIN_BRANCH"
}

# 工作分支对齐 main. 只在 $DOCS_BRANCH 上做, 绝不改动 main.
sync_work() {
  if ! git show-ref --verify -q "refs/heads/$DOCS_BRANCH"; then
    if git ls-remote --exit-code --heads "$MAIN_REMOTE" "$DOCS_BRANCH" >/dev/null 2>&1; then
      run git checkout -b "$DOCS_BRANCH" "$MAIN_REMOTE/$DOCS_BRANCH"
    else
      run git checkout -b "$DOCS_BRANCH"
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
  [[ "$(git rev-parse "$MAIN_REMOTE/$DOCS_BRANCH")" == "$(git rev-parse "$MAIN_BRANCH")" ]] && { log "$DOCS_BRANCH 已与 $MAIN_BRANCH 一致"; return; }

  local backup="${DOCS_BRANCH}-backup"
  run git branch -f "$backup" "$DOCS_BRANCH"
  BACKUP_BRANCH="$backup"

  local base unique
  base="$(git merge-base "$DOCS_BRANCH" "$MAIN_BRANCH")"
  unique="$(git rev-list --count "$base..$DOCS_BRANCH")"
  [[ "$unique" -eq 0 ]] && { log "$DOCS_BRANCH 无独有提交, 快进到 $MAIN_BRANCH"; run git reset --hard "$MAIN_BRANCH"; cleanup_backup; return; }

  if [[ "$SYNC_MODE" == "rebase" ]]; then
    log "$DOCS_BRANCH 有 $unique 个独有提交, [rebase 模式] 重放到 $MAIN_BRANCH 之后(逐个保留, 历史被重写, 需强推)"
    run git rebase "$MAIN_BRANCH"
    run git push --force-with-lease "$MAIN_REMOTE" "$DOCS_BRANCH"
    run git reset --hard "$MAIN_REMOTE/$DOCS_BRANCH"
  else
    log "$DOCS_BRANCH 有 $unique 个独有提交, [merge 模式] 把 $MAIN_BRANCH 合并进来(原提交 SHA 不变, 不重写历史, 普通推送)"
    if git merge-base --is-ancestor "$MAIN_BRANCH" "$DOCS_BRANCH"; then
      log "$MAIN_BRANCH 已包含在 $DOCS_BRANCH 中, 无需合并"
    else
      run git merge "$MAIN_BRANCH" --no-edit -m "merge: 同步 $MAIN_BRANCH 到 $DOCS_BRANCH"
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
  ensure_upstream
  trap restore_on_failure EXIT
  stash_workdir
  sync_main
  sync_work
  trap - EXIT
  restore_stash
  # 收尾保证停在 $DOCS_BRANCH(可配置, 默认 adrian), 不管起步在哪个分支
  git checkout -f "$DOCS_BRANCH" >/dev/null 2>&1 || true
  END_BRANCH="$(git branch --show-current)"
  [[ "$END_BRANCH" == "$DOCS_BRANCH" ]] || warn "未能停在工作分支 $DOCS_BRANCH, 当前在 $END_BRANCH"
  log "同步完成(SYNC_MODE=$SYNC_MODE): $MAIN_BRANCH == $UPSTREAM_REMOTE/$MAIN_BRANCH, $DOCS_BRANCH 已对齐 $MAIN_BRANCH, 当前分支=$END_BRANCH"
  if [[ "$SYNC_MODE" == "merge" ]]; then
    log "  $DOCS_BRANCH 原有提交 SHA 未变(不重写历史), 通过 merge commit 带入 $MAIN_BRANCH 新内容"
  else
    log "  $DOCS_BRANCH 已 rebase 到 $MAIN_BRANCH 之后, 独有提交逐个保留(历史被重写)"
  fi
}

main "$@"
