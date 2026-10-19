# =====================================================================
#  Kun Like 桌宠 · 随机移动（到处跑）
# =====================================================================
#  桌宠可以自己在桌面上溜达：随机挑一个目标点 → 走过去 → 停一会儿 → 再挑下一个。
#
#  这个文件只放**纯函数**（选点、走一步），不碰 WPF、不碰 $window/$state，
#  所以能脱离桌宠单独自测（见 tests/test-wander.ps1）。真正驱动窗口移动的
#  Update-Wander 在 kun-pet-desktop.ps1 里（它需要访问窗口与状态）。
#
#  被 kun-pet-desktop.ps1 以 dot-source 方式加载。
# =====================================================================

# 取 [min, max] 区间内的随机 double。
# 不用 Get-Random -Minimum/-Maximum 直接取小数：那两个参数的语义是整数区间
# （传小数会抛错），所以这里取一个整数比例再换算。
function Get-RandDouble([double]$min, [double]$max) {
    if ($max -le $min) { return [double]$min }
    $scale = 100000.0
    $r = Get-Random -Minimum 0 -Maximum ([int]$scale)
    return [double]($min + ($max - $min) * ($r / $scale))
}

# 在工作区内随机挑一个「放得下窗口」的目标点。
#
#   $wa     ：工作区（含 Left/Top/Right/Bottom，通常是 SystemParameters::WorkArea）
#   $winW/H ：窗口当前尺寸（窗口是 SizeToContent，会随气泡变化）
#   $curX/Y ：当前左上角，用于保证新目标离得够远（否则原地小挪看不出在动）
#   $minDist：期望的最小位移；挑不到就退化为「离当前最远的那个角」
#
# 返回 @{ x; y }，**保证落在工作区内**（即使窗口比工作区还大，也会夹到左/上边界）。
function Get-WanderTarget($wa, [double]$winW, [double]$winH, [double]$curX, [double]$curY, [int]$minDist = 120) {
    $minX = [double]$wa.Left
    $minY = [double]$wa.Top
    $maxX = [double]$wa.Right - $winW
    $maxY = [double]$wa.Bottom - $winH
    # 窗口比工作区还大（气泡很长 / 缩放很大）时，退化为贴住左上角
    if ($maxX -lt $minX) { $maxX = $minX }
    if ($maxY -lt $minY) { $maxY = $minY }

    $minDist2 = [double]$minDist * [double]$minDist
    $first = $null
    for ($i = 0; $i -lt 12; $i++) {
        $x = Get-RandDouble $minX $maxX
        $y = Get-RandDouble $minY $maxY
        if ($null -eq $first) { $first = @{ x = $x; y = $y } }
        $dx = $x - $curX
        $dy = $y - $curY
        if (($dx * $dx + $dy * $dy) -ge $minDist2) {
            return @{ x = $x; y = $y }
        }
    }

    # 兜底：随机的那些点都太近 → 用「离当前最远的角」。
    # 这样至少真的会走一段（而不是原地打转），且仍然在界内。
    $corners = @(
        @{ x = $minX; y = $minY },
        @{ x = $maxX; y = $minY },
        @{ x = $minX; y = $maxY },
        @{ x = $maxX; y = $maxY }
    )
    $best = $corners[0]
    $bestD2 = -1.0
    foreach ($c in $corners) {
        $dx = [double]$c.x - $curX
        $dy = [double]$c.y - $curY
        $d2 = $dx * $dx + $dy * $dy
        if ($d2 -gt $bestD2) { $bestD2 = $d2; $best = $c }
    }
    # 如果连「最远的角」都在 minDist 之内（工作区实在太小），就退回第一个随机点
    if ($bestD2 -lt $minDist2 -and $null -ne $first) { return $first }
    return @{ x = [double]$best.x; y = [double]$best.y }
}

# 朝目标走一步（每帧调用）。
#
# 返回 @{ x; y; arrived; dir; dist }：
#   arrived = $true 时 x/y 就是目标点本身（**保证不会冲过头**）
#   dir     = 'running-right' / 'running-left'（朝右/朝左走；纯竖直移动时按 0 处理取右）
#
# 用「单位向量 × 速度」，所以无论斜着走还是直着走，速度都一致 ——
# 否则对角线方向会快 √2 倍，看起来像在窜。
function Get-WanderStep([double]$curX, [double]$curY, [double]$tx, [double]$ty, [double]$speed) {
    $dx = $tx - $curX
    $dy = $ty - $curY
    $dist = [math]::Sqrt($dx * $dx + $dy * $dy)
    if ($speed -le 0) { $speed = 1.0 }
    if ($dist -le $speed -or $dist -le 0.0001) {
        return @{ x = [double]$tx; y = [double]$ty; arrived = $true; dir = $null; dist = $dist }
    }
    $nx = $curX + ($dx / $dist) * $speed
    $ny = $curY + ($dy / $dist) * $speed
    $dir = 'running-right'
    if ($dx -lt 0) { $dir = 'running-left' }
    return @{ x = $nx; y = $ny; arrived = $false; dir = $dir; dist = $dist }
}

