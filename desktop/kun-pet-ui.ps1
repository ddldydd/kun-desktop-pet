# =====================================================================
#  Kun Like 桌宠 · 纯 UI 辅助函数
# =====================================================================
#  这里只放「不碰 WPF 对象」的纯函数，好处是能脱离桌宠单独自测
#  （见 tests/test-notice.ps1）。需要访问 $window / $state 的部分留在
#  kun-pet-desktop.ps1 里。
# =====================================================================

# 决定气泡当前该显示什么。
#
# 优先级：**临时提示 > 常态文案**。
# 临时提示用于「检查更新」这类有时效的操作反馈 —— 用户点了菜单就期待看到回应，
# 所以它必须盖过「等待介入」「进行中」这些常态文案。
#
# 参数：
#   $normalText   常态下该显示的文案（由调用方按模式/动作算好）
#   $noticeText   临时提示（空 = 没有）
#   $noticeUntil  提示的过期时间
#   $now          当前时间（显式传入便于测试）
#
# 返回 @{ bubble; noticeText }：
#   bubble     = 这一帧要显示的文字
#   noticeText = 处理后的提示状态（**已过期会返回空串**，调用方据此清掉状态，
#                不要让它一直留着 —— 否则过期判断每帧都走一遍 elseif 分支）
function Resolve-BubbleText([string]$normalText, [string]$noticeText, $noticeUntil, $now) {
    $bubble = [string]$normalText
    $notice = [string]$noticeText
    if ($notice) {
        $expired = $true
        try { $expired = -not ($now -lt $noticeUntil) } catch { $expired = $true }
        if (-not $expired) {
            $bubble = $notice
        } else {
            $notice = ''    # 过期：清掉状态
        }
    }
    return @{ bubble = $bubble; noticeText = $notice }
}

# 决定气泡**该不该显示**。
#
# 背景：没有任务时气泡以前永远挂着「怎么还不来找我~有事找我」——
# 它不携带任何信息，还一直占着桌面。现在改为：只有「有话可说」时才显示，
# 没话说时保留一小段宽限期（让状态切换有个过渡），然后整体收起
# （含小尾巴），只留小宠本身。
#
# 「有话可说」由调用方判断（等待审批/提问、临时提示、任务进展、
# 点击反应、出错都算）；这里只负责计时与翻转。
#
# 参数：
#   $worth      这一帧是否有值得显示的内容
#   $idleSince  上一次返回的 idleSince（$null = 之前一直有话说，还没开始计时）
#   $now        当前时间
#   $graceMs    没话说后还能再显示多少毫秒
#
# 返回 @{ visible; idleSince }：
#   visible   = 这一帧气泡是否显示
#   idleSince = 传回给下一帧的计时起点（有话说时清回 $null）
function Resolve-BubbleVisibility([bool]$worth, $idleSince, $now, [int]$graceMs = 6000) {
    if ($worth) { return @{ visible = $true; idleSince = $null } }
    $since = $idleSince
    if ($null -eq $since) { $since = $now }   # 刚进入「没话说」：从现在开始计时
    $visible = $true
    try { $visible = (($now - $since).TotalMilliseconds -lt $graceMs) } catch { $visible = $true }
    return @{ visible = $visible; idleSince = $since }
}

# =====================================================================
#  气泡（信息框）配色
# =====================================================================
#  需求：信息框颜色要能改 —— 比如换成「系统深色面板那种深底 + 白字」。
#
#  这里只做**纯字符串计算**（不碰 WPF 对象），好处与上面几个函数相同：
#  能脱离桌宠单独自测（tests/test-bubble-theme.ps1 直接调它）。
#  真正的画刷（Brush）在 kun-pet-desktop.ps1 的 Apply-BubbleTheme 里创建。
#
#  主题：
#    light  浅色（历来默认：半透明白底 + 深灰字）
#    dark   深色（深灰底 + 白字，接近 Windows 深色模式的面板）
#    system 跟随系统（读 HKCU\...\Themes\Personalize\AppsUseLightTheme）
#    custom 自定义（底色手填；文字色可手填，留空则按底色亮度自动配对比色）

# 把用户输入的颜色规整成 '#AARRGGBB'；看不懂就返回 $null。
# 绝不抛异常：菜单里输入的值直接进这里，抛异常会让菜单点击无声失败。
# 接受 #RGB / #RRGGBB / #AARRGGBB，带不带 '#' 都行，大小写随意。
function Convert-BubbleColor([string]$spec) {
    $s = [string]$spec
    if (-not $s) { return $null }
    $s = $s.Trim()
    if ($s.StartsWith('#')) { $s = $s.Substring(1) }
    if ($s.Length -eq 3) {
        $expanded = ''
        foreach ($ch in $s.ToCharArray()) { $expanded = $expanded + [string]$ch + [string]$ch }
        $s = $expanded
    }
    if ($s.Length -eq 6) { $s = 'FF' + $s }
    if (-not ($s -match '^[0-9A-Fa-f]{8}$')) { return $null }
    return ('#' + $s.ToUpperInvariant())
}

