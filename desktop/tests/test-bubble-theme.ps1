# 「气泡（信息框）配色」的验证。
#
# 背景：用户要能把信息框换成「系统深色面板那种深底 + 白字」。配色逻辑全在
# kun-pet-ui.ps1 的纯函数里（Convert-BubbleColor / Get-BubblePalette / ...），
# 这里**直接调产品代码**，不复制一份规则 —— 复制品会随产品代码失真而测试照样全绿。
$ErrorActionPreference = 'Stop'
$script:fail = 0; $script:pass = 0
function Check([string]$n, $a, $e) {
    $x = if ($null -eq $a) { '<null>' } else { [string]$a }
    $y = if ($null -eq $e) { '<null>' } else { [string]$e }
    if ($x -eq $y) { $script:pass++; Write-Host ("  [ok]   " + $n) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  [FAIL] {0} 期望={1} 实际={2}" -f $n, $y, $x) -ForegroundColor Red }
}
function CheckTrue([string]$n, $c) { Check $n $(if ($c) { 'True' } else { 'False' }) 'True' }

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$desktop = Split-Path -Parent $here
$mod = Join-Path $desktop 'kun-pet-ui.ps1'
if (-not (Test-Path -LiteralPath $mod)) { Write-Host ("找不到模块: " + $mod) -ForegroundColor Red; exit 1 }
. $mod
if (-not (Get-Command -Name 'Get-BubblePalette' -CommandType Function -ErrorAction SilentlyContinue)) {
    Write-Host "Get-BubblePalette 未定义" -ForegroundColor Red; exit 1
}

Write-Host ""
Write-Host "=== 1. 颜色输入规整（手填值必须容错）===" -ForegroundColor Cyan
Check '#RGB 展开' (Convert-BubbleColor '#FFF') '#FFFFFFFF'
Check '#RRGGBB 补不透明 alpha' (Convert-BubbleColor '#1f1f1f') '#FF1F1F1F'
Check '不带 # 也算数' (Convert-BubbleColor '00AACC') '#FF00AACC'
Check '#AARRGGBB 保留 alpha' (Convert-BubbleColor '#80112233') '#80112233'
Check '前后空格' (Convert-BubbleColor '  #123  ') '#FF112233'
Check '乱输入 → $null（菜单不该抛异常）' (Convert-BubbleColor 'not-a-color') $null
Check '空串 → $null' (Convert-BubbleColor '') $null
Check '#12345（位数不对）→ $null' (Convert-BubbleColor '#12345') $null
Check '字母但位数对不上 → $null（zzz 是 3 位，先被当成简写展开）' (Convert-BubbleColor 'zz') $null
Check '3 位简写照样吃（bad → bbaadd）' (Convert-BubbleColor 'bad') '#FFBBAADD'

Write-Host ""
Write-Host "=== 2. 明暗判定（决定自动配白字还是黑字）===" -ForegroundColor Cyan
Check '白色 → 不算暗' (Get-BubbleColorIsDark '#FFFFFFFF') 'False'
CheckTrue '近黑 #1F1F1F → 暗' (Get-BubbleColorIsDark '#FF1F1F1F')
CheckTrue '纯红 → 暗（白字更清楚）' (Get-BubbleColorIsDark '#FFFF0000')
Check '纯绿 → 不算暗' (Get-BubbleColorIsDark '#FF00FF00') 'False'
Check '坏值不抛异常，按浅色处理' (Get-BubbleColorIsDark 'zzz') 'False'

Write-Host ""
Write-Host "=== 3. 派生色（二级文字 / 底部提示不能黑压黑）===" -ForegroundColor Cyan
Check '白+黑 各半 → #FF808080' (Get-MixedBubbleColor '#FFFFFFFF' '#FF000000' 0.5) '#FF808080'
Check '权重 1 = 纯前景' (Get-MixedBubbleColor '#FFFFFFFF' '#FF000000' 1.0) '#FFFFFFFF'
Check '权重 0 = 纯底色' (Get-MixedBubbleColor '#FFFFFFFF' '#FF000000' 0.0) '#FF000000'
Check '越界权重被夹住（≥1）' (Get-MixedBubbleColor '#FFFFFFFF' '#FF000000' 2.0) '#FFFFFFFF'
Check '坏前景 → 原样返回，不炸' (Get-MixedBubbleColor 'nope!' '#FF000000' 0.5) 'nope!'

Write-Host ""
Write-Host "=== 4. 三个内置主题 ===" -ForegroundColor Cyan
$light = Get-BubblePalette 'light'
Check '浅色底色保持原样（半透明白）' $light.bg '#F5FFFFFF'
Check '浅色文字是深灰（历来默认）' $light.text '#FF333333'
Check '浅色边框保持原样' $light.border '#1A000000'

$dark = Get-BubblePalette 'dark'
Check '深色底色：深灰' $dark.bg '#F21F1F1F'
Check '深色文字：白' $dark.text '#FFFFFFFF'
Check '深色边框：半透明白（深底上才看得出边）' $dark.border '#33FFFFFF'
CheckTrue '深色调色板标了 dark' ($dark.dark -eq $true)
Check '深色进展行仍可读（不是纯白）' $dark.sub '#FFC0C0C0'

# 非法主题名/空主题 → 退回浅色（旧配置坏了不能让桌宠变瞎）
$fallback = Get-BubblePalette 'rainbow'
Check '非法主题 → 浅色兜底' $fallback.bg '#F5FFFFFF'
$none = Get-BubblePalette ''
Check '空主题 → 浅色兜底' $none.bg '#F5FFFFFF'

# 跟随系统：结果必须和「系统到底深不深」一致，且只能是这两套之一
$sysDark = Get-SystemThemeIsDark
$sys = Get-BubblePalette 'system'
CheckTrue '跟随系统 → 与注册表判断一致' ([bool]$sys.dark -eq [bool]$sysDark)
CheckTrue '跟随系统 → 配色就是 dark/light 其中一套' ($sys.bg -eq '#F21F1F1F' -or $sys.bg -eq '#F5FFFFFF')

Write-Host ""
Write-Host "=== 5. 等待提示色跟着主题走（不能闪回白底）===" -ForegroundColor Cyan
CheckTrue '浅色主题：提问底是浅琥珀' ($light.waitQuestion -eq '#FFFFF4DC')
CheckTrue '深色主题：提问底被换成暗琥珀' ($dark.waitQuestion -eq '#F2433014')
CheckTrue '深色主题：审批底被换成暗绿' ($dark.waitApproval -eq '#F2183320')
CheckTrue '边框色两套主题一致（语义色不随主题漂移）' ($dark.waitQuestionBorder -eq $light.waitQuestionBorder)
CheckTrue '审批边框同样是绿色' ($dark.waitApprovalBorder -eq '#FF4CAF50')

Write-Host ""
Write-Host "=== 6. 自定义颜色 ===" -ForegroundColor Cyan
# 只填深底色 → 自动白字
$c1 = Get-BubblePalette 'custom' '#1F1F1F' ''
Check '自填深底 → 自动白字' $c1.text '#FFFFFFFF'
Check '自填深底 → 底色按输入规整' $c1.bg '#FF1F1F1F'
Check '自填深底 → 边框转半透明白' $c1.border '#33FFFFFF'
CheckTrue '自填深底 → 等待提示也跟着转暗' ($c1.waitQuestion -eq '#F2433014')

# 只填浅底色 → 自动深字
$c2 = Get-BubblePalette 'custom' '#FFFFFF' ''
Check '自填白底 → 自动深字' $c2.text '#FF1A1A1A'
Check '自填白底 → 边框转半透明黑' $c2.border '#1A000000'

# 同时填文字色
$c3 = Get-BubblePalette 'custom' '#102030' '#F0E0D0'
Check '自填底色 + 自填文字色都生效' $c3.text '#FFF0E0D0'
Check '底色也生效' $c3.bg '#FF102030'

# 近色输入 → 强制换对比色（否则等于看不见）
$c4 = Get-BubblePalette 'custom' '#1F1F1F' '#FF111111'
Check '深底 + 近黑字 → 强制白字' $c4.text '#FFFFFFFF'
$c5 = Get-BubblePalette 'custom' '#FFFFFF' '#FFFFFF'
Check '白底 + 白字 → 强制深字' $c5.text '#FF111111'

# 底色填错/没填 → 退回深色（用户点自定义多半就是嫌白底刺眼）
$c6 = Get-BubblePalette 'custom' 'blue-ish' ''
Check '底色非法 → 深色兜底' $c6.bg '#F21F1F1F'
Check '底色非法 → 白字' $c6.text '#FFFFFFFF'

# 派生色必须是可用的 #AARRGGBB（WPF BrushConverter 只认这个）
$ok = $true
foreach ($k in @('bg', 'border', 'text', 'sub', 'hint', 'waitQuestion', 'waitQuestionBorder', 'waitApproval', 'waitApprovalBorder')) {
    if (-not $c3.ContainsKey($k)) { $ok = $false }
    elseif (-not ($c3[$k] -match '^#[0-9A-F]{8}$')) { $ok = $false }
}
CheckTrue '自定义调色板键齐全且都是 #AARRGGBB' $ok
foreach ($k in @('bg', 'border', 'text', 'sub', 'hint', 'waitQuestion', 'waitQuestionBorder', 'waitApproval', 'waitApprovalBorder')) {
    if (-not ($light[$k] -match '^#[0-9A-F]{8}$')) { $ok = $false }
    if (-not ($dark[$k] -match '^#[0-9A-F]{8}$')) { $ok = $false }
}
CheckTrue '两套内置调色板也全是 #AARRGGBB' $ok

Write-Host ""
Write-Host "=== 7. 设置读取：主题真的能从磁盘读进来（回归防护）===" -ForegroundColor Cyan
# 这段只能做源码级断言：Load-Settings 依赖 WPF 的 $window/$state，脱离桌宠跑不起来。
# 但要防的坑很具体：v2.4.5 把 animSpeed 写成 TryParse(string, IFormatProvider, out double)
# —— 这个重载不存在，一抛异常整段 Load-Settings 就中断（catch 在外面），
# 于是「位置」「气泡配色」这些排在它后面的字段全部读不进来（每次启动回默认位置）。
$srcPath = Join-Path $desktop 'kun-pet-desktop.ps1'
$src = Get-Content -Raw -Path $srcPath -Encoding UTF8
Check '源码里没有 TryParse 的坏重载（它会让整段 Load-Settings 中断）' `
    ($src -match 'TryParse\(\[string\]\$as,\s*\[System\.Globalization\.CultureInfo\]') 'False'

# 脚本里实际用的那个 4 参数重载必须可用
$asn = 0.0
$ok4 = [double]::TryParse('1.5', [System.Globalization.NumberStyles]::Float,
    [System.Globalization.CultureInfo]::InvariantCulture, [ref]$asn)
CheckTrue '4 参数 TryParse 可用且解析正确' ($ok4 -and $asn -eq 1.5)

# 气泡配色的读取顺序要排在 animSpeed 之前（否则一坏就陪葬）
$iBubble = $src.IndexOf('$saved.bubbleTheme')
$iAnim = $src.IndexOf('$saved.animSpeed')
CheckTrue 'bubbleTheme 的读取排在 animSpeed 之前' ($iBubble -gt 0 -and $iAnim -gt 0 -and $iBubble -lt $iAnim)

Write-Host ""
if ($script:fail -eq 0) { Write-Host ("全部通过：{0} 项" -f $script:pass) -ForegroundColor Green; exit 0 }
else { Write-Host ("失败 {0} 项 / 通过 {1} 项" -f $script:fail, $script:pass) -ForegroundColor Red; exit 1 }
