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
#   enabled / paused / dragging / hover / waiting / approvalCount / winLeft / winTop
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
    if ([bool](& $pick 'waiting' $false)) { return $false }            # 等你介入，别把按钮移走
    if ([int](& $pick 'approvalCount' 0) -gt 0) { return $false }      # 审批面板正显示
    $lx = & $pick 'winLeft' 0.0
    $ty = & $pick 'winTop' 0.0
    if ([double]::IsNaN([double]$lx) -or [double]::IsNaN([double]$ty)) { return $false }   # 还没布局
    return $true
}

# =====================================================================
#  DPI 缩放换算 + 位置夹紧（跨分辨率 / 多屏安全）
# =====================================================================
#  拖拽修复与位置恢复共用的纯函数，不碰 WPF，可脱离桌宠自测（tests/test-position.ps1）。
#
#  坐标单位约定（踩过的坑，务必看）：
#    - 鼠标事件里 $window.PointToScreen(...) 返回**物理像素**；
#    - $window.Left/Top 是 WPF **DIP（逻辑单位）**；
#    - 两者只在 100% 缩放时相等。125%/150% 时物理位移是 DIP 位移的 1.25/1.5 倍，
#      直接把物理位移累加到 Left/Top 会让桌宠跑得比鼠标快，表现就是「按不住 / 拖不动」。
#  所以物理位移必须先除以窗口当前的 DPI 缩放比再累加。

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
#   $winW/H ：窗口尺寸（DIP）
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
        # 完整夹紧：左上角 x∈[minX, maxX-winW]，即窗口右/下边不越过屏的右/下边
        $minKeepX = $minX
        $minKeepY = $minY
        $limitX = $maxX - $winW
        $limitY = $maxY - $winH
    } else {
        # 部分可见：允许越界，但至少 $keepPx 宽/高落在屏内
        $minKeepX = $minX - $winW + $keepPx
        $minKeepY = $minY - $winH + $keepPx
        $limitX = $maxX - $keepPx
        $limitY = $maxY - $keepPx
    }
    # 窗口比「合法带」还大（缩放很大 / 气泡很长）：退化为贴住左上角
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