# 取 RGB 分量（忽略 alpha：判断明暗时 alpha 不参与）
function Get-BubbleColorRgb([string]$hex) {
    $c = Convert-BubbleColor $hex
    if (-not $c) { return $null }
    return @{
        r = [Convert]::ToInt32($c.Substring(3, 2), 16)
        g = [Convert]::ToInt32($c.Substring(5, 2), 16)
        b = [Convert]::ToInt32($c.Substring(7, 2), 16)
    }
}

# 底色是不是「暗色」。阈值 0.5：用的感知亮度加权（绿最亮、蓝最暗），
# 比简单平均更贴近肉眼感受（纯红 #FF0000 会被判成暗色，白字压在红底上确实更清楚）。
function Get-BubbleColorIsDark([string]$hex) {
    $rgb = Get-BubbleColorRgb $hex
    if (-not $rgb) { return $false }
    $lum = (0.2126 * $rgb.r + 0.7152 * $rgb.g + 0.0722 * $rgb.b) / 255.0
    return ($lum -lt 0.5)
}

# Windows 当前是深色还是浅色（应用主题，不是任务栏主题）。
# 读不到注册表就按浅色：旧版本一直用浅色，不能因为读失败就突然变成深色。
function Get-SystemThemeIsDark {
    try {
        $p = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop
        if ($null -ne $p.AppsUseLightTheme) { return ([int]$p.AppsUseLightTheme -eq 0) }
    } catch { }
    return $false
}

# 把前景色按权重混到底色里（0.72 = 前景七成、底色三成）。
# 用于从「底色 + 文字色」自动派生出二级文字（进展行）与底部提示的颜色，
# 自定义配色时不用让用户填四五种颜色。
function Get-MixedBubbleColor([string]$fg, [string]$bg, [double]$fgWeight) {
    $a = Get-BubbleColorRgb $fg
    $b = Get-BubbleColorRgb $bg
    if (-not $a) { return $fg }
    if (-not $b) { return $fg }
    $w = [double]$fgWeight
    if ($w -lt 0) { $w = 0 }
    if ($w -gt 1) { $w = 1 }
    $r = [int][math]::Round($a.r * $w + $b.r * (1 - $w))
    $g = [int][math]::Round($a.g * $w + $b.g * (1 - $w))
    $bl = [int][math]::Round($a.b * $w + $b.b * (1 - $w))
    return ('#FF{0:X2}{1:X2}{2:X2}' -f $r, $g, $bl)
}

# 两套内置调色板。
# 等待提示（提问=琥珀 / 审批=绿）也要跟着主题走：浅色主题用浅底，
# 深色主题用同色系的暗底，否则深色气泡一进等待状态就突然闪回一块白底。
function New-BubblePalette([bool]$dark) {
    if ($dark) {
        return @{
            dark                = $true
            bg                  = '#F21F1F1F'
            border              = '#33FFFFFF'
            text                = '#FFFFFFFF'
            sub                 = '#FFC0C0C0'
            hint                = '#FF9A9A9A'
            waitQuestion        = '#F2433014'
            waitQuestionBorder  = '#FFE0A64B'
            waitApproval        = '#F2183320'
            waitApprovalBorder  = '#FF4CAF50'
        }
    }
    return @{
        dark                = $false
        bg                  = '#F5FFFFFF'
        border              = '#1A000000'
        text                = '#FF333333'
        sub                 = '#FF888888'
        hint                = '#FF666666'
        waitQuestion        = '#FFFFF4DC'
        waitQuestionBorder  = '#FFE0A64B'
        waitApproval        = '#FFE8F6EA'
        waitApprovalBorder  = '#FF4CAF50'
    }
}

# 主题名 + 自定义色 → 一份完整的调色板（全是 '#AARRGGBB' 字符串）。
function Get-BubblePalette([string]$theme, [string]$customBg = '', [string]$customText = '') {
    $t = ([string]$theme)
    if ($t) { $t = $t.Trim().ToLowerInvariant() } else { $t = 'light' }
    if ($t -eq 'system') {
        if (Get-SystemThemeIsDark) { $t = 'dark' } else { $t = 'light' }
    }

    if ($t -eq 'custom') {
        $bg = Convert-BubbleColor $customBg
        # 底色填错/没填：按深色处理 —— 用户点「自定义」通常就是嫌白底刺眼，
        # 退回浅色会让这次点击看起来像没生效。
        if (-not $bg) { $bg = '#F21F1F1F' }
        $dark = Get-BubbleColorIsDark $bg
        $fg = Convert-BubbleColor $customText
        if ($fg) {
            # 自填了近色（文字和底色一样深/一样浅）时强制换成对比色，否则字看不清
            if ((Get-BubbleColorIsDark $fg) -eq $dark) {
                if ($dark) { $fg = '#FFFFFFFF' } else { $fg = '#FF111111' }
            }
        } else {
            if ($dark) { $fg = '#FFFFFFFF' } else { $fg = '#FF1A1A1A' }
        }
        $pal = New-BubblePalette $dark
        $pal.bg = $bg
        $pal.text = $fg
        if ($dark) { $pal.border = '#33FFFFFF' } else { $pal.border = '#1A000000' }
        $pal.sub = Get-MixedBubbleColor $fg $bg 0.72
        $pal.hint = Get-MixedBubbleColor $fg $bg 0.50
        return $pal
    }

    if ($t -eq 'dark') { return (New-BubblePalette $true) }
    return (New-BubblePalette $false)
}