# 把点夹进「窗口能完整落在工作区内」的范围。窗口/工作区随时可能变（气泡变长、
# 任务栏移动），所以每帧应用前都夹一次，确保小宠不会跑到屏幕外找不回来。
function Get-WanderClamped($wa, [double]$winW, [double]$winH, [double]$x, [double]$y) {
    $minX = [double]$wa.Left
    $minY = [double]$wa.Top
    $maxX = [double]$wa.Right - $winW
    $maxY = [double]$wa.Bottom - $winH
    if ($maxX -lt $minX) { $maxX = $minX }
    if ($maxY -lt $minY) { $maxY = $minY }
    $cx = [double]$x
    $cy = [double]$y
    if ($cx -lt $minX) { $cx = $minX }
    if ($cx -gt $maxX) { $cx = $maxX }
    if ($cy -lt $minY) { $cy = $minY }
    if ($cy -gt $maxY) { $cy = $maxY }
    return @{ x = $cx; y = $cy }
}

# 这一帧到底允不允许移动？
#
# **放在模块里**（而不是内联在 Update-Wander）是为了能被自测直接调用 ——
# 否则测试只能自己复制一份判断逻辑，那份副本可能跟产品代码悄悄不一致，
# 测试照样全绿却什么也没保证。
#
# $ctx 是哈希表，字段容错（缺字段 = 不构成阻碍）：
#   enabled / paused / dragging / hover / menuOpen / waiting / approvalCount / winLeft / winTop
function Test-WanderAllowed($ctx) {
    $pick = {
        param($name, $default)
        if ($null -ne $ctx -and $ctx.ContainsKey($name) -and $null -ne $ctx[$name]) { return $ctx[$name] }
        return $default
    }
    if (-not [bool](& $pick 'enabled' $false)) { return $false }        # 功能没开
    if ([bool](& $pick 'paused' $false)) { return $false }             # 暂停 = 冻结小宠
    if ([bool](& $pick 'dragging' $false)) { return $false }           # 别跟鼠标抢窗口
    if ([bool](& $pick 'hover' $false)) { return $false }              # 用户想点它
    if ([bool](& $pick 'menuOpen' $false)) { return $false }           # 右键/托盘菜单开着：别跑走
    if ([bool](& $pick 'waiting' $false)) { return $false }            # 等你介入，别把按钮移走
    if ([int](& $pick 'approvalCount' 0) -gt 0) { return $false }      # 审批面板正显示
    $lx = & $pick 'winLeft' 0.0
    $ty = & $pick 'winTop' 0.0
    if ([double]::IsNaN([double]$lx) -or [double]::IsNaN([double]$ty)) { return $false }   # 还没布局
    return $true
}

# 点是否落在矩形内（含边）。用来判断光标是在小宠身体上，还是只在气泡/透明区。
function Test-PointInRect([double]$x, [double]$y, [double]$left, [double]$top, [double]$right, [double]$bottom) {
    return ($x -ge $left -and $x -le $right -and $y -ge $top -and $y -le $bottom)
}

# 悬停暂停要「停够一会儿」才生效。
# 透明分层窗的 MouseEnter/Leave 会丢、会抖：宠物自己走进光标、或鼠标只是路过，
# 立刻把 wander 刹停，观感就是「自己走着走着卡停一下」。
# $prev: @{ overSince; paused }；$over=光标是否在身体上；$dwellMs=最短悬停毫秒。
function Get-HoverPauseState($prev, [bool]$over, $now, [int]$dwellMs = 300) {
    if ($dwellMs -lt 0) { $dwellMs = 0 }
    if (-not $over) {
        return @{ overSince = $null; paused = $false }
    }
    $since = $null
    if ($null -ne $prev -and $prev.ContainsKey('overSince') -and $null -ne $prev.overSince) {
        $since = $prev.overSince
    }
    if ($null -eq $since) { $since = $now }
    $elapsed = 0.0
    try { $elapsed = ([datetime]$now - [datetime]$since).TotalMilliseconds } catch { $elapsed = 0.0 }
    return @{
        overSince = $since
        paused    = ($elapsed -ge [double]$dwellMs)
    }
}

# =====================================================================
#  DPI 缩放换算 + 位置夹紧 + 拖拽落点（跨分辨率 / 拖动跟手）
# =====================================================================
#  不碰 WPF，可脱离桌宠自测（tests/test-position.ps1）。
#
#  坐标单位约定（踩过的坑）：
#    - 鼠标 PointToScreen / GetCursorPos / SetWindowPos 用**物理像素**；
#    - $window.Left/Top 是 WPF **DIP**；
#    - 两者只在 100% 缩放时相等。125%/150% 时把像素位移直接加到 Left/Top，
#      桌宠会比鼠标快，再叠上 SizeChanged 回拉，就是「拖着卡、跟不住」。
#  物理位移必须先除以窗口当前 DPI 缩放比再累加。

# 物理像素位移 → DIP 位移。$scale 是窗口当前 DPI 缩放比（TransformToDevice.M11）。
# $scale <= 0 属于异常输入，按 1:1 原样返回（宁可退回旧行为，也不除零）。
function Convert-PxToDip([double]$px, [double]$scale) {
    if ($scale -le 0) { return $px }
    return $px / $scale
}

