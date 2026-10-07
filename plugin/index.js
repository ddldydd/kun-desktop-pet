/**
 * Kun Like 桌宠 · Host 半区 v2
 *
 * 移植自 liyupi/dsh-kun-like-pet 的 src/host.js（MIT），改写为 DSH 静态 Bundle
 * 的 `export function apply(ctx, config)` 形态。v2 在状态机之外补齐「主动提醒」所需信息：
 *   - 等待确认：区分「审批」与「Agent 提问」，记录等待开始时间与等待时长
 *   - 任务结束：记录完成时间、本轮工具调用次数、本轮耗时摘要
 *   - 进展细节：最近一次工具名、进行中的 Agent 数、失败次数
 *   - 端点自描述：把 /kun-pet/state 的完整 URL 写入 ~/.dsh/kun-pet-endpoint.json，
 *     桌面桌宠无需猜端口
 *
 * 无依赖、fail-soft：任何服务缺失都不会让组合失败。
 */

import { appendFileSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const CONFIG = {
  pollMs: 500,
  celebrateMs: 4800,
  failedMs: 2600,
  recentToolMs: 2500,
  // 兜底路径用：拿不到 Gateway cancel 通道时，先给桌宠这么久的独占窗口，
  // 窗口内没人答才把请求交给网页端（避免桌宠答完网页端卡片还挂着）
  approvalWindowMs: 6000,
  // 状态快照文件的心跳：内容没变化也至少这么久刷新一次（桌宠按 30s 判断新鲜度）
  stateHeartbeatMs: 5000,
  endpointFile: join(homedir(), '.dsh', 'kun-pet-endpoint.json'),
  // 当前皮肤（skins/ 下的目录名）；客户端据此取 /kun-pet/skin/<skin>.png
  skin: 'ikkun',
  // 任务完成时的系统级提示音（best-effort）
  playCommand: () =>
    process.platform === 'win32'
      ? 'powershell -c "[console]::beep(880,180);[console]::beep(1175,220)"'
      : process.platform === 'darwin'
        ? 'afplay /System/Library/Sounds/Glass.aiff'
        : 'printf "\\a"',
}

/**
 * 皮肤素材：从 petdex / Codex 桌宠目录解析 <skin>/pet.json + spritesheet.png|webp。
 * 这样 Harness 宠物可以直接复用 codex-pet.org 下载的皮肤包。
 */
function resolveSkin(skinId) {
  if (!skinId) return null
  const dirs = [
    join(homedir(), '.petdex', 'pets'),
    join(process.env.CODEX_HOME || join(homedir(), '.codex'), 'pets'),
  ]
  for (const root of dirs) {
    const dir = join(root, String(skinId))
    let meta = null
    try { meta = JSON.parse(readFileSync(join(dir, 'pet.json'), 'utf8')) } catch (e) { meta = null }
    for (const name of ['spritesheet.png', 'spritesheet.webp']) {
      const file = join(dir, name)
      let bytes = null
      try { bytes = readFileSync(file) } catch (e) { continue }
      if (!bytes || bytes.length === 0) continue
      const cols = Number(meta && (meta.columns || meta.cols)) || 8
      const rows = Number(meta && (meta.rows || meta.rowsCount)) || 9
      const cellW = Number(meta && (meta.frameWidth || meta.cellWidth)) || 192
      const cellH = Number(meta && (meta.frameHeight || meta.cellHeight)) || 208
      return {
        id: String(skinId),
        displayName: (meta && (meta.displayName || meta.name)) || String(skinId),
        file,
        bytes,
        mime: name.endsWith('.webp') ? 'image/webp' : 'image/png',
        cols, rows, cellW, cellH,
      }
    }
  }
  return null
}

// 截断文案（气泡一行放不下）
function limitText(value, max) {
  const t = String(value == null ? '' : value).replace(/\s+/g, ' ').trim()
  if (t.length <= max) return t
  return t.slice(0, max) + '…'
}

// 从 ask_user_question 的入参里取出「问题 / 选项 / 方案批准」，
// 客户端气泡用它显示「任务停在哪、要你选什么」。
// 兼容几种入参挂载位置与字段名；DSH 的 schema 是：
//   { questions: [ { id, question, detail?, header?, options?: [{label, description?}],
//                    multiSelect?, intent?: { kind:'plan-review', approve } } ] }
export function pickQuestionFromArgs(exec) {
  try {
    if (!exec) return null
    const args = exec.args || exec.arguments || exec.input || exec.params ||
      (exec.tool && (exec.tool.args || exec.tool.arguments)) || null
    if (!args) return null
    const list = Array.isArray(args.questions) ? args.questions
      : (args.question ? [args] : [])
    if (!list.length) return null
    const q = list[0] || {}
    const options = []
    for (const raw of (Array.isArray(q.options) ? q.options : [])) {
      if (raw == null) continue
      const label = typeof raw === 'string'
        ? raw
        : String(raw.label || raw.text || raw.title || raw.value || '')
      if (!label) continue
      const desc = typeof raw === 'object' ? String(raw.description || raw.desc || '') : ''
      options.push(desc ? (label + '（' + limitText(desc, 22) + '）') : label)
    }
    const intent = (q.intent && q.intent.kind) ? String(q.intent.kind) : ''
    return {
      text: limitText(q.question || q.text || q.prompt || '', 60),
      header: limitText(q.header || '', 20),
      detail: limitText(q.detail || '', 40),
      options: options.slice(0, 6),
      multi: !!q.multiSelect,
      kind: intent,
      approve: limitText((q.intent && q.intent.approve) || '', 16),
    }
  } catch (e) { return null }
}

function resolveService(ctx, name) {
  try {
    if (ctx && typeof ctx.get === 'function') {
      const s = ctx.get(name)
      if (s !== undefined) return s
    }
  } catch (e) { /* service 未注册 */ }
  try {
    if (ctx && ctx[name] !== undefined) return ctx[name]
  } catch (e) { /* ignore */ }
  return undefined
}

function humanDuration(ms) {
  const totalSec = Math.max(0, Math.round(ms / 1000))
  const min = Math.floor(totalSec / 60)
  const sec = totalSec % 60
  if (min <= 0) return sec + ' 秒'
  return min + ' 分 ' + sec + ' 秒'
}

export function apply(ctx, config) {
  const cfg = { ...CONFIG, ...(config || {}) }

  // ---- host 侧诊断日志 ----
  // 之前最大的坑就是「静默失败」：插件没加载/路由没注册，桌宠那边只看到 404，
  // 完全没有线索。挂载、路由注册、异常都往这个文件里写一行。
  const hostLogPath = join(homedir(), '.dsh', 'kun-pet-host.log')
  const hostLog = (message) => {
    try {
      mkdirSync(join(homedir(), '.dsh'), { recursive: true })
      try { if (statSync(hostLogPath).size > 256 * 1024) writeFileSync(hostLogPath, '', 'utf8') } catch (e) { /* 首次写入 */ }
      appendFileSync(hostLogPath, '[' + new Date().toISOString() + '] [pid ' + process.pid + '] ' + message + '\n', 'utf8')
    } catch (e) { /* 日志失败不能影响插件本身 */ }
  }

  // 皮肤素材只需解析一次（图片较大，避免每个请求重新读盘）
  const skin = resolveSkin(cfg.skin)
  hostLog('host half mounting (skin=' + (skin ? skin.id : 'none') + ')')

  // ---- 状态快照的第二通道：文件 ----
  // 桌宠既可以直接 GET /kun-pet/state，也可以读这个 JSON 文件。
  // HTTP 路由注册失败（webServer 服务缺失、加载顺序、端口/鉴权异常）时，
  // 等待审批的气泡提示照样出得来，不会再出现「审批了但桌宠没反应」。
  const stateFilePath = join(homedir(), '.dsh', 'kun-pet-state.json')
  let lastStateFingerprint = ''
  let lastStateWriteAt = 0

  // ---- 状态机 ----
  let mode = 'idle'
  let seq = 0
  let celebrating = false
  let celebrateTimer = null
  let failTimer = null
  let toolsInFlight = 0
  let recentTool = false
  let recentToolTimer = null
  let waitingCount = 0
  let pollCount = 0
  let transitionsSeen = 0
  // 用 agentKey()（稳定 id）而不是对象本身做 Map 键：
  // agents.list() 每次可能返回新的包装对象，对象身份做键在多会话下会失效
  // （永远看不到 running→idle 下降沿，lastStatus 也只增不减）
  const turnFlags = new Map()
  const lastStatus = new Map()
  const cleanupFns = []

  // ---- v2：提醒所需细节 ----
  let waitingKind = null          // 'approval' | 'question' | null
  // 等待用户回答的问题详情（来自 ask_user_question 入参），随 /kun-pet/state 下发给客户端
  let questionInfo = null
  let waitingSince = 0            // 等待开始时刻
  let waitingTotal = 0            // 本轮累计等待次数
  let runStartedAt = 0            // 本轮开始（首个工具调用）时刻
  let toolCount = 0               // 本轮工具调用次数
  let lastToolName = null         // 最近一次工具名
  let lastToolAt = 0
  let completedAt = 0             // 最近一次「任务结束」时刻
  let lastSummary = null          // 最近一次完成摘要
  let failureCount = 0

  const currentRunningCount = () => {
    let n = 0
    for (const [, s] of lastStatus) if (s === 'running') n++
    return n
  }

  const setMode = (next) => {
    if (next === mode) return
    if (celebrating && next !== 'celebrating') return
    mode = next
    seq++
  }

  const deriveMode = () => {
    let next = 'idle'
    if (waitingCount > 0) next = 'waiting'
    else if (currentRunningCount() > 0) next = toolsInFlight > 0 || recentTool ? 'working' : 'review'
    if (celebrating) {
      // 多任务场景：庆祝期间若有新任务开始干活/等待确认，立即让位给实时状态，
      // 不能让庆祝动画盖住正在进行的任务进展
      if (next === 'working' || next === 'waiting') {
        celebrating = false
        if (celebrateTimer) { clearTimeout(celebrateTimer); celebrateTimer = null }
      } else {
        return
      }
    }
    setMode(next)
  }

  /** 给桌宠/客户端看的一句话提示 */
  const buildMessage = () => {
    const running = currentRunningCount()
    if (waitingCount > 0) {
      const waited = waitingSince > 0 ? humanDuration(Date.now() - waitingSince) : ''
      const extras = []
      if (waitingCount > 1) extras.push(waitingCount + ' 个请求')
      if (waited) extras.push('已等 ' + waited)
      const suffix = extras.length > 0 ? '（' + extras.join(' · ') + '）' : ''
      if (waitingKind === 'question') {
        return '需要你回答：Agent 正在向你提问' + suffix
      }
      const pending = pendingApprovalList()
      const tool = pending.length > 0 ? pending[0].toolName : ''
      return '需要你确认：Harness 正在等待审批' + (tool ? '（' + tool + '）' : '') + suffix
    }
    if (celebrating) return '任务结束 ✓' + (lastSummary ? ' ' + lastSummary : '')
    if (mode === 'working') {
      const bits = []
      if (running > 1) bits.push(running + ' 个任务并行')
      if (toolCount > 0) bits.push('第 ' + toolCount + ' 次工具调用')
      return '进行中' + (lastToolName ? '：' + lastToolName : '') + (bits.length > 0 ? '（' + bits.join(' · ') + '）' : '')
    }
    if (mode === 'review') return running > 1 ? running + ' 个任务思考中…' : '思考中…'
    if (mode === 'failed') return '出错了，请查看 Harness'
    return '待机中'
  }

  /** 完整状态快照：HTTP 通道（/kun-pet/state）与文件通道共用同一份内容 */
  const stateSnapshot = () => ({
    mode,
    seq,
    message: buildMessage(),
    celebrating,
    pendingApprovals: pendingApprovalList(),
    pendingApprovalCount: pendingApprovals.size,
    waiting: waitingCount > 0,
    waitingKind,
    waitingCount,
    waitingTotal,
    waitingSeconds: waitingSince > 0 ? Math.round((Date.now() - waitingSince) / 1000) : 0,
    runningAgents: currentRunningCount(),
    agentCount: lastStatus.size,
    toolCount,
    toolsInFlight,
    lastTool: lastToolName,
    lastToolAgoSeconds: lastToolAt > 0 ? Math.round((Date.now() - lastToolAt) / 1000) : -1,
    completedAt,
    completedAgoSeconds: completedAt > 0 ? Math.round((Date.now() - completedAt) / 1000) : -1,
    lastSummary,
    failureCount,
    transitionsSeen,
    pollCount,
    // 等待提问的详情：客户端气泡据此显示问题与选项（没有时为空）
    questionText: questionInfo ? questionInfo.text : '',
    questionHeader: questionInfo ? questionInfo.header : '',
    questionDetail: questionInfo ? questionInfo.detail : '',
    questionOptions: questionInfo ? questionInfo.options : [],
    questionMulti: questionInfo ? questionInfo.multi : false,
    questionKind: questionInfo ? questionInfo.kind : '',
    questionApprove: questionInfo ? questionInfo.approve : '',
    skin: skin
      ? { id: skin.id, name: skin.displayName, url: '/kun-pet/skin.png',
          cols: skin.cols, rows: skin.rows, cellW: skin.cellW, cellH: skin.cellH }
      : null,
    // 诊断：网页端那张「等待审批」卡片能不能被收掉（为 false 时桌宠答了它会一直挂着）
    guiCancelAvailable: guiCancelCapability(),
    guiCardsCancelled,
    updatedAt: Date.now(),
  })

  /**
   * 把快照落到 ~/.dsh/kun-pet-state.json。
   * 变化指纹里排除了易变字段（轮询计数/时间戳），否则每 500ms 都要写一次盘；
   * 同时最多每 stateHeartbeatMs 无条件刷一次，保证桌宠 30s 新鲜度判断不会误判过期。
   */
  const publishState = () => {
    try {
      const snapshot = stateSnapshot()
      const fingerprint = JSON.stringify({ ...snapshot, pollCount: 0, transitionsSeen: 0, updatedAt: 0 })
      const now = Date.now()
      if (fingerprint === lastStateFingerprint && (now - lastStateWriteAt) < cfg.stateHeartbeatMs) return
      lastStateFingerprint = fingerprint
      lastStateWriteAt = now
      mkdirSync(join(homedir(), '.dsh'), { recursive: true })
      writeFileSync(stateFilePath, JSON.stringify(snapshot), 'utf8')
    } catch (e) { /* 写不了就只靠 HTTP 通道 */ }
  }

  const playSystemVoice = () => {
    const shell = resolveService(ctx, 'shell')
    if (!shell) return
    try {
      const spec = shell.resolve({ command: cfg.playCommand() })
      shell.run(spec).catch(() => { /* best-effort */ })
    } catch (e) { /* best-effort */ }
  }

  const celebrate = () => {
    if (celebrating) {
      if (celebrateTimer) { clearTimeout(celebrateTimer); celebrateTimer = null }
    } else {
      celebrating = true
      setMode('celebrating')
      playSystemVoice()
    }
    completedAt = Date.now()
    const parts = []
    if (toolCount > 0) parts.push(toolCount + ' 次工具调用')
    if (runStartedAt > 0) parts.push('用时 ' + humanDuration(completedAt - runStartedAt))
    lastSummary = parts.length > 0 ? '· ' + parts.join(' · ') : null
    // 本轮统计归零，准备下一轮
    runStartedAt = 0
    toolCount = 0
    lastToolName = null
    waitingTotal = 0
    celebrateTimer = setTimeout(() => {
      celebrateTimer = null
      celebrating = false
      deriveMode()
    }, cfg.celebrateMs)
  }

  const showFailed = () => {
    failureCount++
    if (celebrating) return
    setMode('failed')
    if (failTimer) { clearTimeout(failTimer); failTimer = null }
    failTimer = setTimeout(() => {
      failTimer = null
      deriveMode()
    }, cfg.failedMs)
  }

  const markToolSettled = () => {
    toolsInFlight = Math.max(0, toolsInFlight - 1)
    if (toolsInFlight === 0) {
      if (recentToolTimer) { clearTimeout(recentToolTimer); recentToolTimer = null }
      recentToolTimer = setTimeout(() => {
        recentToolTimer = null
        recentTool = false
        deriveMode()
      }, cfg.recentToolMs)
    }
    deriveMode()
  }

  // ---- 事件瀑布 ----
  const on = (event, handler) => {
    try {
      const off = ctx && typeof ctx.on === 'function' ? ctx.on(event, handler) : undefined
      if (typeof off === 'function') cleanupFns.push(off)
    } catch (e) { /* 事件总线不可用则仅靠轮询 */ }
  }

  // ---- 审批应答：桌宠可直接放行/拒绝 ----
  // approval/request 是瀑布事件：返回 outcome（'allowed-once' | 'rejected' |
  // 'cancelled' | 'unavailable'）即作答，调 next() 则委托给后续应答者（GUI 弹窗）。
  // 这里做「竞速」：桌宠按钮（/kun-pet/approval）产生的决策与 GUI 的答复谁先到用谁，
  // 两个入口同时亮起，任一处操作都能结束这次审批。
  let approvalSeq = 0
  const pendingApprovals = new Map() // id -> { id, toolName, reason, startedAt, settle }
  cleanupFns.push(() => {
    for (const e of Array.from(pendingApprovals.values())) {
      try { e.settle('unavailable') } catch (err) { /* ignore */ }
    }
  })

  const pendingApprovalList = () => {
    const out = []
    for (const e of pendingApprovals.values()) {
      out.push({
        id: e.id,
        toolName: e.toolName,
        reason: e.reason,
        waitingSeconds: Math.round((Date.now() - e.startedAt) / 1000),
        // false = 已经交给网页端了，桌宠上再点也没用（界面据此收起 ✓/✗）
        answerable: e.answerable !== false,
      })
    }
    return out
  }

  const pickApprovalReason = (req) => {
    try {
      if (!req) return ''
      if (typeof req.reason === 'string' && req.reason) return req.reason
      const d = req.displayReason
      if (d && typeof d === 'object') {
        if (typeof d.zh === 'string' && d.zh) return d.zh
        if (typeof d['zh-CN'] === 'string' && d['zh-CN']) return d['zh-CN']
        if (typeof d.en === 'string' && d.en) return d.en
      }
    } catch (e) { /* ignore */ }
    return ''
  }

  // ---- 桌宠答了之后，把网页端那张「等待审批」卡片收掉 ----
  // api-remotes 把 approval/request 转发给网页端后，那张卡只有收到 Gateway 的
  // `{ type: 'cancel', eventId }` 帧才会消失（客户端会 abort 掉这次远程事件，
  // 挂起的审批被撤下，composer 上的「等待审批」卡片随之消失）。
  // 桌宠是在瀑布上游先答的：上游返回结果时下游那条转发链只是被丢下，Gateway
  // 并不知道请求已经结束，卡片就会一直挂着 —— 这就是「宠物批了，DeepSeek 对话栏
  // 还显示等待审批」的原因。这里显式把对应的 pending 远程事件取消掉。
  // 取不到 Gateway 内部结构时只记一行日志，绝不影响桌宠的决策本身。
  let guiCardsCancelled = 0
  let gatewayProbeLogged = false
  // 桌宠是否在线：它每 500ms 问一次 /kun-pet/state，3 秒没动静就当没开
  let petLastSeenAt = 0
  const petOnline = () => (Date.now() - petLastSeenAt) < 3000

  const gatewayService = () => {
    try { return resolveService(ctx, 'typertGateway') } catch (e) { return undefined }
  }
  const guiCancelCapability = () => {
    const gw = gatewayService()
    return !!gw && typeof gw.cancelRemoteEvent === 'function' && gw.pendingRemoteEvents instanceof Map
  }
  const findGuiPendingApproval = (gw, req) => {
    try {
      const wantedCallId = (req && req.callId !== undefined && req.callId !== null) ? String(req.callId) : null
      const wantedTool = (req && typeof req.toolName === 'string') ? req.toolName : null
      let byTool = null
      for (const pending of gw.pendingRemoteEvents.values()) {
        const frame = pending && pending.frame
        if (!frame || frame.event !== 'approval/request') continue
        const projected = frame.request || {}
        if (wantedCallId !== null && projected.callId !== undefined && String(projected.callId) === wantedCallId) return pending
        if (byTool === null && (wantedTool === null || String(projected.toolName) === wantedTool)) byTool = pending
      }
      return byTool
    } catch (e) { return null }
  }
  const cancelGuiApprovalCard = (req) => {
    const gw = gatewayService()
    if (!gw || typeof gw.cancelRemoteEvent !== 'function' || !(gw.pendingRemoteEvents instanceof Map)) {
      hostLog('GUI approval card: typertGateway internals unavailable; the Web card may keep showing')
      return
    }
    let tries = 0
    const attempt = () => {
      tries += 1
      const pending = findGuiPendingApproval(gw, req)
      if (!pending) {
        // 转发是异步的：卡片可能还没登记到 Gateway，隔一小会儿再试几次
        if (tries < 8) { setTimeout(attempt, 150); return }
        hostLog('GUI approval card: no matching pending Remote event after 8 tries; Web card may keep showing')
        return
      }
      try {
        const reason = new Error('approval answered on the desktop pet')
        reason.name = 'KunPetAnswered'
        gw.cancelRemoteEvent(pending, reason)
        guiCardsCancelled += 1
        hostLog('GUI approval card cancelled: eventId=' + String(pending.id) +
          ' tool=' + String((req && req.toolName) || '?'))
      } catch (e) {
        hostLog('GUI approval card cancel failed: ' + (e && e.message ? e.message : String(e)))
      }
    }
    attempt()
  }

  on('approval/request', async (req, next) => {
    waitingCount++
    waitingTotal++
    if (waitingKind === null) { waitingKind = 'approval'; waitingSince = Date.now() }
    deriveMode()

    const id = 'pa-' + String(++approvalSeq)
    let resolveDecision = null
    const decision = new Promise((resolve) => { resolveDecision = resolve })
    let settled = false
    // 这个决策是不是「桌宠按钮答的」：只有这种情况才需要去收网页端的卡片
    let answeredOnPet = false
    const finish = (outcome) => {
      if (settled) return
      settled = true
      pendingApprovals.delete(id)
      waitingCount = Math.max(0, waitingCount - 1)
      if (waitingCount === 0) { waitingKind = null; waitingSince = 0 }
      deriveMode()
      resolveDecision(outcome)
    }
    pendingApprovals.set(id, {
      id,
      toolName: (req && typeof req.toolName === 'string' && req.toolName) ? req.toolName : '未知工具',
      reason: pickApprovalReason(req),
      startedAt: Date.now(),
      // 桌宠还能不能答这次请求（交给网页端之后就不行了）
      answerable: true,
      // settle 只由桌宠的 /kun-pet/approval 调用（网页端有自己的应答通道）
      settle: (outcome) => { answeredOnPet = true; finish(outcome) },
    })
    const entry = pendingApprovals.get(id)
    // 请求被取消（轮次中断等）时同样收尾，避免桌宠残留按钮
    try {
      if (req && req.signal) {
        if (req.signal.aborted) finish('cancelled')
        else req.signal.addEventListener('abort', () => finish('cancelled'), { once: true })
      }
    } catch (e) { /* ignore */ }

    const delegateToGui = (markUnanswerable) => {
      if (delegatedPromise !== null) return delegatedPromise
      // 兜底路径交给网页端之后，桌宠再答也送不出去（那边已经有一张卡了），
      // 标记为不可答，桌宠界面会把 ✓/✗ 收起来。
      // 正常路径（能 cancel 网页端卡片）不标记：两边都还能答，桌宠先答就撤掉那张卡。
      if (markUnanswerable && entry) entry.answerable = false
      try {
        delegatedPromise = Promise.resolve(next())
      } catch (err) {
        finish('unavailable')
        throw err
      }
      return delegatedPromise.then(
        (outcome) => { finish(outcome); return outcome },
        () => { finish('unavailable'); return 'unavailable' },
      )
    }
    let delegatedPromise = null

    const canCancelGuiCard = guiCancelCapability()
    if (canCancelGuiCard || !petOnline()) {
      // 正常路径：两边同时亮（网页端卡片 + 桌宠面板），谁先答听谁的；
      // 桌宠先答时把网页端那张卡撤掉，避免「任务已经继续、对话栏还显示等待审批」
      return Promise.race([
        decision.then((outcome) => {
          if (answeredOnPet) cancelGuiApprovalCard(req)
          return outcome
        }),
        delegateToGui(false),
      ])
    }

    // 兜底路径（这个 DSH 版本没有可用的 Gateway cancel 通道）：
    // 先只给桌宠看一个窗口，窗口内没人答才交给网页端。
    // 这样即使撤不掉网页端卡片，也不会出现「桌宠答了、卡片还挂着」的状态。
    const windowMs = Number(cfg.approvalWindowMs) > 0 ? Number(cfg.approvalWindowMs) : 6000
    const outcome = await Promise.race([
      decision.then((value) => ({ from: 'pet', value })),
      new Promise((resolve) => setTimeout(() => resolve({ from: 'window' }), windowMs)),
    ])
    if (outcome.from === 'pet') {
      if (answeredOnPet) hostLog('approval answered on the pet before the GUI window expired; the Web card was never shown')
      return outcome.value
    }
    return delegateToGui(true)
  })

  // Agent 身份键：优先稳定 id，退化时用对象本身
  const agentKey = (agent) => {
    try {
      if (agent === null || agent === undefined) return 'nil'
      if (agent.id !== null && agent.id !== undefined) return 'id:' + String(agent.id)
      if (agent.sessionId !== null && agent.sessionId !== undefined) return 'sid:' + String(agent.sessionId)
    } catch (e) { /* ignore */ }
    return agent
  }

  on('tools/execute', (exec, next) => {
    let isQuestion = false
    if (exec && exec.agent) {
      const key = agentKey(exec.agent)
      let f = turnFlags.get(key)
      if (f === undefined) { f = { worked: false, errored: false }; turnFlags.set(key, f) }
      f.worked = true
    }
    if (exec && typeof exec.name === 'string') {
      lastToolName = exec.name
      lastToolAt = Date.now()
      if (exec.name === 'ask_user_question') {
        isQuestion = true
        // 抓住提问内容（问题 / 选项 / 方案批准），客户端气泡据此显示「要选什么」
        const picked = pickQuestionFromArgs(exec)
        if (picked) questionInfo = picked
        waitingCount++
        waitingTotal++
        if (waitingKind === null) { waitingKind = 'question'; waitingSince = Date.now() }
      }
    }
    if (runStartedAt === 0) runStartedAt = Date.now()
    toolCount++
    toolsInFlight++
    recentTool = true
    if (recentToolTimer) { clearTimeout(recentToolTimer); recentToolTimer = null }
    deriveMode()
    let p
    try {
      p = Promise.resolve(next())
    } catch (err) {
      if (isQuestion) {
        waitingCount = Math.max(0, waitingCount - 1)
        questionInfo = null
        if (waitingCount === 0) { waitingKind = null; waitingSince = 0 }
      }
      markToolSettled()
      throw err
    }
    const settle = () => {
      if (isQuestion) {
        waitingCount = Math.max(0, waitingCount - 1)
        questionInfo = null
        if (waitingCount === 0) { waitingKind = null; waitingSince = 0 }
      }
      markToolSettled()
    }
    p.then(settle, settle)
    return p
  })

  on('agent/request-error', (payload, next) => {
    if (payload && payload.agent) {
      const key = agentKey(payload.agent)
      let f = turnFlags.get(key)
      if (f === undefined) { f = { worked: false, errored: false }; turnFlags.set(key, f) }
      f.errored = true
    }
    showFailed()
    return next()
  })

  // ---- 轮询 agents（多会话聚合）----
  const agents = resolveService(ctx, 'agents')
  const onAgentSettled = (key) => {
    transitionsSeen++
    // 只有“所有会话都闲下来”才算一轮任务结束；单个会话收尾不能触发庆祝，
    // 否则另一个还在跑的任务会被庆祝动画/提示音盖住
    if (currentRunningCount() === 0 && waitingCount === 0) {
      const f = turnFlags.get(key)
      if (f === undefined || !f.errored) celebrate()
      if (f !== undefined) turnFlags.delete(key)
    }
  }
  const poll = () => {
    pollCount++
    if (!agents) return
    let list
    try { list = agents.list() } catch (e) { return }
    if (!Array.isArray(list)) return
    const seen = new Set()
    for (const agent of list) {
      const key = agentKey(agent)
      seen.add(key)
      let status = 'idle'
      try { status = agent && agent.status === 'running' ? 'running' : 'idle' } catch (e) { status = 'idle' }
      const prev = lastStatus.get(key)
      lastStatus.set(key, status)
      if (prev === 'running' && status === 'idle') onAgentSettled(key)
    }
    // 从列表消失的会话（窗口关闭/列表收缩）同样按“结束”处理；
    // 否则残留的 running 状态会让桌宠永远停在“进行中”
    for (const entry of Array.from(lastStatus.entries())) {
      const key = entry[0]
      const status = entry[1]
      if (!seen.has(key)) {
        lastStatus.delete(key)
        if (status === 'running') onAgentSettled(key)
      }
    }
    deriveMode()
  }
  const pollTimer = setInterval(() => {
    poll()
    publishState()
    // 启动后探测一次：网页端「等待审批」卡片到底能不能被收掉（收不掉就是这里 UNAVAILABLE）
    if (!gatewayProbeLogged) {
      gatewayProbeLogged = true
      hostLog('capability probe: GUI approval card cancel = ' + (guiCancelCapability() ? 'available' : 'UNAVAILABLE'))
    }
  }, cfg.pollMs)
  cleanupFns.push(() => clearInterval(pollTimer))

  // ---- HTTP 通道：/kun-pet/state、/kun-pet/approval、/kun-pet/skin.png ----
  // 用 ctx.inject(['webServer'], …) 而不是在 apply 里直接 ctx.get('webServer')：
  // 插件与 webServer 的加载顺序并没有硬保证，一旦 apply 先跑，服务还是 undefined，
  // 老写法（if (webServer) {…}）就静默跳过注册 ⇒ 端点永远 404，
  // 桌宠那边表现就是「等审批时气泡不提示」。inject 等依赖就绪后再注册。
  const setupRoutes = (routeCtx) => {
    try {
      const webServer = resolveService(routeCtx, 'webServer')
      if (!webServer || typeof webServer.register !== 'function') {
        hostLog('webServer service unavailable; HTTP channel disabled (file channel still active)')
        return
      }
      const routeHost = webServer.host === '0.0.0.0' ? '127.0.0.1' : webServer.host
      const endpointUrl = 'http://' + routeHost + ':' + webServer.port + '/kun-pet/state'
      const dispose = webServer.register({
        kind: 'exact',
        path: '/kun-pet/state',
        handler: (req, res) => {
          // 有桌宠在轮询 = 桌宠在线（决定审批要不要先给桌宠一个窗口）
          petLastSeenAt = Date.now()
          const body = JSON.stringify(stateSnapshot())
          res.writeHead(200, {
            'Content-Type': 'application/json; charset=utf-8',
            'Content-Length': String(Buffer.byteLength(body)),
            'Cache-Control': 'no-store',
          })
          res.end(body)
        },
      })
      if (typeof dispose === 'function') cleanupFns.push(dispose)

      // ---- /kun-pet/approval：桌宠直接放行/拒绝待审批请求 ----
      const disposeApproval = webServer.register({
        kind: 'exact',
        path: '/kun-pet/approval',
        handler: (req, res) => {
          let raw = ''
          req.on('data', (chunk) => { raw += chunk })
          req.on('end', () => {
            let payload = {}
            try { payload = JSON.parse(raw || '{}') } catch (e) { payload = {} }
            const decisionMap = {
              'allowed-once': 'allowed-once', approve: 'allowed-once', allow: 'allowed-once', yes: 'allowed-once',
              rejected: 'rejected', reject: 'rejected', deny: 'rejected', denied: 'rejected', no: 'rejected',
              cancelled: 'cancelled', cancel: 'cancelled',
            }
            const outcome = decisionMap[String(payload.decision || '')] || null
            petLastSeenAt = Date.now()
            let target = null
            if (payload.id !== undefined && payload.id !== null) {
              target = pendingApprovals.get(String(payload.id)) || null
            }
            if (!target && pendingApprovals.size > 0) {
              target = pendingApprovals.values().next().value // 快照过期时按最早一个处理
            }
            // 已经交给网页端的请求，桌宠再答也送不出去（那边已经亮了卡片）
            const delegatedToHarness = target !== null && target.answerable === false
            let answered = false
            if (outcome && target && !delegatedToHarness) {
              answered = true
              try { target.settle(outcome) } catch (e) { /* ignore */ }
            }
            const body = JSON.stringify({
              ok: answered,
              id: target ? target.id : null,
              outcome,
              delegatedToHarness,
              pendingApprovals: pendingApprovalList(),
            })
            res.writeHead(answered ? 200 : (delegatedToHarness ? 409 : 404), {
              'Content-Type': 'application/json; charset=utf-8',
              'Content-Length': String(Buffer.byteLength(body)),
              'Cache-Control': 'no-store',
            })
            res.end(body)
          })
        },
      })
      if (typeof disposeApproval === 'function') cleanupFns.push(disposeApproval)

      // 皮肤精灵图：客户端需要取图，故带宽松缓存与 CORS 头
      if (skin) {
        try {
          const disposeSkin = webServer.register({
            kind: 'exact',
            path: '/kun-pet/skin.png',
            handler: (req, res) => {
              res.writeHead(200, {
                'Content-Type': skin.mime,
                'Content-Length': String(skin.bytes.length),
                'Cache-Control': 'public, max-age=3600',
                'Access-Control-Allow-Origin': '*',
              })
              res.end(skin.bytes)
            },
          })
          if (typeof disposeSkin === 'function') cleanupFns.push(disposeSkin)
        } catch (e) { /* 皮肤路由注册失败：客户端回退内置形象 */ }
      }

      // 端点自描述：桌面桌宠读这个文件即可，无需猜端口
      try {
        mkdirSync(join(homedir(), '.dsh'), { recursive: true })
        writeFileSync(cfg.endpointFile, JSON.stringify({ url: endpointUrl, updatedAt: Date.now() }, null, 2), 'utf8')
      } catch (e) { /* 写不了就靠默认端口 */ }
      hostLog('HTTP channel ready: ' + endpointUrl)
      cleanupFns.push(() => {
        try { rmSync(cfg.endpointFile, { force: true }) } catch (e) { /* ignore */ }
      })
    } catch (e) {
      hostLog('route registration failed: ' + (e && e.message ? e.message : String(e)))
    }
  }

  try {
    if (ctx && typeof ctx.inject === 'function') {
      const offInject = ctx.inject(['webServer'], setupRoutes)
      if (typeof offInject === 'function') cleanupFns.push(offInject)
    } else {
      setupRoutes(ctx)
    }
  } catch (e) {
    hostLog('inject(webServer) failed: ' + (e && e.message ? e.message : String(e)) + '; registering immediately')
    setupRoutes(ctx)
  }

  // 先落一次盘：桌宠即使还没轮到 HTTP 通道，也能马上从文件通道看到状态
  publishState()

  // ---- 清理 ----
  if (ctx && typeof ctx.effect === 'function') {
    ctx.effect(() => () => {
      if (celebrateTimer) clearTimeout(celebrateTimer)
      if (failTimer) clearTimeout(failTimer)
      if (recentToolTimer) clearTimeout(recentToolTimer)
      for (const fn of cleanupFns) {
        try { fn() } catch (e) { /* ignore */ }
      }
      // 快照文件随插件一起消失，避免桌宠读到上一次运行的陈旧状态
      try { rmSync(stateFilePath, { force: true }) } catch (e) { /* ignore */ }
      hostLog('host half disposed')
    })
  }
}
