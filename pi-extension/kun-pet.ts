/**
 * Kun Like 桌宠 × pi coding agent —— pi 扩展（P2 通道）
 *
 * 作用：把 pi 的运行时状态写成一份 JSON 快照，供桌面桌宠读取。
 *   ~/.pi/agent/kun-pet-state.json
 *
 * 为什么需要它？——**只有它能表达「pi 正在等你」**
 *   桌宠的 P1 通道（只读会话 JSONL）能推出「在干活 / 收尾 / 出错」，
 *   但 pi 的会话文件里**没有**「正在弹确认框」这类记录。
 *   pi 唯一能表达这件事的官方信号是 `ui_prompt_start` / `ui_prompt_end` 事件，
 *   它只在扩展上下文里可见，所以必须由本扩展转发出来。
 *
 * 设计约束：
 *   - **fail-soft**：任何写盘失败都不能影响 pi 本身（全部 try/catch 吞掉）。
 *   - **只写一个文件**：不碰 pi 的其他任何数据（auth.json / models.json 里有明文
 *     API Key，本扩展绝不读取，也绝不写入日志）。
 *   - 心跳：默认 5s 无条件重写一次，桌宠按 30s 判新鲜度
 *     （pi 退出后不再心跳 ⇒ 陈旧快照会被桌宠自动忽略）。
 *
 * 安装（任选）：
 *   1) 本地扩展：把本文件拷到 ~/.pi/agent/extensions/kun-pet.ts，然后在 pi 里 /reload
 *   2) npm 包：见同目录 package.json 与 README.md
 *
 * 卸载：删掉扩展文件（或从 settings.json 的 packages 里移除），
 *       再把 ~/.pi/agent/kun-pet-state.json 删掉即可。桌宠会自动退回 P1 通道。
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** 快照落盘位置（桌宠侧默认读同一路径） */
const STATE_DIR = join(homedir(), ".pi", "agent");
const STATE_FILE = join(STATE_DIR, "kun-pet-state.json");

/** 心跳间隔：即使状态没变也重写一次，保证桌宠的新鲜度判断不会误判过期 */
const HEARTBEAT_MS = 5000;

/** 同一工具连续调用时，工具的展示名 */
type Snapshot = {
  updatedAt: number;
  pid: number;
  /** 桌宠的模式词汇，与 DSH 侧保持一致：idle/working/review/waiting/celebrating/failed */
  mode: "idle" | "working" | "review" | "waiting" | "celebrating" | "failed";
  sessionId: string;
  sessionName: string;
  cwd: string;
  /** 是否正在等用户（这是本扩展存在的核心理由） */
  waiting: boolean;
  waitingKind: "question" | "plan-review" | null;
  waitingTitle: string;
  waitingSince: number;
  waitingCount: number;
  waitingSeconds: number;
  runningAgents: number;
  toolCount: number;
  lastTool: string | null;
  taskText: string;
  turns: number;
  steps: number;
  failureCount: number;
  completedAt: number;
  lastSummary: string | null;
  provider: string | null;
  model: string | null;
  compacting: boolean;
  /** pi 侧暂不支持「在桌宠上直接批准」，恒为空数组（桌宠据此不显示 ✓/✗ 面板） */
  pendingApprovals: never[];
};