# 把窗口左上角 (x, y) 夹进虚拟屏幕范围。
#
#   $bounds ：@{ Left; Top; Right; Bottom }（虚拟屏幕；Left/Top 允许为负 ——
#             副屏在主屏左侧/上方时就是这样表示的）
#   $winW/H ：窗口尺寸（与 $x/$y/$bounds 同一单位：DIP 或像素都可以）
#   $keepPx ：$keepPx <= 0 时**完整夹紧**（窗口整个落在屏内，位置恢复 / wander 用）；
#             $keepPx > 0 时**部分可见夹紧**（允许越界但至少 $keepPx 宽/高留在屏内，
#             拖拽实时夹紧用 —— 贴边拖动不被硬拽回，又不会整个飞出屏幕找不回来）。
#
# 返回 @{ x; y }；窗口比屏还大时退化为贴住左上角（与 Get-WanderClamped 一致）。
function Get-ClampedPos($bounds, [double]$winW, [double]$winH, [double]$x, [double]$y, [double]$keepPx = 0.0) {
    $minX = [double]$bounds.Left
    $minY = [double]$bounds.Top
    $maxX = [double]$bounds.Right
    $maxY = [double]$bounds.Bottom
    if ($keepPx -le 0) {
        $minKeepX = $minX
        $minKeepY = $minY
        $limitX = $maxX - $winW
        $limitY = $maxY - $winH
    } else {
        $minKeepX = $minX - $winW + $keepPx
        $minKeepY = $minY - $winH + $keepPx
        $limitX = $maxX - $keepPx
        $limitY = $maxY - $keepPx
    }
    if ($limitX -lt $minKeepX) { $limitX = $minKeepX }
    if ($limitY -lt $minKeepY) { $limitY = $minKeepY }
    $cx = [double]$x
    $cy = [double]$y
    if ($cx -lt $minKeepX) { $cx = $minKeepX }
    if ($cx -gt $limitX) { $cx = $limitX }
    if ($cy -lt $minKeepY) { $cy = $minKeepY }
    if ($cy -gt $limitY) { $cy = $limitY }
    return @{ x = $cx; y = $cy }
}

# 一次拖拽 MouseMove 的落点：起点 + 像素位移（按 DPI 换成与起点相同的单位）+ 可选夹紧。
# $bounds 为 $null 时只换算、不夹紧（便于单测「纯位移」）。
# 返回 @{ left; top; moved; dir; deltaX; deltaY }
function Get-DragWindowPos(
    [double]$startLeft, [double]$startTop,
    [double]$deltaPxX, [double]$deltaPxY,
    [double]$scale,
    $bounds, [double]$winW, [double]$winH, [double]$keepPx = 40.0
) {
    $dx = Convert-PxToDip $deltaPxX $scale
    $dy = Convert-PxToDip $deltaPxY $scale
    $moved = ([math]::Abs($dx) -gt 3.0 -or [math]::Abs($dy) -gt 3.0)
    $dir = 'running-right'
    if ($dx -lt -2.0) { $dir = 'running-left' }
    elseif ($dx -gt 2.0) { $dir = 'running-right' }
    $nx = $startLeft + $dx
    $ny = $startTop + $dy
    if ($null -ne $bounds) {
        $c = Get-ClampedPos $bounds $winW $winH $nx $ny $keepPx
        $nx = [double]$c.x
        $ny = [double]$c.y
    }
    return @{
        left   = $nx
        top    = $ny
        moved  = $moved
        dir    = $dir
        deltaX = $dx
        deltaY = $dy
    }
}

# 动画/轮询这一帧该干什么。拖拽时冻结气泡与磁盘/网络轮询：
# SizeToContent 一改文字就会改窗口尺寸，SizeChanged 再去改 Left/Top，
# 跟鼠标抢位置，这是 100% DPI 下「拖着卡」的主因。
function Get-PetTickPlan($ctx) {
    $dragging = $false
    $paused = $false
    $menuOpen = $false
    $walking = $false
    if ($null -ne $ctx) {
        if ($ctx.ContainsKey('dragging') -and $null -ne $ctx.dragging) { $dragging = [bool]$ctx.dragging }
        if ($ctx.ContainsKey('paused') -and $null -ne $ctx.paused) { $paused = [bool]$ctx.paused }
        if ($ctx.ContainsKey('menuOpen') -and $null -ne $ctx.menuOpen) { $menuOpen = [bool]$ctx.menuOpen }
        if ($ctx.ContainsKey('walking') -and $null -ne $ctx.walking) { $walking = [bool]$ctx.walking }
    }
    $holdSize = ($dragging -or $menuOpen -or $walking)
    return @{
        updateSprite = ((-not $paused) -and (-not $menuOpen))
        updateChrome = (-not $holdSize)
        wander       = ((-not $dragging) -and (-not $paused) -and (-not $menuOpen))
        poll         = (-not $holdSize)
    }
}
