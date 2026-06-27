# upstream-pr

一个 [Claude Code](https://claude.com/claude-code) skill:在 owner 明确确认后,向 upstream 仓库提
Issue + PR,并启动一个独立守护进程**轮询** PR 进度,有新动态时经 **IM incoming webhook** 通知 owner;
PR 被 merge/close 后推送终态消息并自动退出。

> 监听用轮询(无需 GitHub 入站 webhook / 仓库 admin 权限);通知是出站,POST `{"content":"<markdown>"}`。

## 结构

```
skill/
  SKILL.md              # 工作流编排 + 红线(给 Claude Code 加载)
  scripts/
    preflight.sh        # 校验 GH_TOKEN scope / 分支已 push / merge-tree 探冲突
    create.sh           # gh issue create → 注入 Fixes #N → gh pr create(fork→upstream)
    watch_pr.sh         # 守护进程:轮询 + diff + webhook 通知 + 终态退出
    watchctl.sh         # list / status / stop / stop-all / cleanup
config.example          # 配置样例(复制为 ~/.upstream-pr-watch/config 后填真实值)
install.sh              # 复制 skill 到 ~/.claude/skills/ + 初始化 config
```

## 安装

```bash
./install.sh
# 然后编辑 ~/.upstream-pr-watch/config 填入真实值:
#   WEBHOOK_URL / UPSTREAM / FORK_OWNER
# 并确保环境里有 GH_TOKEN(classic PAT,repo scope)
```

装好后在 Claude Code 里用 `/upstream-pr` 触发。

## 配置(`~/.upstream-pr-watch/config`)

| key | 说明 |
|---|---|
| `WEBHOOK_URL` | IM 出站通知端点(https),载荷 `{"content":"<markdown>"}` |
| `UPSTREAM` | 目标上游仓库 `<org>/<repo>`(PR base) |
| `FORK_OWNER` | 你的 GitHub 用户名(PR head) |
| `POLL_INTERVAL` | 轮询秒数(默认 90) |
| `WATCH_EVENTS` | 触发推送的事件:`request_changes,approved,merged,closed` |
| `MAX_AGE_DAYS` | 守护进程硬过期(默认 14) |

## 隐私

- **真实 `config` 含 webhook 密钥,已被 `.gitignore` 忽略,永不提交。**
- 守护进程运行态(`watcher.pid` / `watcher.log` / `state.json`)也被忽略。
- 仓库内不含任何账号 / 域名 / token —— 全部由本机 config 注入。

## 红线(写在 SKILL.md)

owner-only · 创建前强制确认门(AskUserQuestion)· 不打印 token ·
webhook 仅用 config 里的 https URL · 不 force-push / 不改 upstream / 不自动 merge · 失败诚实回报。

## 依赖

`gh`(已登录,GH_TOKEN classic PAT + repo scope)· `jq` · `curl` · `git` · `setsid`(daemon)。