export default function kunPet(pi: ExtensionAPI): void {
  let mode: Snapshot["mode"] = "idle";
  let sessionId = "";
  let sessionName = "";
  let cwd = "";
  let provider: string | null = null;
  let model: string | null = null;

  let waiting = false;
  let waitingKind: Snapshot["waitingKind"] = null;
  let waitingTitle = "";
  let waitingSince = 0;

  let toolCount = 0;
  let turns = 0;
  let steps = 0;
  let failureCount = 0;
  let lastTool: string | null = null;
  let taskText = "";
  let completedAt = 0;
  let lastSummary: string | null = null;
  let compacting = false;
  let runStartedAt = 0;

  let heartbeat: ReturnType<typeof setInterval> | null = null;

  /** 快照落盘：任何异常都吞掉，绝不影响 pi */
  const publish = (): void => {
    try {
      const now = Date.now();
      const snap: Snapshot = {
        updatedAt: now,
        pid: process.pid,
        mode: waiting ? "waiting" : mode,
        sessionId,
        sessionName,
        cwd,
        waiting,
        waitingKind,
        waitingTitle,
        waitingSince,
        waitingCount: waiting ? 1 : 0,
        waitingSeconds: waitingSince > 0 ? Math.round((now - waitingSince) / 1000) : 0,
        runningAgents: mode === "working" || mode === "review" ? 1 : 0,
        toolCount,
        lastTool,
        taskText,
        turns,
        steps,
        failureCount,
        completedAt,
        lastSummary,
        provider,
        model,
        compacting,
        pendingApprovals: [],
      };

      mkdirSync(STATE_DIR, { recursive: true });
      writeFileSync(STATE_FILE, JSON.stringify(snap), "utf8");
    } catch {
      /* 写不了就算了：桌宠会自动退回 P1（会话尾随）通道 */
    }
  };

  /**
   * 从 ctx 抓「会话身份 + 当前模型」。
   * 注意：模型在 `ctx.model` 上（不是 pi.getActiveModel()），
   * 会话 id 走 `ctx.sessionManager.getSessionId()`，会话名走 `pi.getSessionName()`。
   * 这些都在官方 ExtensionContext / ExtensionAPI 类型里，逐条核对过。
   */
  const syncContext = (ctx: ExtensionContext): void => {
    try { cwd = String(ctx.cwd ?? cwd); } catch { /* ignore */ }
    try {
      const id = ctx.sessionManager?.getSessionId?.();
      if (id) { sessionId = String(id); }
    } catch { /* ignore */ }
    try {
      const name = pi.getSessionName?.();
      if (name) { sessionName = String(name); }
    } catch { /* ignore */ }
    try {
      const m = ctx.model;
      if (m) {
        const p = (m as { provider?: string }).provider;
        const id = (m as { id?: string }).id;
        if (p) { provider = String(p); }
        if (id) { model = String(id); }
      }
    } catch { /* ignore */ }
  };

  // ---------------- 会话生命周期 ----------------
  pi.on("session_start", (event, ctx) => {
    syncContext(ctx);
    if (event.reason === "new" || event.reason === "startup") {
      toolCount = 0; turns = 0; steps = 0; failureCount = 0;
      lastTool = null; completedAt = 0; lastSummary = null;
    }
    // 切会话/恢复时，上一轮的等待态不应残留
    waiting = false; waitingKind = null; waitingTitle = ""; waitingSince = 0;
    mode = "idle";
    publish();
  });

  pi.on("session_shutdown", () => {
    // 主动清掉快照：桌宠下一轮就看不到 pi，不会读到「正在等你」的陈旧状态
    try {
      if (heartbeat) { clearInterval(heartbeat); heartbeat = null; }
      rmSync(STATE_FILE, { force: true });
    } catch {
      /* 删不掉也不影响：桌宠按 updatedAt 30s 判新鲜度 */
    }
  });

  // ---------------- 轮次 / 模型 ----------------
  pi.on("turn_start", (_event, ctx) => {
    syncContext(ctx);
    turns++;
    if (runStartedAt === 0) { runStartedAt = Date.now(); }
    // 新一轮开始：上一轮的结束态让位
    if (!waiting) { mode = "working"; }
    publish();
  });

  pi.on("model_select", (event) => {
    try {
      const p = (event.model as { provider?: string }).provider;
      const id = (event.model as { id?: string }).id;
      if (p) { provider = String(p); }
      if (id) { model = String(id); }
    } catch { /* ignore */ }
    publish();
  });

  // ---------------- 工具执行 ----------------
  pi.on("tool_execution_start", (event) => {
    toolCount++;
    steps++;
    lastTool = event.toolName;
    if (!waiting) { mode = "working"; }
    publish();
  });

  pi.on("tool_execution_end", (event) => {
    if (event.isError) { failureCount++; }
    if (!waiting) {
      // 工具收尾但 agent 还在这一轮里 → 交给 review（思考/生成中）
      mode = "review";
    }
    publish();
  });

  // ---------------- ★ 「pi 正在等你」：本扩展的核心价值 ----------------
  // pi 在弹阻塞式 UI（confirm / select / input / editor / custom）时发这两个事件。
  // 会话 JSONL 里没有任何等价记录，所以纯文件尾随**永远**拿不到这一项。
  pi.on("ui_prompt_start", (event) => {
    waiting = true;
    waitingSince = Date.now();
    waitingTitle = String(event.title ?? "");
    // 交互类型 → 桌宠的等待分类；'confirm' 多半是方案/权限确认
    waitingKind = event.kind === "confirm" ? "plan-review" : "question";
    mode = "waiting";
    publish();
  });

  pi.on("ui_prompt_end", () => {
    waiting = false;
    waitingKind = null;
    waitingTitle = "";
    waitingSince = 0;
    mode = "working";
    publish();
  });

  // ---------------- 结束 ----------------
  // agent_settled = 「这一轮彻底落定，不会再有自动重试/压缩/排队续跑」
  pi.on("agent_settled", (event) => {
    completedAt = Date.now();
    waiting = false;
    waitingKind = null;
    waitingTitle = "";
    waitingSince = 0;
    mode = event.aborted ? "idle" : "celebrating";

    const parts: string[] = [];
    if (toolCount > 0) { parts.push(`${toolCount} 次工具调用`); }
    if (runStartedAt > 0) {
      const sec = Math.max(0, Math.round((completedAt - runStartedAt) / 1000));
      parts.push(`用时 ${sec} 秒`);
    }
    if (failureCount > 0) { parts.push(`${failureCount} 次失败`); }
    lastSummary = parts.length > 0 ? `· ${parts.join(" · ")}` : null;

    // 为下一轮归零
    runStartedAt = 0;
    toolCount = 0;
    steps = 0;
    failureCount = 0;
    lastTool = null;
    publish();
  });

  // ---------------- 上下文压缩 ----------------
  pi.on("session_before_compact", () => { compacting = true; publish(); });
  pi.on("session_compact", () => { compacting = false; publish(); });
  pi.on("session_compact_failed", () => { compacting = false; publish(); });

  // ---------------- 用户输入 → 气泡里的「当前任务」 ----------------
  // InputSource 是 "interactive" | "rpc" | "extension"（**不是** "user"）。
  // 扩展自己注入的输入 source='extension'，不该当成用户任务，故排除它。
  pi.on("input", (event, ctx) => {
    try {
      syncContext(ctx);
      if (event.source !== "extension" && typeof event.text === "string" && event.text.trim()) {
        taskText = event.text.replace(/\s+/g, " ").trim().slice(0, 120);
      }
    } catch { /* ignore */ }
    publish();
  });

  // ---------------- 心跳 ----------------
  // 状态没变化也要定期重写：桌宠按 updatedAt 判新鲜度（30s），
  // 没有心跳的话「等你确认」卡住较久时会被误判成 pi 已退出。
  heartbeat = setInterval(publish, HEARTBEAT_MS);
}
