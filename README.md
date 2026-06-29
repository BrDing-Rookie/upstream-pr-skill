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
| `MENTION_ROUTES` | (可选) JSON map `{事件: push_url}`,把某事件路由到「会 @ bot」的专用 webhook;未列出的落回 `WEBHOOK_URL` |
| `MENTION_PROMPT_<event>` | (可选) 给被触发 bot 附的指令,支持 `{pr}/{url}/{title}` |
| `UPSTREAM` | 目标上游仓库 `<org>/<repo>`(PR base) |
| `FORK_OWNER` | 你的 GitHub 用户名(PR head) |
| `POLL_INTERVAL` | 轮询秒数(默认 90) |
| `WATCH_EVENTS` | 触发推送的事件:`request_changes,approved,merged,closed` |
| `MAX_AGE_DAYS` | 守护进程硬过期(默认 14) |

## @ 触发 bot(可选)

某事件想在群里 **@ 一个 bot 并触发它反馈**(例:request changes 时 @ 代码 bot)时:

1. **人工**(一次性)用 IM 的 webhook 管理接口建一个 incoming-webhook,配置 `mention_uids=[bot_uid]`
   (bot 须先是目标群成员)。skill 不碰管理接口、不改 IM 服务端。
2. 把该 webhook 的 push URL 写进 `MENTION_ROUTES` 对应事件,例如:
   ```
   MENTION_ROUTES='{"request_changes":"https://<host>/api/v1/incoming-webhooks/<iwh_bot>/<token>"}'
   MENTION_PROMPT_request_changes='请阅读 PR #{pr} 的 review 意见并给出修改建议:{url}'
   ```
3. 守护进程在该事件发生时就 POST 到这个 URL → 服务端按其配置自动 @ bot → bot 被触发,读消息正文(含上面 prompt)做反馈。

> @ 目标完全由目标 webhook 的服务端配置决定;skill 只负责「往哪个 URL 发什么内容」,不自行构造 mention。

## 隐私

- **真实 `config` 含 webhook 密钥,已被 `.gitignore` 忽略,永不提交。**
- 守护进程运行态(`watcher.pid` / `watcher.log` / `state.json`)也被忽略。
- 仓库内不含任何账号 / 域名 / token —— 全部由本机 config 注入。

## 红线(写在 SKILL.md)

owner-only · 创建前强制确认门(AskUserQuestion)· 不打印 token ·
webhook 仅用 config 里的 https URL · 不 force-push / 不改 upstream / 不自动 merge · 失败诚实回报。

## 依赖

`gh`(已登录,GH_TOKEN classic PAT + repo scope)· `jq` · `curl` · `git` · `setsid`(daemon)。
