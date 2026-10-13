# pi 扩展：Kun Like 桌宠 × pi coding agent

把 pi 的运行时状态发布给桌面桌宠，让桌宠能在 pi 干活/收尾/出错/等你确认时给出反应。

**这个扩展存在的唯一核心理由**：pi 的会话文件里**没有**「正在弹确认框」这类记录，
所以纯读文件的桌宠永远无法知道「pi 在等你」。pi 唯一能表达这件事的官方信号是
`ui_prompt_start` / `ui_prompt_end` 事件，而它只在扩展里可见。

> 不装本扩展，桌宠仍能跟随 pi 的「在干活 / 收尾 / 出错 / 模型 / 轮次」——
> 它可以直接只读 `~/.pi/agent/sessions/**/*.jsonl`。本扩展只是补上「等待确认」这一项。

---

## 装法

### 方式一：一键安装（推荐）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ..\install.ps1 -InstallPiExtension
```

### 方式二：手动拷

```powershell
$dest = "$env:USERPROFILE\.pi\agent\extensions"
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item .\kun-pet.ts $dest -Force
```

装完**在 pi 里执行 `/reload`**（或重开 pi）。

### 方式三：当 npm 包用

`~/.pi/agent/npm/` 下加依赖，然后在该目录的 `package.json` 里引用本目录
（本机已用这种方式装了 `pi-signal-footer`，可照抄）。pi 的 `settings.json` 里
`packages` 数组加一项即可。

---

## 验证

装好后看两个地方：

```powershell
# 1. 状态文件是否在持续更新（每 5s 一次心跳）
Get-Content "$env:USERPROFILE\.pi\agent\kun-pet-state.json" -Raw

# 2. 桌宠日志里应出现 ext 通道
Select-String -Path .\kun-pet-desktop.log -Pattern 'pi channel'
```

期望看到 `pi channel: ext`。如果是 `pi channel: sessions`，说明扩展没生效
（多半是没 `/reload`，或文件放错了目录）。

---

## 它写了什么

只写**一个**文件：`~/.pi/agent/kun-pet-state.json`

```json
{
  "updatedAt": 1791870082000,
  "pid": 12345,
  "mode": "waiting",
  "sessionId": "...",
  "sessionName": "...",
  "cwd": "E:\\demo\\proj",
  "waiting": true,
  "waitingKind": "plan-review",
  "waitingTitle": "确认要删除这 3 个文件吗？",
  "waitingSeconds": 12,
  "toolCount": 7,
  "lastTool": "bash",
  "taskText": "把登录页的空指针修掉",
  "turns": 2,
  "steps": 7,
  "completedAt": 0,
  "lastSummary": null,
  "provider": "newapixiacan",
  "model": "cline-pass/deepseek-v4.1-flash",
  "compacting": false,
  "pendingApprovals": []
}
```

**绝不**读取或写入 pi 的其他数据。特别是 `models.json` / `auth.json` /
`secrets.dpapi.json` —— 那里有明文 API Key，本扩展碰都不碰。

---

## 用到哪些 pi 事件

| 事件 | 用途 |
|---|---|
| `session_start` / `session_shutdown` | 起止；退出时删除快照，避免桌宠读到陈旧的「正在等你」 |
| `turn_start` | 轮次计数、进入 working |
| `tool_execution_start` / `tool_execution_end` | 工具计数、当前工具名、是否失败 |
| **`ui_prompt_start` / `ui_prompt_end`** | **「正在等你确认」——本扩展的核心** |
| `agent_settled` | 一轮彻底结束 → 「任务结束」摘要 |
| `model_select` | 当前模型/提供方 |
| `input` | 当前任务文本（排除扩展自身注入的输入） |
| `session_before_compact` / `session_compact` / `session_compact_failed` | 「压缩上下文中」 |

全部 API 都是对照 `@earendil-works/pi-coding-agent` 的
`dist/core/extensions/types.d.ts` 核过的（`ExtensionContext.model`、
`ctx.sessionManager.getSessionId()`、`InputSource` 取值等）。

---

## 卸载

```powershell
Remove-Item "$env:USERPROFILE\.pi\agent\extensions\kun-pet.ts" -Force
Remove-Item "$env:USERPROFILE\.pi\agent\kun-pet-state.json" -Force
```

或在 pi 里 `/reload` 后即不再加载。桌宠会自动退回「只读会话文件」通道，
进展提示照常，只是不再有「正在等你确认」。
