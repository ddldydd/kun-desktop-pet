<#
  Kun Like 桌宠 · 桌面版 v2（对齐 Codex / petdex 桌宠规格）

  对齐的 Codex 桌宠功能：
    - 9 个标准状态：idle / running-right / running-left / waving / jumping /
      failed / waiting / running / review
    - 单击 = 挥手(waving)，双击 = 跳一下(jumping)，拖动 = 移动（带方向跑动）
    - 16 个待机视线方向，从正上方开始顺时针轮转
    - 托盘/右键菜单：角色、动作、大小、暂停、鼠标穿透、位置重置、退出
    - 每次工具调用都有动画反应；任务完成跳跃 + 提示音 + 托盘通知

  素材：
    - 若检测到 petdex/Codex 桌宠（~/.petdex/pets/<slug>/ 或 ~/.codex/pets/<id>/
      下的 pet.json + spritesheet.webp|png），直接按 8×9 / 8×11、192×208 贴图渲染
    - 否则使用内置矢量形象（零素材依赖）

  任务状态来源（自动降级）：
    1) DSH 插件接口  http://127.0.0.1:19387/kun-pet/state
    2) DSH 会话目录活跃度  ~/.dsh/sessions
#>

$ErrorActionPreference = 'Continue'

# ---------------- 配置 ----------------
# PowerShell 5.1 不允许 if 作为表达式出现在参数位置，先算好常量
$script:codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
# 日志与设置必须固定放在脚本所在目录，否则「双击启动」和「开机自启启动」会各自读写
# 不同的 kun-pet-settings.json，导致换个方式启动就恢复不出上次的宠物。
# 三个启动器都通过 ScriptBlock::Create 执行脚本，此时 $PSScriptRoot 为空，
# 所以由启动器显式传入 $cwd；直接运行 .ps1 时回退到命令自身路径。
$script:logDir = $null
if ($cwd) { $script:logDir = [string]$cwd }
if (-not $script:logDir) {
    try {
        $cmdPath = $MyInvocation.MyCommand.Path
        if (-not $cmdPath) { $cmdPath = $PSCommandPath }
        if ($cmdPath) { $script:logDir = Split-Path -Parent $cmdPath }
    } catch { }
}
if (-not $script:logDir -and $PSScriptRoot) { $script:logDir = $PSScriptRoot }
if (-not $script:logDir) { $script:logDir = (Get-Location).Path }

$Config = @{
    StateUrl    = 'http://127.0.0.1:19387/kun-pet/state'
    SessionsDir = Join-Path $env:USERPROFILE '.dsh\sessions'
    # DSH 会话投影缓存（明文 JSON，桌宠读取任务进展的主数据源）
    ProjCacheDir = Join-Path $env:USERPROFILE '.dsh\storages\session_projcache\sessions'
    PetDirs     = @(
        (Join-Path $env:USERPROFILE '.petdex\pets'),
        (Join-Path $script:codexHome 'pets')
    )
    PollMs      = 500
    AnimFpsMs   = 40
    DefaultCols = 8
    DefaultRows = 9
    DefaultCellW = 192
    DefaultCellH = 208
    Scale       = 0.62
    LogFile     = Join-Path $script:logDir 'kun-pet-desktop.log'
}

function Write-Log([string]$msg) {
    try {
        Add-Content -Path $Config.LogFile -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
    } catch { }
}
Write-Log 'kun-pet-desktop v2 starting'

# ---------------- 单实例 ----------------
$mutex = $null
try {
    $mutex = [System.Threading.Mutex]::new($false, 'Local\KunPetDesktopPet')
    if (-not $mutex.WaitOne(0)) { Write-Log 'already running; exit'; exit 0 }
} catch { }

# ---------------- 程序集 ----------------
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
    # 自定义大小输入框需要 VB 交互程序集（Windows 自带）
    Add-Type -AssemblyName Microsoft.VisualBasic
} catch {
    Write-Log ("assembly load failed: " + $_.Exception.Message); exit 1
}

# 鼠标穿透需要 Win32 扩展样式
$script:clickThroughAvailable = $false
try {
    Add-Type -Namespace KunPet -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
'@
    $script:clickThroughAvailable = $true
} catch {
    Write-Log ("win32 interop unavailable: " + $_.Exception.Message)
}

# 素材逐行扫描：petdex/Codex 的精灵图每行末尾常有「空帧」（整格全透明），
# 固定按 8 列循环会让小宠周期性消失一瞬——这就是频闪的根源。
# 这里一次性扫出每行真正有内容的列号，动画只在这些列之间循环。
$script:spriteScanAvailable = $false
try {
    Add-Type -TypeDefinition @'
using System.Collections.Generic;
namespace KunPet {
    public static class SpriteScan {
        // bgra: BGRA32 像素缓冲（alpha 在第 4 字节）；返回每行有内容的列号列表
        public static int[][] UsableCols(byte[] bgra, int stride, int width, int height, int cols, int rows) {
            int[][] res = new int[rows][];
            for (int r = 0; r < rows; r++) {
                List<int> list = new List<int>();
                for (int c = 0; c < cols; c++) {
                    int x0 = (int)((long)c * width / cols);
                    int x1 = (int)((long)(c + 1) * width / cols);
                    int y0 = (int)((long)r * height / rows);
                    int y1 = (int)((long)(r + 1) * height / rows);
                    bool any = false;
                    for (int y = y0; y < y1 && !any; y += 2) {
                        int rowBase = y * stride;
                        for (int x = x0; x < x1; x += 2) {
                            if (bgra[rowBase + x * 4 + 3] > 8) { any = true; break; }
                        }
                    }
                    if (any) list.Add(c);
                }
                if (list.Count == 0) list.Add(0);
                res[r] = list.ToArray();
            }
            return res;
        }
    }
}
'@
    $script:spriteScanAvailable = $true
} catch {
    Write-Log ("sprite scan helper unavailable: " + $_.Exception.Message)
}

# ---------------- 标准状态（与 Codex 桌宠九行一致） ----------------
$StateKeys = @('idle', 'running-right', 'running-left', 'waving', 'jumping', 'failed', 'waiting', 'running', 'review')

# DSH 状态 -> Codex 桌宠状态
$ModeToActionMap = @{
    idle          = 'idle'
    working       = 'running'
    review        = 'review'
    waiting       = 'waiting'
    failed        = 'failed'
    celebrating   = 'jumping'
    disconnected  = 'idle'
    dragging      = 'running-right'
}

$BubbleMap = @{
    'idle'          = '怎么还不来找我~有事找我'
    'running'       = '我先去干活啦！'
    'review'        = '让我看看...嘿！'
    'waiting'       = '能不能快点啊？(ー`ー)'
    'failed'        = '卧槽！出事了！(・_・;)'
    'jumping'       = '搞定收工~（≧∇≦）ﾉ'
    'waving'        = '嗨~ 在的在的！'
    'running-right' = '我去那边看看~'
    'running-left'  = '我回这边啦~'
    'disconnected'  = 'DSH 没连上…先待机啦'
}
$BadgeMap = @{
    'idle'          = ''
    'running'       = [char]::ConvertFromUtf32(0x1F4A7)
    'review'        = [char]::ConvertFromUtf32(0x1F50D)
    'waiting'       = [char]::ConvertFromUtf32(0x23F3)
    'failed'        = [char]::ConvertFromUtf32(0x2757)
    'jumping'       = [char]::ConvertFromUtf32(0x1F389)
    'waving'        = [char]::ConvertFromUtf32(0x1F44B)
    'running-right' = [char]::ConvertFromUtf32(0x27A1)
    'running-left'  = [char]::ConvertFromUtf32(0x2B05)
    'disconnected'  = [char]::ConvertFromUtf32(0x1F50C)
}

# 各状态动画参数：浮动幅度、横向抖动、每帧毫秒
$ActionAnimMap = @{
    'idle'          = @{ amp = 3.0;  wobble = 0.0; fps = 260 }
    'running'       = @{ amp = 7.0;  wobble = 0.0; fps = 110 }
    'review'        = @{ amp = 4.0;  wobble = 0.0; fps = 180 }
    'waiting'       = @{ amp = 2.0;  wobble = 2.0; fps = 300 }
    'failed'        = @{ amp = 1.5;  wobble = 4.0; fps = 120 }
    'jumping'       = @{ amp = 13.0; wobble = 0.0; fps = 140 }
    'waving'        = @{ amp = 3.0;  wobble = 1.2; fps = 160 }
    'running-right' = @{ amp = 4.0;  wobble = 3.0; fps = 120 }
    'running-left'  = @{ amp = 4.0;  wobble = 3.0; fps = 120 }
}

# ---------------- 素材发现（petdex / Codex 桌宠） ----------------
function Find-Pets {
    $found = @()
    foreach ($dir in $Config.PetDirs) {
        try {
            if (-not (Test-Path $dir)) { continue }
            foreach ($sub in Get-ChildItem -Path $dir -Directory -ErrorAction Stop) {
                $jsonPath = Join-Path $sub.FullName 'pet.json'
                if (-not (Test-Path $jsonPath)) { continue }
                $sheet = $null
                foreach ($name in @('spritesheet.png', 'spritesheet.webp', 'spritesheet.PNG', 'spritesheet.WEBP')) {
                    $candidate = Join-Path $sub.FullName $name
                    if (Test-Path $candidate) { $sheet = $candidate; break }
                }
                if (-not $sheet) { continue }
                $meta = $null
                try { $meta = Get-Content -Raw -Path $jsonPath -Encoding UTF8 | ConvertFrom-Json } catch { $meta = $null }
                $petName = $sub.Name
                if ($meta -and $meta.name) { $petName = [string]$meta.name }
                $found += [pscustomobject]@{
                    Id      = $sub.Name
                    Name    = $petName
                    Dir     = $sub.FullName
                    Sheet   = $sheet
                    Meta    = $meta
                }
            }
        } catch {
            Write-Log ("pet scan failed in {0}: {1}" -f $dir, $_.Exception.Message)
        }
    }
    return $found
}

function Get-SheetLayout($pet) {
    $cols = $Config.DefaultCols; $rows = $Config.DefaultRows
    $cellW = $Config.DefaultCellW; $cellH = $Config.DefaultCellH
    $m = $pet.Meta
    if ($m) {
        foreach ($k in @('columns', 'cols', 'columnsCount')) { if ($m.$k) { $cols = [int]$m.$k; break } }
        foreach ($k in @('rows', 'rowsCount')) { if ($m.$k) { $rows = [int]$m.$k; break } }
        foreach ($k in @('frameWidth', 'frame_width', 'cellWidth', 'width')) { if ($m.$k) { $cellW = [int]$m.$k; break } }
        foreach ($k in @('frameHeight', 'frame_height', 'cellHeight', 'height')) { if ($m.$k) { $cellH = [int]$m.$k; break } }
    }
    return @{ cols = $cols; rows = $rows; cellW = $cellW; cellH = $cellH }
}

function Get-ActionRow([string]$action) {
    $idx = $StateKeys.IndexOf($action)
    if ($idx -lt 0) { return 0 }
    return $idx
}

# ---------------- UI ----------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Kun Pet" Width="200" Height="240"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" SizeToContent="WidthAndHeight"
        ResizeMode="NoResize" ShowActivated="False"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Grid Margin="8" Background="Transparent">
    <Grid.RenderTransform>
      <TranslateTransform x:Name="floatTransform" X="0" Y="0"/>
    </Grid.RenderTransform>
    <StackPanel>
      <Border x:Name="alertBorder" Background="#F2E8453C" CornerRadius="10"
              Padding="8,5" HorizontalAlignment="Center" Margin="0,0,0,4"
              Visibility="Collapsed">
        <TextBlock x:Name="alertText" Text="" FontSize="12" FontWeight="Bold"
                   Foreground="White" TextWrapping="Wrap" MaxWidth="184" TextAlignment="Center"/>
      </Border>
      <!-- 待审批操作面板：有权限确认时直接点「同意 / 拒绝」，不用切回 Harness -->
      <Border x:Name="approvalBorder" Background="#F52E7D32" CornerRadius="10"
              Padding="8,6" HorizontalAlignment="Center" Margin="0,0,0,4"
              Visibility="Collapsed">
        <StackPanel>
          <TextBlock x:Name="approvalText" Text="" FontSize="12" FontWeight="Bold"
                     Foreground="White" TextWrapping="Wrap" MaxWidth="184" TextAlignment="Center"
                     Margin="0,0,0,6"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
            <Button x:Name="btnApprove" Content="✓ 同意" Width="78" Height="28" Margin="0,0,8,0"
                    Background="#FF4CAF50" Foreground="White" FontWeight="Bold"
                    BorderThickness="0" Cursor="Hand" ToolTip="允许这次执行（allowed-once）"/>
            <Button x:Name="btnReject" Content="✗ 拒绝" Width="78" Height="28"
                    Background="#FFE53935" Foreground="White" FontWeight="Bold"
                    BorderThickness="0" Cursor="Hand" ToolTip="拒绝这次执行（rejected）"/>
          </StackPanel>
        </StackPanel>
      </Border>
      <!-- 气泡与小宠贴合：尾巴叠在气泡下方（Grid 叠层，不占额外行高），
           并用负边距把气泡压到贴近头顶 -->
      <Grid HorizontalAlignment="Center" Margin="0,0,10,0" Panel.ZIndex="3">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Border x:Name="bubble" Grid.Row="0" Background="#F5FFFFFF" CornerRadius="12"
                BorderBrush="#1A000000" BorderThickness="1" Padding="10,6"
                HorizontalAlignment="Center">
          <StackPanel>
            <TextBlock x:Name="bubbleText" Text="..." FontSize="13" Foreground="#333"
                       TextWrapping="Wrap" MaxWidth="176" TextAlignment="Center"/>
            <TextBlock x:Name="progressText" Text="" FontSize="10" Foreground="#888"
                       TextWrapping="Wrap" MaxWidth="176" TextAlignment="Center"
                       Margin="0,2,0,0" Visibility="Collapsed"/>
          </StackPanel>
        </Border>
        <!-- 小尾巴：负上边距使其与气泡底边无缝相接 -->
        <Path x:Name="bubbleTail" Grid.Row="1" Fill="#F5FFFFFF" Stroke="#1A000000"
              StrokeThickness="1" Data="M0,0 L8,10 L16,0 Z"
              HorizontalAlignment="Center" Margin="0,-2,0,0"/>
      </Grid>
      <Grid x:Name="petShell" Width="140" Height="140" HorizontalAlignment="Center"
            Margin="0,-18,0,0">
        <!-- LayoutTransform（而非 RenderTransform）：参与布局，整体等比缩放不裁剪 -->
        <Grid.LayoutTransform>
          <ScaleTransform x:Name="userScale" ScaleX="1" ScaleY="1"/>
        </Grid.LayoutTransform>
        <Grid>
          <Grid.RenderTransform>
            <ScaleTransform x:Name="petScale" ScaleX="1" ScaleY="1" CenterX="70" CenterY="70"/>
          </Grid.RenderTransform>
          <StackPanel x:Name="vectorPet" HorizontalAlignment="Center" VerticalAlignment="Center">
            <Grid Width="128" Height="110">
              <Canvas x:Name="whaleCanvas" Width="128" Height="110">
                <Path x:Name="tailPath" Fill="#2F7FC4" Data="M100,84 q16,-6 20,-22 q-14,2 -22,10 z"/>
                <Ellipse x:Name="bodyEllipse" Canvas.Left="22" Canvas.Top="38" Width="84" Height="68" Fill="#3A8FD4"/>
                <Ellipse x:Name="bellyEllipse" Canvas.Left="38" Canvas.Top="66" Width="52" Height="36" Fill="#EAF4FD"/>
                <Path x:Name="finPath" Fill="#2F7FC4" Data="M32,76 q-14,4 -16,18 q12,2 20,-8 z"/>
                <Ellipse x:Name="blushLeft" Canvas.Left="33" Canvas.Top="70" Width="14" Height="9" Fill="#FFB3C1" Opacity="0.8"/>
                <Ellipse x:Name="blushRight" Canvas.Left="81" Canvas.Top="70" Width="14" Height="9" Fill="#FFB3C1" Opacity="0.8"/>
                <Ellipse x:Name="eyeLeft" Canvas.Left="45" Canvas.Top="56" Width="11" Height="13" Fill="#22303C"/>
                <Ellipse x:Name="eyeRight" Canvas.Left="71" Canvas.Top="56" Width="11" Height="13" Fill="#22303C"/>
                <Ellipse x:Name="glintLeft" Canvas.Left="48" Canvas.Top="58" Width="4" Height="4" Fill="White"/>
                <Ellipse x:Name="glintRight" Canvas.Left="74" Canvas.Top="58" Width="4" Height="4" Fill="White"/>
                <Path x:Name="mouthPath" Stroke="#22303C" StrokeThickness="3" StrokeStartLineCap="Round"
                      StrokeEndLineCap="Round" Data="M56,86 q8,8 16,0"/>
                <TextBlock x:Name="badgeText" Text="" FontSize="26" Canvas.Left="96" Canvas.Top="4"/>
              </Canvas>
            </Grid>
          </StackPanel>
          <Image x:Name="sheetPet" Stretch="Uniform" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
        </Grid>
      </Grid>
      <TextBlock x:Name="hintText" Text="" FontSize="10" Foreground="#666"
                 HorizontalAlignment="Center" Margin="0,4,0,0"/>
    </StackPanel>
  </Grid>
</Window>
'@

try {
    $window = [Windows.Markup.XamlReader]::Parse($xaml)
} catch {
    Write-Log ("xaml parse failed: " + $_.Exception.Message); exit 1
}
$floatTransform = $window.FindName('floatTransform')
$petScale       = $window.FindName('petScale')
$userScaleEl    = $window.FindName('userScale')
$petShellEl     = $window.FindName('petShell')
$vectorPet      = $window.FindName('vectorPet')
$sheetPetEl     = $window.FindName('sheetPet')
$badgeTextEl    = $window.FindName('badgeText')
$bubbleTextEl   = $window.FindName('bubbleText')
$bubbleEl       = $window.FindName('bubble')
$alertBorderEl  = $window.FindName('alertBorder')
$alertTextEl    = $window.FindName('alertText')
$progressTextEl = $window.FindName('progressText')
$bubbleTailEl   = $window.FindName('bubbleTail')
$hintTextEl     = $window.FindName('hintText')
$approvalBorderEl = $window.FindName('approvalBorder')
$approvalTextEl   = $window.FindName('approvalText')
$btnApproveEl     = $window.FindName('btnApprove')
$btnRejectEl      = $window.FindName('btnReject')
$bodyEllipse    = $window.FindName('bodyEllipse')
$eyeLeftEl      = $window.FindName('eyeLeft')
$eyeRightEl     = $window.FindName('eyeRight')
$glintLeftEl    = $window.FindName('glintLeft')
$glintRightEl   = $window.FindName('glintRight')
$mouthPathEl    = $window.FindName('mouthPath')
$tailPathEl     = $window.FindName('tailPath')
$finPathEl      = $window.FindName('finPath')

try {
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $window.Left = $workArea.Right - 260
    $window.Top  = $workArea.Bottom - 320
} catch { }

# ---------------- 声音 ----------------
function New-BeepStream([double[]]$freqs, [int]$durMs, [int]$gapMs) {
    $sampleRate = 22050
    $memStream = New-Object System.IO.MemoryStream
    $writer = [System.IO.BinaryWriter]::new($memStream)
    $samples = New-Object System.Collections.Generic.List[byte]
    $spanMs = $gapMs + $durMs
    $total = [int]($freqs.Count * $spanMs / 1000.0 * $sampleRate)
    $amp = 9000
    for ($i = 0; $i -lt $total; $i++) {
        $t = $i / $sampleRate
        $idx = [int]($t * 1000 / $spanMs)
        $v = 0
        if ($idx -lt $freqs.Count) {
            $local = $t - ($idx * $spanMs / 1000.0)
            if ($local -lt ($durMs / 1000.0)) {
                $envelope = [math]::Min(1.0, $local * 20) * [math]::Exp(-3.0 * $local)
                $v = [int]($amp * $envelope * [math]::Sin(2 * [math]::PI * $freqs[$idx] * $local))
            }
        }
        $samples.Add([byte]($v -band 0xFF))
        $samples.Add([byte](($v -shr 8) -band 0xFF))
    }
    $dataLen = $samples.Count
    $writer.Write([char[]]'RIFF'); $writer.Write([int](36 + $dataLen)); $writer.Write([char[]]'WAVE')
    $writer.Write([char[]]'fmt '); $writer.Write([int]16); $writer.Write([int16]1); $writer.Write([int16]1)
    $writer.Write([int]$sampleRate); $writer.Write([int]($sampleRate * 2)); $writer.Write([int16]2); $writer.Write([int16]16)
    $writer.Write([char[]]'data'); $writer.Write([int]$dataLen)
    $writer.Write($samples.ToArray())
    $writer.Flush()
    $memStream.Position = 0
    return $memStream
}

function Play-Tones([double[]]$freqs, [int]$durMs, [int]$gapMs) {
    try {
        $stream = New-BeepStream -freqs $freqs -durMs $durMs -gapMs $gapMs
        $player = [System.Media.SoundPlayer]::new($stream)
        $script:currentPlayer = $player
        $script:currentStream = $stream
        $player.Play()
    } catch {
        Write-Log ("play sound failed: " + $_.Exception.Message)
    }
}

# ---------------- 托盘 ----------------
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Text = 'Kun Like 桌宠'
try {
    $bmp = [System.Drawing.Bitmap]::new(32, 32)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.Clear([System.Drawing.Color]::Transparent)
    $gfx.FillEllipse([System.Drawing.Brushes]::DodgerBlue, 2, 6, 28, 22)
    $gfx.FillEllipse([System.Drawing.Brushes]::White, 20, 10, 6, 5)
    $gfx.Dispose()
    $notify.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
} catch {
    $notify.Icon = [System.Drawing.SystemIcons]::Application
}

# ---------------- 状态 ----------------
$state = [hashtable]::Synchronized(@{
    mode         = 'disconnected'
    action       = 'idle'
    modeStart    = Get-Date
    seq          = -1
    lastSource   = 'none'
    reaction     = $null
    reactionEnd  = [datetime]::MinValue
    dragging     = $false
    dragDir      = 'running-right'
    paused       = $false
    clickThrough = $false
    scale        = [double]$Config.Scale
    lookIndex    = 0
    lookTick     = 0
    frame        = 0
    frameAt      = Get-Date
    petIndex     = -1
    # 素材形态：'vector' 内置矢量形象 / 'sprite' 使用已装素材
    # 用独立字段而不是 petIndex<0 判断，这样「上次选的是内置形象」也能被记住并恢复
    petMode      = 'vector'
    petId        = 'none'
    lastAlertKey = $null
    progressText = ''
    # 多任务进展展示方式：all 全部列出 / rotate 轮换切换 / single 只看最活跃
    multiTaskMode   = 'all'
    rotateSec       = 4
    taskLines       = @()
    rotateIndex     = 0
    rotateAt        = Get-Date
    rotateLastCount = -1
    approvalItems       = @()
    # 待审批信息的来源通道：'http'（插件端点，可在桌宠上点同意/拒绝）
    # 或 'file'（插件状态快照文件，只能提示、要切回 Harness 确认）
    approvalChannel     = $null
    # 这次待审批还能不能在桌宠上答（插件 answerable=false ⇒ 已交给 Harness 那只确认框）
    approvalAnswerable  = $true
    # 当前实际可用的插件通道（只用于变化时打一行日志，排查「审批时气泡没反应」）
    # 初值刻意用 'init' 这种哨兵值：启动后第一轮一定打一行，把当前通道写进日志
    dshChannel          = 'init'
    lastApprovalAlertId = $null
    alertFlashUntil = [datetime]::MinValue
    taskText = ''
    questionText = ''
    # 等待用户介入（权限审批 / 提问选择）：气泡要单独、显眼地提示这些内容。
    # waiting 由轮询写入，暂停时也会照常更新（暂停只冻结小宠动画）。
    waiting         = $false
    waitingKind     = $null      # 'approval' | 'question' | $null
    waitingSeconds  = 0
    questionHeader  = ''
    questionDetail  = ''
    questionOptions = @()
    questionMulti   = $false
    questionKind    = ''         # 'plan-review' = Agent 提交方案等批准
    questionApprove = ''
    gapPx = -18
    floating = $true
})

$script:tickErrors = 0
function Note-TickError([string]$where, $err) {
    if ($script:tickErrors -lt 25) {
        $script:tickErrors++
        Write-Log ("{0} error: {1}" -f $where, $err.Exception.Message)
    }
}

# ---------------- 素材加载 ----------------
$script:pets = @()
$script:sheetCache = @{}
$script:sheetFailures = @{}

function Load-PetSheet([int]$petIndex) {
    if ($petIndex -lt 0 -or $petIndex -ge $script:pets.Count) { return $null }
    $pet = $script:pets[$petIndex]
    if ($script:sheetCache.ContainsKey($pet.Sheet)) { return $script:sheetCache[$pet.Sheet] }
    # 失败同样缓存：否则每个动画帧都会重试解码一次（WebP 在无 WIC 编解码器时必失败）
    if ($script:sheetFailures.ContainsKey($pet.Sheet)) { return $null }
    $stream = $null
    try {
        # 用文件流而非 Uri：避免相对路径被当成非法 scheme；OnLoad 后即可关闭流
        $stream = [System.IO.File]::OpenRead($pet.Sheet)
        $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
            $stream,
            [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
            [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $frame = $decoder.Frames[0]
        $frame.Freeze()
        $layout = Get-SheetLayout $pet
        # 每行可用帧（跳过末尾空帧）：不做这一步的话，动画会走到全透明的格子上，
        # 小宠就会周期性「消失一瞬」= 频闪。
        $usable = $null
        if ($script:spriteScanAvailable) {
            try {
                $conv = [System.Windows.Media.Imaging.FormatConvertedBitmap]::new(
                    $frame, [System.Windows.Media.PixelFormats]::Bgra32, $null, 0)
                $pw = [int]$conv.PixelWidth; $ph = [int]$conv.PixelHeight
                $stride = $pw * 4
                $buf = New-Object byte[] ($stride * $ph)
                $conv.CopyPixels($buf, $stride, 0)
                $usable = [KunPet.SpriteScan]::UsableCols($buf, $stride, $pw, $ph, [int]$layout.cols, [int]$layout.rows)
            } catch {
                Note-TickError 'sprite-scan' $_
                $usable = $null
            }
        }
        if ($null -eq $usable) {
            # 扫描不可用：退化成「整行 8 列」（旧行为），至少不改变可用性
            $cols = [int]$layout.cols; $rows = [int]$layout.rows
            $usable = New-Object 'int[][]' $rows
            for ($ri = 0; $ri -lt $rows; $ri++) { $usable[$ri] = [int[]](0..($cols - 1)) }
        }
        $entry = @{ bitmap = $frame; layout = $layout; usable = $usable }
        $script:sheetCache[$pet.Sheet] = $entry
        $framesPerRow = @()
        foreach ($u in $usable) { $framesPerRow += $u.Count }
        Write-Log ("sheet loaded: {0} ({1}x{2}, {3}x{4} grid, frames/row: {5})" -f $pet.Sheet, $frame.PixelWidth, $frame.PixelHeight, $layout.cols, $layout.rows, ($framesPerRow -join ','))
        return $entry
    } catch {
        # WPF 原生不支持 WebP：加载失败即回退内置矢量形象，并记入失败缓存
        $script:sheetFailures[$pet.Sheet] = $_.Exception.Message
        Write-Log ("sheet load failed ({0}): {1}" -f $pet.Sheet, $_.Exception.Message)
        return $null
    } finally {
        if ($stream) { try { $stream.Dispose() } catch { } }
    }
}

function Test-PetLoadable([int]$petIndex) {
    # 素材是否真的能渲染（WebP 缺编解码器、文件损坏时不能）。
    # 复用 Load-PetSheet 的成功/失败缓存，因此重复调用不会重复解码。
    if ($petIndex -lt 0 -or $petIndex -ge $script:pets.Count) { return $false }
    return [bool](Load-PetSheet $petIndex)
}

function Set-PetSelection([int]$idx, [bool]$persist) {
    # 统一切换素材形态的唯一入口：调用方只需给「素材下标」，-1 = 内置形象。
    if ($idx -ge 0 -and $idx -lt $script:pets.Count -and (Test-PetLoadable $idx)) {
        $state.petMode = 'sprite'
        $state.petIndex = $idx
        $state.petId = [string]$script:pets[$idx].Id
    } else {
        # 显式选「内置形象」：用 'builtin' 记录，避免被当成「没保存过」而在下次启动回落
        $state.petMode = 'vector'
        $state.petIndex = -1
        $state.petId = 'builtin'
    }
    # 换了形象：帧缓存失效，否则会沿用上一个素材的裁剪结果
    $script:lastFrameKey = ''
    Show-PetFrame $state.action
    Rebuild-PetMenu
    if ($persist) { Save-Settings }
}

function Show-PetFrame([string]$action) {
    $sheetEntry = $null
    if ($state.petMode -eq 'sprite') { $sheetEntry = Load-PetSheet $state.petIndex }
    if (-not $sheetEntry) {
        # 内置矢量形象（含素材临时加载失败时的兜底）
        if ($vectorPet.Visibility -ne 'Visible') { $vectorPet.Visibility = 'Visible' }
        if ($sheetPetEl.Visibility -ne 'Collapsed') { $sheetPetEl.Visibility = 'Collapsed' }
        if ([double]$petShellEl.Width -ne 140 -or [double]$petShellEl.Height -ne 140) {
            $petShellEl.Width = 140
            $petShellEl.Height = 140
        }
        return
    }
    try {
        $layout = $sheetEntry.layout
        $cols = [int]$layout.cols
        $cellW = [int]$layout.cellW
        $cellH = [int]$layout.cellH
        $row = Get-ActionRow $action
        $maxRow = [int]$layout.rows - 1
        if ($row -gt $maxRow) { $row = $maxRow }
        # 只在该行真正有内容的列之间循环（素材末尾的空帧会让小宠一闪一闪）
        $usableCols = $null
        if ($sheetEntry.ContainsKey('usable') -and $sheetEntry.usable) {
            $usableCols = $sheetEntry.usable[$row]
        }
        if ($null -eq $usableCols -or $usableCols.Count -eq 0) { $usableCols = [int[]](0..([int]$layout.cols - 1)) }
        $col = [int]$usableCols[[int]($state.frame % $usableCols.Count)]
        if ($col -ge $cols) { $col = $cols - 1 }

        # 同一帧不重复解码；帧号变化才重建 CroppedBitmap（避免每帧新建造成内存增长）
        $frameKey = '{0}:{1}:{2}' -f $state.petIndex, $row, $col
        if ($script:lastFrameKey -ne $frameKey) {
            $script:lastFrameKey = $frameKey
            $rect = [System.Windows.Int32Rect]::new(($col * $cellW), ($row * $cellH), $cellW, $cellH)
            $crop = [System.Windows.Media.Imaging.CroppedBitmap]::new($sheetEntry.bitmap, $rect)
            $crop.Freeze()
            $sheetPetEl.Source = $crop
        }

        # 保持素材原始像素尺寸：大小统一由 userScale 缩放层处理，
        # 否则会与缩放层叠加造成双重缩放
        if ([double]$sheetPetEl.Width -ne [double]$cellW) { $sheetPetEl.Width = $cellW }
        if ([double]$sheetPetEl.Height -ne [double]$cellH) { $sheetPetEl.Height = $cellH }
        # 容器尺寸 = 一格素材的尺寸：让布局把整张贴图算进窗口大小。
        # 容器固定 140x140 时贴图（192x208）会溢出布局盒，窗口按布局算尺寸，
        # 于是气泡一窄、窗口一窄，小宠左右就被裁掉一截（气泡宽窄一变就是一次闪）。
        if ([double]$petShellEl.Width -ne [double]$cellW -or [double]$petShellEl.Height -ne [double]$cellH) {
            $petShellEl.Width = [double]$cellW
            $petShellEl.Height = [double]$cellH
        }

        if ($vectorPet.Visibility -ne 'Collapsed') { $vectorPet.Visibility = 'Collapsed' }
        if ($sheetPetEl.Visibility -ne 'Visible') { $sheetPetEl.Visibility = 'Visible' }
    } catch {
        Note-TickError 'sheet-frame' $_
    }
}

function Render-PausedFrame {
    # 暂停时动画不再推进，但仍要把「当前状态」渲染一次：
    # 否则启动时就是暂停的话，气泡会停在初始的 "..."、底部提示为空。
    try {
        $action = [string]$state.action
        if ($ModeToActionMap.ContainsKey([string]$state.mode)) { $action = [string]$ModeToActionMap[[string]$state.mode] }
        if ($state.petMode -eq 'sprite') { Show-PetFrame $action } else { Update-VectorLook $action }
        $bubbleValue = '怎么还不来找我~有事找我'
        if ($BubbleMap.ContainsKey($action)) { $bubbleValue = $BubbleMap[$action] }
        if ($action -eq 'idle' -and $state.mode -eq 'disconnected') { $bubbleValue = $BubbleMap['disconnected'] }
        if ($bubbleTextEl.Text -ne $bubbleValue) { $bubbleTextEl.Text = $bubbleValue }
        $sourceLabel = switch ($state.lastSource) {
            'harness'  { 'Harness 实时' }
            'dsh'      { 'DSH 插件接口' }
            'dsh-file' { 'DSH 插件快照文件' }
            'sessions' { '会话活跃度(兜底)' }
            default    { '未连接' }
        }
        $hintValue = '{0} · 已暂停' -f $sourceLabel
        if ($hintTextEl.Text -ne $hintValue) { $hintTextEl.Text = $hintValue }
    } catch {
        Note-TickError 'paused-render' $_
    }
}

# ---------------- 矢量形象：按状态改写外观 + 视线方向 ----------------
# 画刷/几何体启动时一次性构建，避免每帧 CreateInstance（原实现每帧重建导致 CPU 空转）
$script:brushNormal = [System.Windows.Media.Brush][System.Windows.Media.BrushConverter]::new().ConvertFromString('#3A8FD4')
$script:brushNormalDark = [System.Windows.Media.Brush][System.Windows.Media.BrushConverter]::new().ConvertFromString('#2F7FC4')
$script:brushFailed = [System.Windows.Media.Brush][System.Windows.Media.BrushConverter]::new().ConvertFromString('#D97B7B')
$script:brushFailedDark = [System.Windows.Media.Brush][System.Windows.Media.BrushConverter]::new().ConvertFromString('#C96A6A')
$script:geometryMouthNormal = [System.Windows.Media.Geometry]::Parse('M56,86 q8,8 16,0')
$script:geometryMouthFailed = [System.Windows.Media.Geometry]::Parse('M56,92 q8,-8 16,0')
$script:vectorState = @{ failed = $null; happy = $null; eyeHeight = $null; badge = $null }

# 气泡原色（等待提示结束后要还原）+ 等待提示配色
$script:brushBubble = $bubbleEl.Background
$script:brushBubbleBorder = $bubbleEl.BorderBrush
$script:brushWaitQuestion = [System.Windows.Media.Brush][System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFF4DC')
$script:brushWaitQuestionBorder = [System.Windows.Media.Brush][System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFE0A64B')
$script:brushWaitApproval = [System.Windows.Media.Brush][System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFE8F6EA')
$script:brushWaitApprovalBorder = [System.Windows.Media.Brush][System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF4CAF50')
$script:bubbleTint = ''

function Update-VectorLook([string]$action) {
    try {
        $failed = ($action -eq 'failed')
        $happy = ($action -eq 'jumping' -or $action -eq 'waving')

        if ($script:vectorState.failed -ne $failed) {
            $script:vectorState.failed = $failed
            if ($failed) {
                $bodyEllipse.Fill = $script:brushFailed
                $finPathEl.Fill = $script:brushFailedDark
                $tailPathEl.Fill = $script:brushFailedDark
                $mouthPathEl.Data = $script:geometryMouthFailed
            } else {
                $bodyEllipse.Fill = $script:brushNormal
                $finPathEl.Fill = $script:brushNormalDark
                $tailPathEl.Fill = $script:brushNormalDark
                $mouthPathEl.Data = $script:geometryMouthNormal
            }
        }

        if ($script:vectorState.happy -ne $happy) {
            $script:vectorState.happy = $happy
            $eyeVisibility = if ($happy) { 'Collapsed' } else { 'Visible' }
            $eyeLeftEl.Visibility = $eyeVisibility
            $eyeRightEl.Visibility = $eyeVisibility
            $glintLeftEl.Visibility = $eyeVisibility
            $glintRightEl.Visibility = $eyeVisibility
        }

        if (-not $happy) {
            $eyeHeight = if ($action -eq 'review') { 5.0 } else { 13.0 }
            if ($script:vectorState.eyeHeight -ne $eyeHeight) {
                $script:vectorState.eyeHeight = $eyeHeight
                $eyeLeftEl.Height = $eyeHeight
                $eyeRightEl.Height = $eyeHeight
            }
        }

        # 16 向视线：从正上开始顺时针
        $dirIdx = [int]($state.lookIndex % 16)
        $angle = ($dirIdx * 22.5 - 90.0) * [math]::PI / 180.0
        $dx = [math]::Cos($angle) * 2.6
        $dy = [math]::Sin($angle) * 2.2
        [System.Windows.Controls.Canvas]::SetLeft($eyeLeftEl, 45 + $dx)
        [System.Windows.Controls.Canvas]::SetTop($eyeLeftEl, 56 + $dy)
        [System.Windows.Controls.Canvas]::SetLeft($eyeRightEl, 71 + $dx)
        [System.Windows.Controls.Canvas]::SetTop($eyeRightEl, 56 + $dy)
        [System.Windows.Controls.Canvas]::SetLeft($glintLeftEl, 48 + $dx)
        [System.Windows.Controls.Canvas]::SetTop($glintLeftEl, 58 + $dy)
        [System.Windows.Controls.Canvas]::SetLeft($glintRightEl, 74 + $dx)
        [System.Windows.Controls.Canvas]::SetTop($glintRightEl, 58 + $dy)

        $badgeValue = ''
        if ($BadgeMap.ContainsKey($action)) { $badgeValue = $BadgeMap[$action] }
        if ($script:vectorState.badge -ne $badgeValue) {
            $script:vectorState.badge = $badgeValue
            $badgeTextEl.Text = $badgeValue
        }
    } catch {
        Note-TickError 'vector-look' $_
    }
}

# ---------------- 状态来源 ----------------
# 首选：直接读 DSH 的会话投影缓存（明文 JSON，始终可用、无需插件、无需端口）
#       路径 ~/.dsh/storages/session_projcache/sessions/<id>.json
# 次选：插件 HTTP 端点（若已加载，可额外提供“正在执行哪个工具”）
# 兜底：会话目录活跃度
$script:endpointUrl = $Config.StateUrl
$script:endpointCheckedAt = [datetime]::MinValue

function Resolve-EndpointUrl {
    if (((Get-Date) - $script:endpointCheckedAt).TotalSeconds -lt 30) { return $script:endpointUrl }
    $script:endpointCheckedAt = Get-Date
    try {
        $endpointFile = Join-Path $env:USERPROFILE '.dsh\kun-pet-endpoint.json'
        if (Test-Path $endpointFile) {
            $meta = Get-Content -Raw -Path $endpointFile -Encoding UTF8 | ConvertFrom-Json
            if ($meta -and $meta.url) {
                if ($script:endpointUrl -ne [string]$meta.url) { Write-Log ("endpoint discovered: {0}" -f $meta.url) }
                $script:endpointUrl = [string]$meta.url
            }
        }
    } catch { }
    return $script:endpointUrl
}

# PowerShell 5.1 跑在 .NET Framework 上，[datetime]::UnixEpoch 是 .NET 6+ 才有的 API。
# 用固定的纪元参考时间做减法来获取毫秒级时间戳，兼容所有 .NET Framework 版本。
$script:epochRef = [System.DateTime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)

function Get-EpochMs {
    return [int64]((Get-Date).ToUniversalTime() - $script:epochRef).TotalMilliseconds
}

function Get-SessionRowValue($rows, [string]$name) {
    try {
        $row = $rows.$name
        if ($null -eq $row) { return $null }
        return $row.val
    } catch { return $null }
}

function Test-IsSubagentSession($doc) {
    # 子代理会话在 subagent.val.identity 里有 mode（continuable / one-shot）与 label；
    # 主会话的 subagent 行是“子代理清单”（含 childCreatedAt），没有 identity.mode。
    # 必须排除子代理，否则它们干活更新更频繁，会把主任务进展顶掉。
    try {
        $row = $doc.record.rows.subagent
        if ($null -eq $row -or $null -eq $row.val) { return $false }
        $val = $row.val
        if ($null -eq $val.identity) { return $false }
        if ($val.identity.mode) { return $true }
        return $false
    } catch { return $false }
}

# ---- 多会话聚合基础设施 ----
# 桌面桌宠是“全局”的：可能同时有多个任务会话在跑。旧实现只取“最近写入的一个
# 会话文件”，别的会话就算还在进展也会被忽略，表现为“任务在跑却没有气泡提示”。
# 这里改为：扫描全部活跃主会话、逐会话跟踪开关状态、聚合出全局模式与逐任务进展。
$script:docCache = @{}          # 文件路径 -> @{ stamp; doc }，文件没写入就不重复 JSON 解析
$script:docCacheMark = @{}      # 本轮扫描见过的文件（用于裁剪缓存）
$script:sessionOpenPrev = @{}   # 会话 id -> 上一帧是否在跑（逐会话下降沿检测）
$script:sessionWaitSince = @{}  # 会话 id -> 开始等待用户回答的时刻（ms）
$script:completions = @()       # 最近完成事件：@{ at; summary; text }

function Get-SessionDoc($file) {
    $key = [string]$file.FullName
    $stamp = '{0}:{1}' -f $file.LastWriteTimeUtc.Ticks, $file.Length
    $hit = $script:docCache[$key]
    if ($null -ne $hit -and [string]$hit.stamp -eq $stamp) {
        $script:docCacheMark[$key] = $true
        return $hit.doc
    }
    $doc = $null
    try {
        $doc = Get-Content -Raw -Path $file.FullName -Encoding UTF8 | ConvertFrom-Json
    } catch { $doc = $null }
    $script:docCache[$key] = @{ stamp = $stamp; doc = $doc }
    $script:docCacheMark[$key] = $true
    return $doc
}

function Clear-DocCache {
    # 只保留本轮见过的文件，防止长期运行后缓存无限增长
    if ($script:docCache.Count -gt 64) {
        foreach ($key in @($script:docCache.Keys)) {
            if (-not $script:docCacheMark.ContainsKey($key)) { [void]$script:docCache.Remove($key) }
        }
    }
    $script:docCacheMark = @{}
}

function Add-CompletionEvent([double]$atMs, [string]$summary, [string]$text) {
    $script:completions += @{ at = $atMs; summary = $summary; text = $text }
    $kept = @()
    foreach ($c in $script:completions) {
        if (($atMs - [double]$c.at) -le 60000) { $kept += $c }
    }
    $script:completions = $kept
}

function Limit-Text([string]$text, [int]$max) {
    if (-not $text) { return '' }
    $t = $text -replace '\s+', ' '
    $t = $t.Trim()
    if ($t.Length -le $max) { return $t }
    return $t.Substring(0, $max) + '…'
}

Function Get-StateFromHarness {
    try {
        $files = $null
        try {
            $files = Get-ChildItem -Path $Config.ProjCacheDir -Filter *.json -File -ErrorAction Stop
        } catch { return $null }
        if ($null -eq $files) { return $null }
        $arr = @($files | Sort-Object LastWriteTime -Descending)
        if ($arr.Count -eq 0) { return $null }
        $now = Get-Date
        $nowMs = Get-EpochMs

        # 关注范围：最近 15 分钟写过的会话 + 之前跟踪中的会话（保证收尾边沿能观测到）
        $candidates = @()
        foreach ($f in $arr) {
            $fAgeSec = ($now - $f.LastWriteTime).TotalSeconds
            $tracked = $script:sessionOpenPrev.ContainsKey([string]$f.BaseName)
            if ($fAgeSec -le 900 -or $tracked) { $candidates += $f }
            if ($candidates.Count -ge 24) { break }
        }
        if ($candidates.Count -eq 0) { return $null }
        $script:docCacheMark = @{}

        $workingSessions = @()
        $waitingSessions = @()
        $seenIds = @{}
        $anyFresh = $false
        $totalTurns = 0
        $totalSteps = 0

        # ---- 逐会话提取（多会话聚合）----
        foreach ($file in $candidates) {
            $id = [string]$file.BaseName
            $seenIds[$id] = $true
            $doc = Get-SessionDoc $file
            if ($null -eq $doc -or $null -eq $doc.record) { continue }
            if (Test-IsSubagentSession $doc) { continue }
            $rows = $doc.record.rows
            if ($null -eq $rows) { continue }
            $ageSec = ($now - $file.LastWriteTime).TotalSeconds
            if ($ageSec -lt 20) { $anyFresh = $true }

            $turnBoundary = Get-SessionRowValue $rows 'turnBoundary'
            $sessionStats = Get-SessionRowValue $rows 'sessionStats'
            $userQuestions = Get-SessionRowValue $rows 'userQuestions'
            $turnOutline = Get-SessionRowValue $rows 'turnOutline'

            # 是否正在跑（有未结束的轮次 / 未结束的步骤 / 未落地的工具调用）
            $openTurn = $null
            if ($turnBoundary) { $openTurn = $turnBoundary.openTurnStartSeq }
            $openStep = $null
            $pendingCount = 0
            $turns = 0; $steps = 0; $llmMs = 0; $toolMs = 0
            if ($sessionStats) {
                $openStep = $sessionStats.openStep
                # 注意：pendingCalls 常为空对象 {}。PS 5.1 下 @($obj.PSObject.Properties).Count
                # 对空对象会算出 1，必须按“属性名数量”显式统计，否则会误判为仍在运行
                if ($sessionStats.pendingCalls) {
                    $names = @()
                    foreach ($prop in $sessionStats.pendingCalls.PSObject.Properties) {
                        if ($prop.Name -and $prop.Name -notmatch '^PS') { $names += $prop.Name }
                    }
                    $pendingCount = $names.Count
                }
                if ($sessionStats.turns) { $turns = [int]$sessionStats.turns }
                if ($sessionStats.steps) { $steps = [int]$sessionStats.steps }
                if ($sessionStats.llmMs) { $llmMs = [int]$sessionStats.llmMs }
                if ($sessionStats.toolMs) { $toolMs = [int]$sessionStats.toolMs }
            }
            $isRawOpen = (($null -ne $openTurn) -or ($null -ne $openStep) -or ($pendingCount -gt 0))
            # 关键：会话缓存只在有活动时被写入，最后一次快照里的 openStep/openTurn 会
            # 一直保留。因此必须结合“文件新鲜度”判断是否真的在跑，否则任务结束后
            # 桌宠会永久卡在“进行中”。
            # 阈值取 180 秒：既容忍长时间思考/生成长文本时缓存不更新的情况，
            # 又能在 DSH 异常退出后把陈旧的“进行中”收回来。
            $isFresh = ($ageSec -lt 180)
            $isOpen = ($isRawOpen -and $isFresh)

            # 正在等待用户回答的问题（= 需要你介入）。
            # DSH 会话投影里的真实结构（app.asar 中的 userQuestions schema）：
            #   active: [ { callId, state: 'open'|'continued',
            #               questions: [ { id, question, detail?, header?,
            #                              options?: [{label, description?}],
            #                              multiSelect?,
            #                              intent?: {kind:'plan-review', approve} } ] } ]
            # 两个坑：① 问题字段嵌在 questions[] 里（不是直接挂在条目上）；
            # ② state='continued' 表示已经答过、Agent 正在继续，不能再当成等待。
            # 以前这两点都没处理，所以气泡永远只说“Agent 正在等待你的回答”。
            $activeQuestions = @()
            if ($userQuestions -and $userQuestions.questions -and $userQuestions.questions.active) {
                foreach ($entry in @($userQuestions.questions.active)) {
                    if ($null -eq $entry) { continue }
                    $entryState = ''
                    try { if ($entry.state) { $entryState = [string]$entry.state } } catch { }
                    if ($entryState -eq 'continued') { continue }
                    $nested = @()
                    try { $nested = @($entry.questions) } catch { $nested = @() }
                    if ($nested.Count -eq 0) { $nested = @($entry) }   # 兼容扁平结构
                    foreach ($q in $nested) { if ($null -ne $q) { $activeQuestions += $q } }
                }
            }
            $questionText = ''
            $questionHeader = ''
            $questionDetail = ''
            $questionOptions = @()
            $questionMulti = $false
            $questionKind = ''
            $questionApprove = ''
            if ($activeQuestions.Count -gt 0) {
                $q = $activeQuestions[0]
                foreach ($field in @('question', 'text', 'prompt', 'title', 'message')) {
                    try {
                        if ($q.$field) { $questionText = [string]$q.$field; break }
                    } catch { }
                }
                if (-not $questionText) { $questionText = 'Agent 正在等待你的回答' }
                try { if ($q.header) { $questionHeader = [string]$q.header } } catch { }
                try { if ($q.detail) { $questionDetail = [string]$q.detail } } catch { }
                try { if ($q.multiSelect) { $questionMulti = [bool]$q.multiSelect } } catch { }
                # intent.kind='plan-review' = Agent 提交了方案等你批准（“选方案”那一类）
                try {
                    if ($q.intent -and $q.intent.kind) {
                        $questionKind = [string]$q.intent.kind
                        if ($q.intent.approve) { $questionApprove = [string]$q.intent.approve }
                    }
                } catch { }
                # 选项：DSH 的 ask_user_question 用 label / description，这里对常见字段名都兼容。
                # 桌面气泡要把「要选什么」列出来，用户不用切回 Harness 才知道。
                foreach ($opt in @($q.options)) {
                    if ($null -eq $opt) { continue }
                    $label = ''
                    foreach ($f in @('label', 'text', 'title', 'value', 'name')) {
                        try { if ($opt.$f) { $label = [string]$opt.$f; break } } catch { }
                    }
                    if (-not $label) { $label = [string]$opt }
                    if (-not $label) { continue }
                    $desc = ''
                    foreach ($f in @('description', 'desc', 'detail')) {
                        try { if ($opt.$f) { $desc = [string]$opt.$f; break } } catch { }
                    }
                    if ($desc) { $questionOptions += ('{0}（{1}）' -f $label, (Limit-Text $desc 22)) }
                    else { $questionOptions += $label }
                }
            }

            # 当前任务（取最近一轮的用户输入）
            $lastPrompt = ''
            if ($turnOutline -and $turnOutline.turns) {
                $allTurns = @($turnOutline.turns)
                if ($allTurns.Count -gt 0) {
                    $lastTurn = $allTurns[$allTurns.Count - 1]
                    if ($lastTurn.prompt) { $lastPrompt = [string]$lastTurn.prompt }
                }
            }

            $totalTurns += $turns
            $totalSteps += $steps

            # ---- 逐会话下降沿：任务结束 ----
            # 必须逐会话记录“上一帧是否在跑”：多会话时若共用一个全局标记，
            # 会把 B 会话的静止误当成 A 会话收尾（误报完成 / 漏报完成都会发生）。
            $prevOpen = $false
            if ($script:sessionOpenPrev.ContainsKey($id)) { $prevOpen = [bool]$script:sessionOpenPrev[$id] }
            $script:sessionOpenPrev[$id] = $isOpen
            if ($prevOpen -and -not $isOpen) {
                $summary = '· {0} 轮 / {1} 步 · 模型 {2}s · 工具 {3}s' -f $turns, $steps,
                    [math]::Round($llmMs / 1000.0, 1), [math]::Round($toolMs / 1000.0, 1)
                Add-CompletionEvent $nowMs $summary (Limit-Text $lastPrompt 40)
            }

            if ($activeQuestions.Count -gt 0) {
                if (-not $script:sessionWaitSince.ContainsKey($id) -or [double]$script:sessionWaitSince[$id] -le 0) {
                    $script:sessionWaitSince[$id] = [double]$nowMs
                }
                $waitingSessions += @{
                    id      = $id
                    text    = (Limit-Text $questionText 60)
                    header  = (Limit-Text $questionHeader 20)
                    detail  = (Limit-Text $questionDetail 40)
                    options = @($questionOptions | Select-Object -First 6)
                    multi   = [bool]$questionMulti
                    kind    = [string]$questionKind
                    approve = (Limit-Text $questionApprove 16)
                    since   = [double]$script:sessionWaitSince[$id]
                }
            } elseif ($script:sessionWaitSince.ContainsKey($id)) {
                $script:sessionWaitSince[$id] = 0
            }

            if ($isOpen) {
                $workingSessions += @{
                    id     = $id
                    prompt = (Limit-Text $lastPrompt 60)
                    turns  = $turns
                    steps  = $steps
                }
            }
        }

        # 从磁盘消失的会话不再跟踪（其收尾边沿早已在文件变旧阶段观测到）
        foreach ($k in @($script:sessionOpenPrev.Keys)) {
            if (-not $seenIds.ContainsKey($k)) {
                [void]$script:sessionOpenPrev.Remove($k)
                [void]$script:sessionWaitSince.Remove($k)
            }
        }
        Clear-DocCache

        # ---- 模式判定（多会话聚合）----
        # 优先级：等待回答 > 有任务在跑 > 刚完成 > 收尾 > 待机。
        # 关键：只要还有任何一个任务在跑，就必须显示“进行中”与逐任务进展，
        # 不允许被其他会话的完成/收尾顶掉。
        $mode = 'idle'
        $waitingKind = $null
        $waitingSeconds = 0
        $questionOut = ''
        $questionHeaderOut = ''
        $questionDetailOut = ''
        $questionOptionsOut = @()
        $questionMultiOut = $false
        $questionKindOut = ''
        $questionApproveOut = ''
        $waitingCount = 0

        if ($waitingSessions.Count -gt 0) {
            $mode = 'waiting'
            $waitingKind = 'question'
            $primaryWait = $waitingSessions[0]
            foreach ($w in $waitingSessions) {
                if ([double]$w.since -lt [double]$primaryWait.since) { $primaryWait = $w }
            }
            $questionOut = [string]$primaryWait.text
            if ($primaryWait.ContainsKey('header')) { $questionHeaderOut = [string]$primaryWait.header }
            if ($primaryWait.ContainsKey('detail')) { $questionDetailOut = [string]$primaryWait.detail }
            if ($primaryWait.ContainsKey('options')) { $questionOptionsOut = @($primaryWait.options) }
            if ($primaryWait.ContainsKey('multi')) { $questionMultiOut = [bool]$primaryWait.multi }
            if ($primaryWait.ContainsKey('kind')) { $questionKindOut = [string]$primaryWait.kind }
            if ($primaryWait.ContainsKey('approve')) { $questionApproveOut = [string]$primaryWait.approve }
            $waitingCount = $waitingSessions.Count
            $waitingSeconds = [int](($nowMs - [double]$primaryWait.since) / 1000)
        } elseif ($workingSessions.Count -gt 0) {
            $mode = 'working'
        } else {
            $lastDone = $null
            foreach ($c in $script:completions) {
                if ($null -eq $lastDone -or [double]$c.at -gt [double]$lastDone.at) { $lastDone = $c }
            }
            $sinceCompleted = -1
            if ($null -ne $lastDone) { $sinceCompleted = $nowMs - [double]$lastDone.at }
            if ($null -ne $lastDone -and $sinceCompleted -ge 0 -and $sinceCompleted -lt 5000) {
                $mode = 'celebrating'
            } elseif ($anyFresh) {
                $mode = 'review'
            } else {
                $mode = 'idle'
            }
        }

        # 最近一次完成（供提醒与摘要使用）
        $completedAt = 0
        $lastSummary = $null
        $lastDoneText = ''
        foreach ($c in $script:completions) {
            if ([double]$c.at -gt $completedAt) {
                $completedAt = [double]$c.at
                $lastSummary = [string]$c.summary
                $lastDoneText = [string]$c.text
            }
        }

        # ---- 文案与进展行（气泡内容）----
        $message = '待机中'
        $detail = ''
        $taskText = ''
        $progressLines = @()
        if ($mode -eq 'waiting') {
            if ($waitingCount -gt 1) {
                $message = '需要你回答：{0} 个任务在等你' -f $waitingCount
            } else {
                $message = '需要你回答：' + (Limit-Text $questionOut 60)
            }
            foreach ($w in $waitingSessions) {
                $progressLines += ('· ' + (Limit-Text ([string]$w.text) 40))
            }
            if ($progressLines.Count -gt 3) {
                $progressLines = @($progressLines[0..2])
                $progressLines += ('… 共 {0} 个任务等待回答' -f $waitingCount)
            }
        } elseif ($mode -eq 'working') {
            if ($workingSessions.Count -eq 1) {
                $w = $workingSessions[0]
                $taskText = [string]$w.prompt
                $message = '进行中：' + (Limit-Text $taskText 46)
                $detail = '{0} 轮 / {1} 步' -f [int]$w.turns, [int]$w.steps
                $progressLines += ('正在处理：' + (Limit-Text $taskText 40) + ' · ' + $detail)
            } else {
                $message = '{0} 个任务进行中' -f $workingSessions.Count
                $detail = '共 {0} 轮 / {1} 步' -f $totalTurns, $totalSteps
                foreach ($w in $workingSessions) {
                    $line = '· ' + (Limit-Text ([string]$w.prompt) 36)
                    $line += ('（{0} 轮 / {1} 步）' -f [int]$w.turns, [int]$w.steps)
                    $progressLines += $line
                }
                if ($progressLines.Count -gt 3) {
                    $progressLines = @($progressLines[0..2])
                    $progressLines += ('… 共 {0} 个任务进行中' -f $workingSessions.Count)
                }
            }
        } elseif ($mode -eq 'review') {
            $message = '收尾中…'
            $progressLines = @('收尾中…')
        } elseif ($mode -eq 'celebrating') {
            $message = '任务结束 ✓'
            if ($lastSummary) { $message = $message + ' ' + [string]$lastSummary }
            if ($lastDoneText) {
                $progressLines += ('完成：' + $lastDoneText)
                if ($lastSummary) { $progressLines += ([string]$lastSummary) }
            } elseif ($lastSummary) {
                $progressLines += ([string]$lastSummary)
            }
        }

        # seq 用“轮次+步骤+任务数+模式”做指纹：
        # 不能用 ageSec（每帧都在变），否则 Set-Mode 每帧都被调用、modeStart 被反复重置，
        # 底部“已 Ns”永远显示 0，状态也就无法稳定停留。
        $modeWeight = 5
        if ($mode -eq 'waiting') { $modeWeight = 1 }
        elseif ($mode -eq 'working') { $modeWeight = 2 }
        elseif ($mode -eq 'celebrating') { $modeWeight = 3 }
        elseif ($mode -eq 'review') { $modeWeight = 4 }
        $seqFingerprint = [int](($totalTurns * 100000) + ($totalSteps * 10) + ($workingSessions.Count * 6) + ($waitingSessions.Count * 3) + $modeWeight)

        return @{
            mode           = $mode
            seq            = $seqFingerprint
            source         = 'harness'
            message        = $message
            waiting        = ($waitingSessions.Count -gt 0)
            waitingKind    = $waitingKind
            waitingCount   = $waitingCount
            waitingSeconds = $waitingSeconds
            runningAgents  = $workingSessions.Count
            toolCount      = $totalSteps
            lastTool       = $null
            lastSummary    = $lastSummary
            completedAt    = $completedAt
            failureCount   = 0
            taskText       = (Limit-Text $taskText 60)
            questionText   = (Limit-Text $questionOut 60)
            questionHeader = $questionHeaderOut
            questionDetail = $questionDetailOut
            questionOptions = @($questionOptionsOut)
            questionMulti  = [bool]$questionMultiOut
            questionKind   = $questionKindOut
            questionApprove = $questionApproveOut
            detail         = $detail
            progressLines  = $progressLines
        }
    } catch {
        Note-TickError 'harness-state' $_
        return $null
    }
}

$script:dshBackoffUntil = [datetime]::MinValue

# 插件状态快照文件（host 半区的第二通道）：HTTP 路由注册不上/端口不通时，
# 桌宠仍然能从这份 JSON 里读到 waiting / pendingApprovals，气泡照常提示。
$script:stateFilePath = Join-Path $env:USERPROFILE '.dsh\kun-pet-state.json'
$script:stateFileFreshSec = 30

# 把插件快照（HTTP 响应体或状态文件内容）映射成桌宠内部快照，两个通道共用
function Convert-DshSnapshot($resp, [string]$source) {
    if ($null -eq $resp) { return $null }
    if (-not $resp.mode) { return $null }
    $lastToolValue = $null
    if ($resp.lastTool) { $lastToolValue = [string]$resp.lastTool }
    $waitingKindValue = $null
    if ($resp.waitingKind) { $waitingKindValue = [string]$resp.waitingKind }
    $msgText = [string]$resp.message
    $approvals = @()
    if ($resp.pendingApprovals) { $approvals = @($resp.pendingApprovals) }
    return @{
        mode           = [string]$resp.mode
        seq            = [int]$resp.seq
        source         = $source
        message        = $msgText
        progressLines  = @($msgText)
        waiting        = [bool]$resp.waiting
        waitingKind    = $waitingKindValue
        waitingCount   = [int]$resp.waitingCount
        waitingSeconds = [int]$resp.waitingSeconds
        runningAgents  = [int]$resp.runningAgents
        toolCount      = [int]$resp.toolCount
        lastTool       = $lastToolValue
        lastSummary    = [string]$resp.lastSummary
        completedAt    = [double]$resp.completedAt
        failureCount   = [int]$resp.failureCount
        taskText       = ''
        questionText   = ''
        pendingApprovals = $approvals
        approvalChannel = 'http'
    }
}

function Get-StateFromDshHttp {
    try {
        # 插件端点不可用时退避几秒，避免每个轮询都白等超时
        if ((Get-Date) -lt $script:dshBackoffUntil) { return $null }
        $url = Resolve-EndpointUrl
        $resp = Invoke-RestMethod -Uri $url -TimeoutSec 2 -ErrorAction Stop
        $script:dshBackoffUntil = [datetime]::MinValue
        return (Convert-DshSnapshot $resp 'dsh')
    } catch {
        $script:dshBackoffUntil = (Get-Date).AddSeconds(3)
    }
    return $null
}

# 文件通道：只在快照还新鲜时采信（插件每次状态变化都会重写它；
# 等审批时秒数每秒在变，所以等待期间一定是新鲜的；DSH 崩了留下的陈旧文件会被忽略）
function Get-StateFromDshFile {
    try {
        if (-not (Test-Path -LiteralPath $script:stateFilePath)) { return $null }
        $resp = Get-Content -LiteralPath $script:stateFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $resp) { return $null }
        $updatedAt = 0
        try { if ($resp.updatedAt) { $updatedAt = [int64]$resp.updatedAt } } catch { $updatedAt = 0 }
        $fresh = $false
        if ($updatedAt -gt 0) {
            $ageSec = ((Get-Date).ToUniversalTime() - $script:epochRef).TotalMilliseconds - $updatedAt
            $fresh = ($ageSec -ge -5000 -and $ageSec -lt ($script:stateFileFreshSec * 1000))
        } else {
            $ageSec = ((Get-Date) - (Get-Item -LiteralPath $script:stateFilePath).LastWriteTime).TotalSeconds
            $fresh = ($ageSec -lt $script:stateFileFreshSec)
        }
        if (-not $fresh) { return $null }
        $snap = Convert-DshSnapshot $resp 'dsh-file'
        if ($null -ne $snap) { $snap.approvalChannel = 'file' }
        return $snap
    } catch { return $null }
}

function Get-StateFromDsh {
    $snap = Get-StateFromDshHttp
    if ($null -ne $snap) { return $snap }
    return (Get-StateFromDshFile)
}

function Get-StateFromSessions {
    try {
        $newest = Get-ChildItem -Path $Config.SessionsDir -Recurse -File -ErrorAction Stop |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -eq $newest) { return $null }
        $ageSec = ((Get-Date) - $newest.LastWriteTime).TotalSeconds
        if ($ageSec -lt 30)  { return @{ mode = 'working'; source = 'sessions' } }
        if ($ageSec -lt 120) { return @{ mode = 'review';  source = 'sessions' } }
        return @{ mode = 'idle'; source = 'sessions' }
    } catch { return $null }
}

# ---------------- 待审批操作：桌宠上直接放行 / 拒绝 ----------------
# 插件端点 /kun-pet/state 的 pendingApprovals 列出等待确认的权限请求；
# 点按钮把决策 POST 到 /kun-pet/approval（与 GUI 弹窗竞速，谁先操作听谁的）。
# 两种情况只提示、不显示按钮（点了也送不出去，显示按钮只会误导）：
#   1) 只有文件通道（插件状态快照 /kun-pet-state.json）可用；
#   2) 插件已经把这次请求交给了 Harness（answerable=false），由网页端那只确认框负责。
function Update-ApprovalPanel($dshSnap) {
    try {
        $items = @()
        $channel = $null
        if ($null -ne $dshSnap -and $dshSnap.ContainsKey('pendingApprovals')) {
            $items = @($dshSnap.pendingApprovals)
            if ($dshSnap.ContainsKey('approvalChannel') -and $dshSnap.approvalChannel) {
                $channel = [string]$dshSnap.approvalChannel
            }
        }
        $state.approvalItems = $items
        $state.approvalChannel = $channel
        # answerable 缺省（老版本插件没有这个字段）＝ 还能在桌宠上答
        $canAnswer = $true
        if ($items.Count -gt 0) {
            try { if ($null -ne $items[0].answerable) { $canAnswer = [bool]$items[0].answerable } } catch { $canAnswer = $true }
        }
        $state.approvalAnswerable = $canAnswer
        $visible = ($items.Count -gt 0 -and $channel -eq 'http' -and $canAnswer)
        $targetVis = if ($visible) { 'Visible' } else { 'Collapsed' }
        if ([string]$approvalBorderEl.Visibility -ne $targetVis) { $approvalBorderEl.Visibility = $targetVis }
        if ($items.Count -eq 0) {
            $state.lastApprovalAlertId = $null
            return
        }
        $first = $items[0]
        $text = '需要你确认：{0}' -f [string]$first.toolName
        if ($items.Count -gt 1) { $text += ('（共 {0} 个待确认）' -f $items.Count) }
        $reason = ''
        try { if ($first.reason) { $reason = [string]$first.reason } } catch { }
        if ($reason) { $text += ("`n" + (Limit-Text $reason 40)) }
        if ($channel -ne 'http') { $text += "`n" + '切回 Harness 窗口点「同意 / 拒绝」' }
        elseif (-not $canAnswer) { $text += "`n" + 'Harness 已弹出确认框，去窗口里点' }
        if ($approvalTextEl.Text -ne $text) { $approvalTextEl.Text = $text }
        # 新的待确认请求：提示音 + 托盘通知 + 抢置顶（同一请求只喊一次）
        $firstId = [string]$first.id
        if ($state.lastApprovalAlertId -ne $firstId) {
            $state.lastApprovalAlertId = $firstId
            Play-Tones -freqs @(880, 1174.7, 880) -durMs 160 -gapMs 130
            try {
                $hint = if ($channel -eq 'http' -and $canAnswer) { '可在桌宠上直接放行 / 拒绝：' } else { '请切回 Harness 窗口确认：' }
                $notify.ShowBalloonTip(6000, '⚠ 需要你确认',
                    ($hint + [string]$first.toolName),
                    [System.Windows.Forms.ToolTipIcon]::Warning)
            } catch { }
            try { $window.Topmost = $false; $window.Topmost = $true } catch { }
            $state.alertFlashUntil = (Get-Date).AddSeconds(6)
            Write-Log ('approval pending: {0} via {1}' -f [string]$first.toolName, $(if ($channel) { $channel } else { '?' }))
        }
    } catch {
        Note-TickError 'approval-panel' $_
    }
}

function Send-ApprovalDecision([string]$decision) {
    try {
        $items = @($state.approvalItems)
        if ($items.Count -eq 0) { return }
        $first = $items[0]
        $id = [string]$first.id
        $base = (Resolve-EndpointUrl) -replace '/kun-pet/state$', ''
        $body = (@{ id = $id; decision = $decision } | ConvertTo-Json)
        $result = Invoke-RestMethod -Uri ($base + '/kun-pet/approval') -Method Post `
            -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 2
        # 乐观移除当前项，下一轮轮询与真源对齐
        $state.approvalItems = @($items | Select-Object -Skip 1)
        if (@($state.approvalItems).Count -eq 0) {
            $approvalBorderEl.Visibility = 'Collapsed'
            $state.lastApprovalAlertId = $null
        }
        if ($decision -eq 'allowed-once') { Set-Action 'jumping' 1200 } else { Set-Action 'waving' 1200 }
        Play-Tones -freqs @(660, 880) -durMs 90 -gapMs 90
        Write-Log ('approval {0}: {1} ({2})' -f $decision, [string]$first.toolName, $id)
        try { if ($result -and $result.ok -eq $false) { Write-Log ('approval already handled: ' + $id) } } catch { }
    } catch {
        Note-TickError 'approval-send' $_
        Write-Log ('approval send failed: ' + $_.Exception.Message)
    }
}

# ---------------- 大小 / 缩放（用户可自定义） ----------------
# 缩放作用在独立的 userScale 层，与动画脉冲（petScale）相乘叠加，
# 因此动画不会再覆盖用户设置的大小。
$script:scaleMin = 0.25
$script:scaleMax = 3.0
$script:settingsFile = Join-Path $script:logDir 'kun-pet-settings.json'
$script:sizeItems = @()

function Update-SizeMenuChecks {
    try {
        foreach ($item in $script:sizeItems) {
            $target = [double]$item.Tag
            $item.Checked = ([math]::Abs([double]$state.scale - $target) -lt 0.001)
        }
    } catch { }
}

function Save-Settings {
    try {
        $payload = @{
            scale   = [double]$state.scale
            # petId 是恢复上次形象的关键：'builtin'=内置形象，素材 id=已装素材，'none'=从未选择过
            petId   = [string]$state.petId
            petMode = [string]$state.petMode
            paused  = [bool]$state.paused
            gapPx   = [int]$state.gapPx
            floating = [bool]$state.floating
            multiMode = [string]$state.multiTaskMode
            rotateSec = [int]$state.rotateSec
            posLeft = [double]$window.Left
            posTop  = [double]$window.Top
            # 窗口是 SizeToContent：尺寸随气泡文字变，只存左上角的话，
            # 重启后气泡内容一不同，小宠的位置就跟上次差一截。
            # 连尺寸一起存，启动时按「底边 + 水平中心」还原。
            posW    = [double]$window.ActualWidth
            posH    = [double]$window.ActualHeight
        }
        $payload | ConvertTo-Json -Depth 3 | Set-Content -Path $script:settingsFile -Encoding UTF8
    } catch {
        Note-TickError 'save-settings' $_
    }
}

function Load-Settings {
    try {
        if (-not (Test-Path $script:settingsFile)) { return }
        $saved = Get-Content -Raw -Path $script:settingsFile -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $saved) { return }
        if ($saved.scale) {
            $v = [double]$saved.scale
            if ($v -ge $script:scaleMin -and $v -le $script:scaleMax) { $state.scale = $v }
        }
        # 注意：这里判断的是「字段存在」而不是「非空字符串」。
        # 旧版把内置形象存成空串，用 if ($saved.petId) 会把「用户选的就是内置形象」
        # 误判成「没保存过」，于是每次启动都回落默认形象。
        if ($null -ne $saved.petId) {
            $pid2 = [string]$saved.petId
            if ($pid2 -and $pid2 -ne 'none') { $state.petId = $pid2 }
        }
        if ($null -ne $saved.petMode) {
            $pm = [string]$saved.petMode
            if ($pm -eq 'sprite' -or $pm -eq 'vector') { $state.petMode = $pm }
        }
        if ($saved.paused) { $state.paused = [bool]$saved.paused }
        if ($null -ne $saved.floating) { $state.floating = [bool]$saved.floating }
        if ($null -ne $saved.gapPx) {
            $gp = [int]$saved.gapPx
            if ($gp -ge -32 -and $gp -le 0) { $state.gapPx = $gp }
        }
        if ($saved.multiMode) {
            $mm = [string]$saved.multiMode
            if ($mm -eq 'all' -or $mm -eq 'rotate' -or $mm -eq 'single') { $state.multiTaskMode = $mm }
        }
        if ($null -ne $saved.rotateSec) {
            $rs = 0
            if ([int]::TryParse([string]$saved.rotateSec, [ref]$rs)) {
                if ($rs -ge 1 -and $rs -le 60) { $state.rotateSec = $rs }
            }
        }
        if ($saved.posLeft -and $saved.posTop) {
            $screenW = [System.Windows.SystemParameters]::PrimaryScreenWidth
            $screenH = [System.Windows.SystemParameters]::PrimaryScreenHeight
            if ($saved.posLeft -gt -200 -and $saved.posLeft -lt $screenW -and
                $saved.posTop -gt -200 -and $saved.posTop -lt $screenH) {
                $window.Left = [double]$saved.posLeft
                $window.Top = [double]$saved.posTop
                # 记下保存时的窗口尺寸：首次布局后按底边/中心校正（见 SizeChanged）
                if ($null -ne $saved.posW) { $script:pendingPosW = [double]$saved.posW }
                if ($null -ne $saved.posH) { $script:pendingPosH = [double]$saved.posH }
            }
        }
        Write-Log ("settings loaded: scale={0} pet={1} mode={2} multi={3} rotate={4}s" -f $state.scale, $state.petId, $state.petMode, $state.multiTaskMode, $state.rotateSec)
    } catch {
        Write-Log ("settings load failed: " + $_.Exception.Message)
    }
}

function Apply-Scale {
    try {
        $v = [double]$state.scale
        if ($v -lt $script:scaleMin) { $v = $script:scaleMin }
        if ($v -gt $script:scaleMax) { $v = $script:scaleMax }
        $state.scale = $v
        # LayoutTransform 参与布局：整体等比缩放，容器尺寸自动跟随，不会裁剪内容
        $userScaleEl.ScaleX = $v
        $userScaleEl.ScaleY = $v
        # 文案跟着缩放，避免 300% 的小宠配 13px 文字显得失衡（下限保证可读性）
        $bubbleFont = [math]::Round(13 * [math]::Max(1.0, [math]::Min($v, 2.0)), 1)
        $hintFont = [math]::Round(10 * [math]::Max(1.0, [math]::Min($v, 2.0)), 1)
        $bubbleTextEl.FontSize = $bubbleFont
        $alertTextEl.FontSize = [math]::Round($bubbleFont * 0.92, 1)
        $hintTextEl.FontSize = $hintFont
        if ($state.petMode -eq 'sprite') { Show-PetFrame $state.action }
        Update-SizeMenuChecks
    } catch {
        Note-TickError 'apply-scale' $_
    }
}

function Set-Scale([double]$value, [bool]$persist) {
    $state.scale = $value
    Apply-Scale
    if ($persist) { Save-Settings }
}

function Apply-Gap {
    try {
        $gap = [int]$state.gapPx
        if ($gap -gt 0) { $gap = 0 }
        if ($gap -lt -32) { $gap = -32 }
        $state.gapPx = $gap
        $petShellEl.Margin = [System.Windows.Thickness]::new(0, $gap, 0, 0)
    } catch {
        Note-TickError 'apply-gap' $_
    }
}

function Set-Gap([int]$value, [bool]$persist) {
    $state.gapPx = $value
    Apply-Gap
    Update-GapMenuChecks
    if ($persist) { Save-Settings }
}

function Set-Action([string]$action, [int]$holdMs) {
    if (-not $ActionAnimMap.ContainsKey($action)) { $action = 'idle' }
    $state.action = $action
    if ($holdMs -gt 0) {
        $state.reaction = $action
        $state.reactionEnd = (Get-Date).AddMilliseconds($holdMs)
    } else {
        $state.reaction = $null
    }
    $state.frame = 0
    $state.frameAt = Get-Date
}

function Set-Mode([string]$mode) {
    if ($state.mode -eq $mode) { return }
    $prevMode = $state.mode
    $state.mode = $mode
    $state.modeStart = Get-Date
    $action = 'idle'
    if ($ModeToActionMap.ContainsKey($mode)) { $action = $ModeToActionMap[$mode] }
    Set-Action $action 0
    if ($mode -eq 'celebrating' -and $prevMode -ne 'celebrating') {
        Play-Tones -freqs @(523.25, 659.25, 783.99, 1046.5) -durMs 220 -gapMs 120
        # 不在这里弹托盘通知：Update-Alerts 会根据 completedAt 弹带摘要的通知，
        # 两处都弹会导致用户收到重复通知
    }
    if ($mode -eq 'failed' -and $prevMode -ne 'failed') {
        try { [System.Media.SystemSounds]::Hand.Play() } catch { }
    }
}

# ---------------- 多任务进展展示（全部 / 轮换 / 单条） ----------------
# 多会话并行时，气泡里的进展按「多任务展示」菜单的配置渲染：
#   all    —— 逐条全部列出（默认），一眼看到所有任务
#   rotate —— 每隔 N 秒轮换一条（带 i/N 序号），气泡保持小巧
#   single —— 只显示最活跃的一条（标注任务总数）
function Apply-ProgressDisplay {
    try {
        $lines = @($state.taskLines)
        $n = $lines.Count
        if ([int]$state.rotateLastCount -ne $n) {
            $state.rotateLastCount = $n
            $state.rotateIndex = 0
            $state.rotateAt = Get-Date
        }
        if ($n -le 0) {
            if ([string]$state.progressText -ne '') { $state.progressText = '' }
            return
        }
        if ($n -eq 1) {
            $only = [string]$lines[0]
            if ([string]$state.progressText -ne $only) { $state.progressText = $only }
            return
        }
        $displayMode = [string]$state.multiTaskMode
        if ($displayMode -eq 'rotate') {
            if ((Get-Date) -ge $state.rotateAt) {
                $state.rotateIndex = ([int]$state.rotateIndex + 1) % $n
                $state.rotateAt = (Get-Date).AddSeconds([double]$state.rotateSec)
            }
            $idx = [int]$state.rotateIndex
            if ($idx -ge $n -or $idx -lt 0) { $idx = 0; $state.rotateIndex = 0 }
            $line = ([string]$lines[$idx]) -replace '^·\s*', ''
            $text = '({0}/{1}) {2}' -f ($idx + 1), $n, $line
        } elseif ($displayMode -eq 'single') {
            $first = ([string]$lines[0]) -replace '^·\s*', ''
            $text = '{0}（共 {1} 个任务）' -f $first, $n
        } else {
            $text = ($lines -join "`n")
        }
        if ([string]$state.progressText -ne $text) { $state.progressText = $text }
    } catch {
        Note-TickError 'progress-display' $_
    }
}

# ---------------- 主动提醒：等待确认 / 任务结束 ----------------
# 关键点：同一件事只喊一次，避免每 500ms 轮询重复弹窗；用户确认后自动复位
function Update-Alerts($snap) {
    try {
        $alertText = ''
        $alertVisible = $false

        # 只有来自真实 Harness 状态源（会话缓存 / 插件接口）的快照才能触发提醒，
        # 活跃度兜底来源不参与，避免误报
        $isRealSource = ($null -ne $snap -and $snap.ContainsKey('source') -and
                         ($snap.source -eq 'harness' -or $snap.source -eq 'dsh'))
        if ($isRealSource) {
            # ---- 1) Harness 需要你确认 / 回答 ----
            if ($snap.waiting) {
                $isQuestion = ($snap.waitingKind -eq 'question')
                $headline = '需要你确认'
                $detail = 'Harness 等待审批'
                if ($isQuestion) {
                    $headline = '需要你回答'
                    $detail = 'Agent 正在向你提问'
                    # 提问：把问题本身写进横幅（plan-review 单独措辞）
                    try {
                        if ($snap.ContainsKey('questionKind') -and $snap.questionKind -eq 'plan-review') {
                            $headline = '需要你确认方案'
                            $detail = 'Agent 提交了方案待批准'
                        } elseif ($snap.ContainsKey('questionText') -and $snap.questionText) {
                            $detail = '问：' + (Limit-Text ([string]$snap.questionText) 30)
                        }
                    } catch { }
                }
                # 权限审批：把工具名一并写进横幅，桌面上不切窗口就知道要确认什么
                if (-not $isQuestion) {
                    $tipTool = ''
                    try {
                        if ($snap.ContainsKey('pendingApprovals')) {
                            $pa = @($snap.pendingApprovals)
                            if ($pa.Count -gt 0 -and $pa[0].toolName) { $tipTool = '：' + [string]$pa[0].toolName }
                        }
                    } catch { }
                    $detail = 'Harness 等待审批' + $tipTool
                }
                $waited = ''
                if ($snap.waitingSeconds -gt 0) { $waited = '（已等 {0} 秒）' -f $snap.waitingSeconds }
                $alertText = '{0}：{1}{2}' -f $headline, $detail, $waited
                $alertVisible = $true

                $key = 'waiting:' + [string]$snap.waitingKind
                if ($state.lastAlertKey -ne $key) {
                    $state.lastAlertKey = $key
                    # 主动喊人：提示音 + 托盘通知（比气泡更显眼）
                    Play-Tones -freqs @(880, 1174.7, 880) -durMs 160 -gapMs 130
                    $tip = 'Harness 正在等待你的确认/审批'
                    if ($isQuestion) { $tip = 'Agent 正在向你提问，请回到 Harness 回答' }
                    elseif ($tipTool) { $tip = '待确认工具' + $tipTool + '，可在桌宠上直接同意/拒绝' }
                    try { $notify.ShowBalloonTip(6000, '⚠ ' + $headline, $tip, [System.Windows.Forms.ToolTipIcon]::Warning) } catch { }
                    # 置顶抢一下存在感（不激活输入焦点，避免打断打字）
                    try { $window.Topmost = $false; $window.Topmost = $true } catch { }
                    $state.alertFlashUntil = (Get-Date).AddSeconds(6)
                    Write-Log ('alert: ' + $alertText)
                }
            } else {
                # ---- 2) 任务结束 ----
                # 完成事件只在“刚刚发生”的时间窗内提醒（默认 20 秒），避免重启桌宠后翻旧账
                $isRecent = ($snap.completedAt -gt 0 -and (Get-EpochMs - $snap.completedAt) -lt 20000)
                if ($isRecent) {
                    $summary = ''
                    if ($snap.lastSummary) { $summary = ' ' + [string]$snap.lastSummary }
                    $alertText = '任务结束 ✓' + $summary
                    $alertVisible = $true

                    $key = 'done:' + [string]([int64]$snap.completedAt)
                    if ($state.lastAlertKey -ne $key) {
                        $state.lastAlertKey = $key
                        $body = '任务已结束' + $summary
                        try { $notify.ShowBalloonTip(7000, '✓ Kun Like 桌宠', $body, [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
                        $state.alertFlashUntil = (Get-Date).AddSeconds(8)
                        Write-Log ('alert: ' + $alertText)
                    }
                } else {
                    # 回到常态：允许下一次提醒
                    if ($state.lastAlertKey -and $state.lastAlertKey.StartsWith('done:')) { $state.lastAlertKey = $null }
                    if ($state.lastAlertKey -and $state.lastAlertKey.StartsWith('waiting:')) { $state.lastAlertKey = $null }
                }
            }

            # 刷新进展摘要（显示在气泡内，紧贴形象）。
            # 多会话时 progressLines 为逐任务进展；具体展示方式（全部/轮换/单条）
            # 由「多任务展示」菜单配置，统一交给 Apply-ProgressDisplay 渲染。
            $lines = @()
            if ($snap.ContainsKey('progressLines')) { $lines = @($snap.progressLines) }
            if ($lines.Count -eq 0) {
                if ($snap.mode -eq 'working') {
                    $bit = ''
                    if ($snap.ContainsKey('detail') -and $snap.detail) { $bit = ' · ' + [string]$snap.detail }
                    if ($snap.taskText) { $lines = @(('正在处理：' + $snap.taskText + $bit)) }
                    elseif ($snap.lastTool) { $lines = @(('正在执行 {0}（第 {1} 次）' -f $snap.lastTool, $snap.toolCount)) }
                    else { $lines = @(('进行中…' + $bit)) }
                } elseif ($snap.mode -eq 'waiting') {
                    if ($snap.questionText) { $lines = @([string]$snap.questionText) }
                    else { $lines = @('等待你的回答') }
                } elseif ($snap.mode -eq 'review') {
                    $lines = @('收尾中…')
                }
            }
            $state.taskLines = $lines
            Apply-ProgressDisplay
        } else {
            $state.taskLines = @()
            $state.progressText = ''
            if ($state.lastAlertKey -and $state.lastAlertKey.StartsWith('waiting:')) { $state.lastAlertKey = $null }
        }

        # 应用到 UI（仅在变化时写属性，避免无谓重绘）
        $targetVisibility = if ($alertVisible) { 'Visible' } else { 'Collapsed' }
        if ([string]$alertBorderEl.Visibility -ne $targetVisibility) { $alertBorderEl.Visibility = $targetVisibility }
        if ($alertVisible -and $alertTextEl.Text -ne $alertText) { $alertTextEl.Text = $alertText }
    } catch {
        Note-TickError 'alerts' $_
    }
}

# ---------------- 菜单 ----------------
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$petMenu = [System.Windows.Forms.ToolStripMenuItem]::new('宠物')
$menu.Items.Add($petMenu) | Out-Null

$actionMenu = [System.Windows.Forms.ToolStripMenuItem]::new('动作')
foreach ($act in $StateKeys) {
    $item = [System.Windows.Forms.ToolStripMenuItem]::new($act)
    $item.Tag = $act
    $item.add_Click({ param($sender, $eventArgs) Set-Action ([string]$sender.Tag) 2600 })
    $actionMenu.DropDownItems.Add($item) | Out-Null
}
$menu.Items.Add($actionMenu) | Out-Null

$sizeMenu = [System.Windows.Forms.ToolStripMenuItem]::new('大小')
$script:sizePresets = @(
    @{ label = '25%';  value = 0.25 },
    @{ label = '50%';  value = 0.5 },
    @{ label = '75%';  value = 0.75 },
    @{ label = '100%'; value = 1.0 },
    @{ label = '125%'; value = 1.25 },
    @{ label = '150%'; value = 1.5 },
    @{ label = '200%'; value = 2.0 },
    @{ label = '300%'; value = 3.0 }
)
foreach ($preset in $script:sizePresets) {
    $item = [System.Windows.Forms.ToolStripMenuItem]::new([string]$preset.label)
    $item.Tag = [double]$preset.value
    $item.add_Click({
        param($sender, $eventArgs)
        Set-Scale ([double]$sender.Tag) $true
    })
    $script:sizeItems += $item
    $sizeMenu.DropDownItems.Add($item) | Out-Null
}
$sizeMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miScaleUp = [System.Windows.Forms.ToolStripMenuItem]::new('放大 (滚轮上)')
$miScaleUp.add_Click({ Set-Scale ([double]$state.scale + 0.1) $true })
$sizeMenu.DropDownItems.Add($miScaleUp) | Out-Null

$miScaleDown = [System.Windows.Forms.ToolStripMenuItem]::new('缩小 (滚轮下)')
$miScaleDown.add_Click({ Set-Scale ([double]$state.scale - 0.1) $true })
$sizeMenu.DropDownItems.Add($miScaleDown) | Out-Null

$miScaleCustom = [System.Windows.Forms.ToolStripMenuItem]::new('自定义…')
$miScaleCustom.add_Click({
    try {
        $current = [int]([double]$state.scale * 100)
        $input = [Microsoft.VisualBasic.Interaction]::InputBox(
            "输入桌宠大小百分比（25 - 300）：", '自定义桌宠大小', [string]$current)
        if ($input) {
            $pct = 0
            if ([int]::TryParse($input.Trim(), [ref]$pct)) {
                if ($pct -ge 25 -and $pct -le 300) { Set-Scale ($pct / 100.0) $true }
                else { [System.Windows.Forms.MessageBox]::Show('请输入 25 到 300 之间的数字。', '桌宠大小') | Out-Null }
            } else {
                [System.Windows.Forms.MessageBox]::Show('请输入数字，例如 125。', '桌宠大小') | Out-Null
            }
        }
    } catch {
        Note-TickError 'scale-custom' $_
    }
})
$sizeMenu.DropDownItems.Add($miScaleCustom) | Out-Null

$miScaleReset = [System.Windows.Forms.ToolStripMenuItem]::new('恢复默认 (62%)')
$miScaleReset.add_Click({ Set-Scale ([double]$Config.Scale) $true })
$sizeMenu.DropDownItems.Add($miScaleReset) | Out-Null

$menu.Items.Add($sizeMenu) | Out-Null

# 间距菜单：气泡与头顶的距离
$gapMenu = [System.Windows.Forms.ToolStripMenuItem]::new('间距')
$script:gapPresets = @(
    @{ label = '紧贴'; value = -28 },
    @{ label = '较近'; value = -22 },
    @{ label = '标准'; value = -18 },
    @{ label = '稍远'; value = -12 },
    @{ label = '较远'; value = -6 },
    @{ label = '默认'; value = -4 }
)
$script:gapItems = @()
foreach ($preset in $script:gapPresets) {
    $item = [System.Windows.Forms.ToolStripMenuItem]::new([string]$preset.label)
    $item.Tag = [int]$preset.value
    $item.add_Click({
        param($sender, $eventArgs)
        Set-Gap ([int]$sender.Tag) $true
    })
    $script:gapItems += $item
    $gapMenu.DropDownItems.Add($item) | Out-Null
}
$gapMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miGapCloser = [System.Windows.Forms.ToolStripMenuItem]::new('更近 (快捷)')
$miGapCloser.add_Click({ Set-Gap ([int]$state.gapPx - 3) $true })
$gapMenu.DropDownItems.Add($miGapCloser) | Out-Null
$miGapFarther = [System.Windows.Forms.ToolStripMenuItem]::new('更远 (快捷)')
$miGapFarther.add_Click({ Set-Gap ([int]$state.gapPx + 3) $true })
$gapMenu.DropDownItems.Add($miGapFarther) | Out-Null
$menu.Items.Add($gapMenu) | Out-Null

# 多任务展示菜单：多会话并行时气泡里怎么展示进展（全部 / 轮换 / 单条）
$multiMenu = [System.Windows.Forms.ToolStripMenuItem]::new('多任务展示')
$script:multiItems = @{}
$script:multiModes = @(
    @{ label = '全部展示（逐条列出）';   value = 'all' },
    @{ label = '轮换展示（每几秒一条）'; value = 'rotate' },
    @{ label = '仅展示最活跃任务';       value = 'single' }
)
foreach ($preset in $script:multiModes) {
    $multiValue = [string]$preset.value
    $item = [System.Windows.Forms.ToolStripMenuItem]::new([string]$preset.label)
    $item.Tag = $multiValue
    $item.add_Click({
        param($sender, $eventArgs)
        $state.multiTaskMode = [string]$sender.Tag
        $state.rotateIndex = 0
        $state.rotateLastCount = -1
        $state.rotateAt = Get-Date
        Update-MultiMenuChecks
        Save-Settings
    })
    $script:multiItems[$multiValue] = $item
    $multiMenu.DropDownItems.Add($item) | Out-Null
}
$multiMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$rotateIntervalMenu = [System.Windows.Forms.ToolStripMenuItem]::new('轮换间隔')
$script:rotateItems = @()
$script:rotatePresets = @(
    @{ label = '2 秒'; value = 2 },
    @{ label = '4 秒'; value = 4 },
    @{ label = '8 秒'; value = 8 }
)
foreach ($preset in $script:rotatePresets) {
    $item = [System.Windows.Forms.ToolStripMenuItem]::new([string]$preset.label)
    $item.Tag = [int]$preset.value
    $item.add_Click({
        param($sender, $eventArgs)
        $state.rotateSec = [int]$sender.Tag
        $state.rotateAt = Get-Date
        Update-MultiMenuChecks
        Save-Settings
    })
    $script:rotateItems += $item
    $rotateIntervalMenu.DropDownItems.Add($item) | Out-Null
}
$multiMenu.DropDownItems.Add($rotateIntervalMenu) | Out-Null
$menu.Items.Add($multiMenu) | Out-Null

function Update-MultiMenuChecks {
    try {
        foreach ($key in @($script:multiItems.Keys)) {
            $script:multiItems[$key].Checked = ([string]$state.multiTaskMode -eq [string]$key)
        }
        foreach ($item in $script:rotateItems) {
            $item.Checked = ([int]$state.rotateSec -eq [int]$item.Tag)
        }
    } catch { }
}

function Update-GapMenuChecks {
    try {
        foreach ($item in $script:gapItems) {
            $target = [int]$item.Tag
            $item.Checked = ([int]$state.gapPx -eq $target)
        }
    } catch { }
}

$miPause = [System.Windows.Forms.ToolStripMenuItem]::new('暂停')
$miPause.add_Click({
    $state.paused = -not $state.paused
    if ($state.paused) { $miPause.Text = '继续' } else { $miPause.Text = '暂停' }
    # 暂停瞬间把当前状态画出来（动画停了，但气泡/提示不该停在旧内容或 "..."）
    if ($state.paused) { Render-PausedFrame }
    Save-Settings
})
$menu.Items.Add($miPause) | Out-Null

# 浮动开关：关闭后小宠静止不动，不分散注意力
$miFloat = [System.Windows.Forms.ToolStripMenuItem]::new('浮动动画')
$miFloat.Checked = $true
$miFloat.add_Click({
    $state.floating = -not $state.floating
    $miFloat.Checked = $state.floating
    if (-not $state.floating) {
        # 关闭浮动时立即归零，避免停在半空
        $floatTransform.Y = 0
        $floatTransform.X = 0
    }
    Save-Settings
})
$menu.Items.Add($miFloat) | Out-Null

$miThrough = [System.Windows.Forms.ToolStripMenuItem]::new('鼠标穿透')
$miThrough.Enabled = $script:clickThroughAvailable
$miThrough.add_Click({
    try {
        $state.clickThrough = -not $state.clickThrough
        $handle = ([System.Windows.Interop.WindowInteropHelper]::new($window)).Handle
        $GWL_EXSTYLE = -20
        $WS_EX_TRANSPARENT = 0x20
        $style = [KunPet.Win32]::GetWindowLong($handle, $GWL_EXSTYLE)
        $newStyle = if ($state.clickThrough) { $style -bor $WS_EX_TRANSPARENT } else { $style -band (-bnot $WS_EX_TRANSPARENT) }
        [KunPet.Win32]::SetWindowLong($handle, $GWL_EXSTYLE, $newStyle) | Out-Null
        $miThrough.Checked = $state.clickThrough
    } catch {
        Note-TickError 'click-through' $_
    }
})
$menu.Items.Add($miThrough) | Out-Null

$miReset = [System.Windows.Forms.ToolStripMenuItem]::new('重置位置')
$miReset.add_Click({
    try {
        $wa2 = [System.Windows.SystemParameters]::WorkArea
        $window.Left = $wa2.Right - 260
        $window.Top  = $wa2.Bottom - 320
    } catch { }
})
$menu.Items.Add($miReset) | Out-Null

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miExit = [System.Windows.Forms.ToolStripMenuItem]::new('退出')
$miExit.add_Click({
    Write-Log 'exit requested'
    $notify.Visible = $false
    $window.Close()
})
$menu.Items.Add($miExit) | Out-Null

$notify.ContextMenuStrip = $menu
$notify.Visible = $true

# 宠物子菜单：内置 + 已发现素材
function Rebuild-PetMenu {
    $petMenu.DropDownItems.Clear()
    $builtin = [System.Windows.Forms.ToolStripMenuItem]::new('内置形象')
    $builtin.Tag = -1
    $builtin.Checked = ($state.petMode -ne 'sprite')
    $builtin.add_Click({
        param($sender, $eventArgs)
        # 走统一入口：会把 petId 记成 'builtin' 并落盘，下次启动才会保持「内置形象」
        Set-PetSelection -1 $true
    })
    $petMenu.DropDownItems.Add($builtin) | Out-Null
    for ($i = 0; $i -lt $script:pets.Count; $i++) {
        $pet = $script:pets[$i]
        $itemLabel = $pet.Name
        # WebP 需要系统编解码器（Windows「Webp 图像扩展」）；探测失败时在菜单里标注
        $probe = Load-PetSheet $i
        if (-not $probe) {
            $ext = [System.IO.Path]::GetExtension($pet.Sheet).ToLowerInvariant()
            if ($ext -eq '.webp') { $itemLabel = $pet.Name + '（需 WebP 扩展）' }
            else { $itemLabel = $pet.Name + '（素材不可用）' }
        }
        $item = [System.Windows.Forms.ToolStripMenuItem]::new($itemLabel)
        $item.Tag = $i
        $item.Checked = ($state.petMode -eq 'sprite' -and $state.petIndex -eq $i)
        $item.add_Click({
            param($sender, $eventArgs)
            Set-PetSelection ([int]$sender.Tag) $true
        })
        $petMenu.DropDownItems.Add($item) | Out-Null
    }
    if ($script:pets.Count -eq 0) {
        $hint = [System.Windows.Forms.ToolStripMenuItem]::new('（未发现 petdex 素材）')
        $hint.Enabled = $false
        $petMenu.DropDownItems.Add($hint) | Out-Null
    }
}

try {
    $script:pets = @(Find-Pets)
    Write-Log ("pets discovered: {0}" -f $script:pets.Count)
} catch {
    Write-Log ("pet discovery failed: " + $_.Exception.Message)
}

# 载入用户设置（大小/素材/暂停/位置），再按 petId 恢复上次的形象。
# 顺序很重要：必须先把设置读进来，否则菜单勾选和实际形象都会停在默认值。
Load-Settings
# 上次保存的素材可能已被卸载、改名或（WebP 缺编解码器时）加载不了。
# 这种情况下自动回退到任一可用素材，而不是直接掉回默认形象。
$savedPetId = [string]$state.petId
if ($savedPetId -and $savedPetId -ne 'none' -and $savedPetId -ne 'builtin') {
    $restored = -1
    for ($i = 0; $i -lt $script:pets.Count; $i++) {
        if ([string]$script:pets[$i].Id -eq $savedPetId) { $restored = $i; break }
    }
    if ($restored -ge 0 -and (Test-PetLoadable $restored)) {
        Set-PetSelection $restored $false
        Write-Log ("pet restored from settings: {0}" -f $savedPetId)
    } else {
        $fallback = -1
        for ($i = 0; $i -lt $script:pets.Count; $i++) {
            if ((Test-PetLoadable $i) -and [string]$script:pets[$i].Id -ne $savedPetId) { $fallback = $i; break }
        }
        if ($fallback -ge 0) {
            Set-PetSelection $fallback $true
            Write-Log ("saved pet '{0}' unavailable; using '{1}' now (saved preference kept for it to return)" -f $savedPetId, $script:pets[$fallback].Id)
            # 回退不覆盖用户原来的偏好：素材回来（重新安装 / 补上 WebP 扩展）后仍会恢复
            $state.petId = $savedPetId
            Save-Settings
        } else {
            $state.petMode = 'vector'; $state.petIndex = -1
            Rebuild-PetMenu
            Write-Log ("saved pet '{0}' unavailable and no usable material found; using built-in figure (petId kept for later)" -f $savedPetId)
        }
    }
} elseif ($savedPetId -eq 'builtin') {
    $state.petMode = 'vector'; $state.petIndex = -1
    Rebuild-PetMenu
    Write-Log 'pet restored from settings: builtin figure'
} else {
    # 从未保存过（首次运行）：给一个可用素材当默认，免得用户以为桌宠没反应
    $firstUsable = -1
    for ($i = 0; $i -lt $script:pets.Count; $i++) {
        if (Test-PetLoadable $i) { $firstUsable = $i; break }
    }
    if ($firstUsable -ge 0) {
        Set-PetSelection $firstUsable $true
        Write-Log ("no saved pet; defaulting to first usable material: {0}" -f $script:pets[$firstUsable].Id)
    } else {
        $state.petMode = 'vector'; $state.petIndex = -1
        Rebuild-PetMenu
        Write-Log 'no saved pet and no usable material; using built-in figure'
    }
}
Apply-Scale
Apply-Gap
Update-GapMenuChecks
Update-MultiMenuChecks
if ($state.paused) { $miPause.Text = '继续' }
$miFloat.Checked = [bool]$state.floating
# 启动时若处于暂停：先按当前状态画一帧，避免气泡停在上一个会话的旧文字或 "..."
if ($state.paused) { Render-PausedFrame }

# ---------------- 轮询 ----------------
$pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromMilliseconds($Config.PollMs)
$pollTimer.Add_Tick({
    try {
        # 注意：这里**不再**因为暂停而 return。暂停只冻结小宠的动画，
        # 任务气泡/进度/等待提示必须照常刷新（否则一暂停就什么都看不到了）。
        # 优先读会话投影缓存（始终可用），再退到插件端点，最后是活跃度兜底。
        # 插件端点每次都读：它额外提供「待审批」列表（可在桌宠上直接放行/拒绝）
        $snap = Get-StateFromHarness
        $dshSnap = Get-StateFromDsh
        # 插件通道变化只记一行日志：这是「审批时气泡没提示」最关键的排查线索
        $channelNow = $null
        if ($null -ne $dshSnap -and $dshSnap.ContainsKey('approvalChannel') -and $dshSnap.approvalChannel) {
            $channelNow = [string]$dshSnap.approvalChannel
        }
        if ($channelNow -ne $state.dshChannel) {
            $state.dshChannel = $channelNow
            if ($channelNow) {
                Write-Log ('plugin channel: ' + $channelNow)
            } else {
                Write-Log 'plugin channel: unavailable (/kun-pet/state 无响应，也没有新鲜的 kun-pet-state.json)'
            }
        }
        if ($null -eq $snap) {
            $snap = $dshSnap
        } elseif ($null -ne $dshSnap) {
            # 会话缓存里没有「权限审批」（只有提问），所以审批状态一律以插件端点为准：
            # 即使缓存认为“在干活”，只要有待审批就切成等待，否则桌宠不会提示你点同意/拒绝
            $mergeWait = $false
            try { $mergeWait = [bool]$dshSnap.waiting } catch { }
            if ($mergeWait) {
                $snap.mode = 'waiting'
                $snap.waiting = $true
                foreach ($k in @('waitingKind', 'waitingCount', 'waitingSeconds', 'message')) {
                    if ($dshSnap.ContainsKey($k) -and $null -ne $dshSnap[$k]) { $snap[$k] = $dshSnap[$k] }
                }
                if ($dshSnap.ContainsKey('pendingApprovals')) {
                    $snap['pendingApprovals'] = @($dshSnap['pendingApprovals'])
                    if (@($dshSnap['pendingApprovals']).Count -gt 0) { $snap['waitingKind'] = 'approval' }
                }
            }
        }
        if ($null -eq $snap) {
            $snap = Get-StateFromSessions
            if ($null -eq $snap) { $snap = @{ mode = 'disconnected'; source = 'none' } }
        }
        $state.lastSource = $snap.source
        Update-ApprovalPanel $dshSnap
        # 记下气泡要用的等待信息（权限 / 提问都记）：动画定时器据此渲染醒目气泡
        $state.waiting = $false
        $state.waitingKind = $null
        $state.waitingSeconds = 0
        $state.questionText = ''
        $state.questionHeader = ''
        $state.questionDetail = ''
        $state.questionOptions = @()
        $state.questionMulti = $false
        $state.questionKind = ''
        $state.questionApprove = ''
        if ($snap.ContainsKey('waiting')) { $state.waiting = [bool]$snap.waiting }
        if ($snap.ContainsKey('waitingKind') -and $snap.waitingKind) { $state.waitingKind = [string]$snap.waitingKind }
        if ($snap.ContainsKey('waitingSeconds')) { $state.waitingSeconds = [int]$snap.waitingSeconds }
        if ($snap.ContainsKey('questionText') -and $snap.questionText) { $state.questionText = [string]$snap.questionText }
        if ($snap.ContainsKey('questionHeader') -and $snap.questionHeader) { $state.questionHeader = [string]$snap.questionHeader }
        if ($snap.ContainsKey('questionDetail') -and $snap.questionDetail) { $state.questionDetail = [string]$snap.questionDetail }
        if ($snap.ContainsKey('questionOptions')) { $state.questionOptions = @($snap.questionOptions) }
        if ($snap.ContainsKey('questionMulti')) { $state.questionMulti = [bool]$snap.questionMulti }
        if ($snap.ContainsKey('questionKind') -and $snap.questionKind) { $state.questionKind = [string]$snap.questionKind }
        if ($snap.ContainsKey('questionApprove') -and $snap.questionApprove) { $state.questionApprove = [string]$snap.questionApprove }
        # 每次都调用 Set-Mode：其内部对“模式未变”会立即返回，
        # 因此既能保证模式变化时立刻切换动画，又不会重复触发。
        # （不能只在 seq 变化时调用：等待确认等模式变化时轮次/步骤可能没变）
        if ($snap.ContainsKey('seq')) { $state.seq = $snap.seq }
        Set-Mode $snap.mode
        # 主动提醒（等待确认 / 任务结束）——暂停时同样要喊人
        Update-Alerts $snap
    } catch { Note-TickError 'poll' $_ }
})
$pollTimer.Start()

# ---------------- 动画 ----------------
$script:phase = 0.0
$animTimer = New-Object System.Windows.Threading.DispatcherTimer
$animTimer.Interval = [TimeSpan]::FromMilliseconds($Config.AnimFpsMs)
$animTimer.Add_Tick({
    try {
        $pausedNow = [bool]$state.paused
        # 显示动作用局部变量，不回写 $state.action：
        # 拖拽/反应是临时覆盖，回写会导致松手后动作卡住不回待机
        $action = $state.action
        if ($state.reaction -and (Get-Date) -lt $state.reactionEnd) {
            $action = [string]$state.reaction
        } elseif ($state.reaction) {
            # 反应到期：清掉临时覆盖，回到模式对应的动作
            $state.reaction = $null
            if ($ModeToActionMap.ContainsKey($state.mode)) {
                $state.action = $ModeToActionMap[$state.mode]
            } else {
                $state.action = 'idle'
            }
            $action = $state.action
        }
        if ($state.dragging) { $action = $state.dragDir }

        # 暂停 = 只冻结小宠本身：不推进帧、不做浮动/缩放、不重画形象。
        # 下面的气泡/进度/等待提示一律照常刷新（这是暂停时唯一还在动的东西）。
        if (-not $pausedNow) {
        $script:phase += 0.09

        # 帧推进
        $anim = $ActionAnimMap[$action]
        if (-not $anim) { $anim = $ActionAnimMap['idle'] }
        $now = Get-Date
        if (($now - $state.frameAt).TotalMilliseconds -ge [double]$anim.fps) {
            $state.frame = $state.frame + 1
            $state.frameAt = $now
        }
        # 16 向视线：约每 700ms 顺时针一格
        $state.lookTick = $state.lookTick + 1
        if ($state.lookTick -ge 18) {
            $state.lookTick = 0
            $state.lookIndex = ($state.lookIndex + 1) % 16
        }

        $amp = [double]$anim.amp
        $wobble = [double]$anim.wobble
        $floatX = 0.0
        $floatY = 0.0
        if ($state.floating) {
            $floatY = [math]::Sin($script:phase) * $amp
            if ($wobble -gt 0) { $floatX = [math]::Sin($script:phase * 2.4) * $wobble }
        }
        $alerting = ((Get-Date) -lt $state.alertFlashUntil)
        if ($state.petMode -eq 'sprite') {
            # 像素素材：位移取整 + 不做逐帧缩放。
            # 亚像素位移/连续缩放会让整张贴图每帧重新重采样（像素边缘来回抖），
            # 也就是「频闪」；整数位移 + 固定缩放后每帧栅格完全一致，画面是稳的。
            if ($alerting) { $floatY = $floatY - [math]::Round(6.0 * [math]::Abs([math]::Sin($script:phase * 3.0))) }
            $snapX = [math]::Round($floatX)
            $snapY = [math]::Round($floatY)
            if ([double]$floatTransform.X -ne $snapX) { $floatTransform.X = $snapX }
            if ([double]$floatTransform.Y -ne $snapY) { $floatTransform.Y = $snapY }
            if ([double]$petScale.ScaleX -ne 1.0) { $petScale.ScaleX = 1.0; $petScale.ScaleY = 1.0 }
        } else {
            # 矢量形象是纯路径，缩放不会重采样位图，保留呼吸/脉冲效果
            $scaleNow = 1.0 + [math]::Sin($script:phase) * 0.02
            if ($alerting) { $scaleNow = $scaleNow + 0.07 + [math]::Sin($script:phase * 2.0) * 0.05 }
            $petScale.ScaleX = $scaleNow
            $petScale.ScaleY = $scaleNow
            $floatTransform.X = $floatX
            $floatTransform.Y = $floatY
        }

        if ($state.petMode -eq 'sprite') {
            Show-PetFrame $action
        } else {
            Update-VectorLook $action
        }
        }   # ← 暂停分支结束：以下气泡/进度/提示在暂停时也照常刷新

        # ---- 等待用户介入：气泡给「不一样的、看得懂」的提示 ----
        # 权限审批（桌宠上可直接 ✓/✗）与 Agent 提问（带选项）分开措辞，配色也不同，
        # 桌面上扫一眼就知道任务停在哪、要你选什么。
        $waitItems = @($state.approvalItems)
        $waitedLabel = ''
        if ([int]$state.waitingSeconds -gt 0) { $waitedLabel = '（已等 {0} 秒）' -f [int]$state.waitingSeconds }
        $bubbleValue = ''
        $waitProgress = ''
        $waitKindLabel = ''
        if ($waitItems.Count -gt 0) {
            $waitKindLabel = 'approval'
            $it = $waitItems[0]
            $bubbleValue = '⏳ 需要你确认权限' + $waitedLabel
            $waitLines = @('工具：' + [string]$it.toolName)
            $reason = ''
            try { if ($it.reason) { $reason = [string]$it.reason } } catch { }
            if ($reason) { $waitLines += ('原因：' + (Limit-Text $reason 36)) }
            if ([string]$state.approvalChannel -eq 'file') {
                # 只有状态快照文件通道：气泡照样提示，但决策要回 Harness 做
                $waitLines += '切回 Harness 窗口点「同意 / 拒绝」'
            } elseif (-not [bool]$state.approvalAnswerable) {
                # 插件已经把这次请求交给 Harness 的确认框了：桌宠只提示，不再给按钮
                $waitLines += 'Harness 已弹出确认框，去窗口里点'
            } else {
                $waitLines += '桌宠上点「✓同意 / ✗拒绝」'
            }
            if ($waitItems.Count -gt 1) { $waitLines += ('另有 {0} 个待确认' -f ($waitItems.Count - 1)) }
            $waitProgress = ($waitLines -join "`n")
        } elseif ($state.waiting -or $state.mode -eq 'waiting') {
            $waitKindLabel = 'question'
            $opts = @($state.questionOptions)
            $qt = [string]$state.questionText
            $waitLines = @()
            if ([string]$state.questionKind -eq 'plan-review') {
                # Agent 提交了方案等你批准（ask_user_question 的 plan-review intent）
                $bubbleValue = '📋 需要你确认方案' + $waitedLabel
                if ($qt) { $waitLines += (Limit-Text $qt 46) }
                if ([string]$state.questionDetail) { $waitLines += (Limit-Text ([string]$state.questionDetail) 40) }
                if ([string]$state.questionApprove) { $waitLines += ('同意请点：' + [string]$state.questionApprove) }
                $waitLines += '切回 Harness 看方案全文'
            } else {
                $multiLabel = ''
                if ($state.questionMulti) { $multiLabel = '（可多选）' }
                $bubbleValue = '❓ 需要你选一下' + $multiLabel + $waitedLabel
                if ($qt) { $waitLines += ('问题：' + (Limit-Text $qt 44)) }
                elseif ($state.progressText) { $waitLines += (Limit-Text ([string]$state.progressText) 44) }
                if ([string]$state.questionDetail) { $waitLines += ('说明：' + (Limit-Text ([string]$state.questionDetail) 36)) }
                for ($oi = 0; $oi -lt [math]::Min(4, $opts.Count); $oi++) {
                    $waitLines += ('{0}) {1}' -f ($oi + 1), [string]$opts[$oi])
                }
                if ($opts.Count -gt 4) { $waitLines += ('… 共 {0} 个选项' -f $opts.Count) }
                if ($opts.Count -eq 0) { $waitLines += '切回 Harness 窗口作答' }
            }
            $waitProgress = ($waitLines -join "`n")
        }

        if (-not $bubbleValue) {
            $bubbleValue = '怎么还不来找我~有事找我'
            if ($BubbleMap.ContainsKey($action)) { $bubbleValue = $BubbleMap[$action] }
            if ($action -eq 'idle' -and $state.mode -eq 'disconnected') { $bubbleValue = $BubbleMap['disconnected'] }
        }
        if ($bubbleTextEl.Text -ne $bubbleValue) { $bubbleTextEl.Text = $bubbleValue }

        # 等待提示换配色：提问=琥珀，审批=绿（与面板上的 ✓/✗ 呼应）
        if ($script:bubbleTint -ne $waitKindLabel) {
            $script:bubbleTint = $waitKindLabel
            if ($waitKindLabel -eq 'approval') {
                $bubbleEl.Background = $script:brushWaitApproval
                $bubbleEl.BorderBrush = $script:brushWaitApprovalBorder
                $bubbleTailEl.Fill = $script:brushWaitApproval
                $bubbleTailEl.Stroke = $script:brushWaitApprovalBorder
            } elseif ($waitKindLabel -eq 'question') {
                $bubbleEl.Background = $script:brushWaitQuestion
                $bubbleEl.BorderBrush = $script:brushWaitQuestionBorder
                $bubbleTailEl.Fill = $script:brushWaitQuestion
                $bubbleTailEl.Stroke = $script:brushWaitQuestionBorder
            } else {
                $bubbleEl.Background = $script:brushBubble
                $bubbleEl.BorderBrush = $script:brushBubbleBorder
                $bubbleTailEl.Fill = $script:brushBubble
                $bubbleTailEl.Stroke = $script:brushBubbleBorder
            }
        }

        # 进展详情直接显示在气泡内（贴近形象，一眼可见）；
        # 轮换模式下每帧检查是否该切到下一个任务
        Apply-ProgressDisplay
        $progressValue = [string]$state.progressText
        if ($waitProgress) { $progressValue = $waitProgress }
        $targetProgressVis = 'Collapsed'
        if ($progressValue) { $targetProgressVis = 'Visible' }
        if ([string]$progressTextEl.Visibility -ne $targetProgressVis) { $progressTextEl.Visibility = $targetProgressVis }
        if ($progressValue -and $progressTextEl.Text -ne $progressValue) { $progressTextEl.Text = $progressValue }

        # 尺寸随缩放（气泡尾巴与文字同步，保证贴合不脱节）；只在真的变了才写，
        # 避免每帧无谓地触发一次布局
        $tailScale = [math]::Max(0.85, [math]::Min([double]$state.scale, 1.6))
        $tailW = [math]::Round(16 * $tailScale, 1)
        $tailH = [math]::Round(10 * $tailScale, 1)
        if ([double]$bubbleTailEl.Width -ne $tailW) { $bubbleTailEl.Width = $tailW }
        if ([double]$bubbleTailEl.Height -ne $tailH) { $bubbleTailEl.Height = $tailH }

        $elapsedSec = [int]((Get-Date) - $state.modeStart).TotalSeconds
        $sourceLabel = switch ($state.lastSource) {
            'harness'  { 'Harness 实时' }
            'dsh'      { 'DSH 插件接口' }
            'dsh-file' { 'DSH 插件快照文件' }
            'sessions' { '会话活跃度(兜底)' }
            default    { '未连接' }
        }
        $pauseLabel = ''
        if ($state.paused) { $pauseLabel = ' · 已暂停' }
        # 进展显示在气泡里；底部只保留来源/时长等辅助信息（仅变化时写，减少布局）
        $hintValue = '{0}{1} · 已 {2}s' -f $sourceLabel, $pauseLabel, $elapsedSec
        if ($hintTextEl.Text -ne $hintValue) { $hintTextEl.Text = $hintValue }
    } catch { Note-TickError 'anim' $_ }
})
$animTimer.Start()

# ---------------- 交互：拖动 / 单击挥手 / 双击跳一下 ----------------
$script:dragStart = $null
$script:clickPending = $false
$script:clickTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:clickTimer.Interval = [TimeSpan]::FromMilliseconds(260)
$script:clickTimer.Add_Tick({
    $script:clickTimer.Stop()
    if ($script:clickPending) {
        $script:clickPending = $false
        # 暂停时小宠是冻结的：不再挥手/出声，只有气泡与提示在更新
        if (-not $state.paused) {
            Set-Action 'waving' 1600
            Play-Tones -freqs @(660, 880) -durMs 90 -gapMs 90
        }
    }
})

# 审批面板按钮：同意 = allowed-once，拒绝 = rejected（一次性决策）
$btnApproveEl.Add_Click({ Send-ApprovalDecision 'allowed-once' })
$btnRejectEl.Add_Click({ Send-ApprovalDecision 'rejected' })

$window.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    try {
        # 不用 DragMove()：它是模态循环，拖动期间收不到 MouseMove，方向动画无法更新
        $relPoint = [System.Windows.Input.Mouse]::GetPosition($window)
        $screenPoint = $window.PointToScreen($relPoint)
        $script:dragStart = @{
            screenX = $screenPoint.X
            screenY = $screenPoint.Y
            left    = $window.Left
            top     = $window.Top
            moved   = $false
        }
        $state.dragging = $true
        $state.dragDir = 'running-right'
        try { $window.CaptureMouse() | Out-Null } catch { }
    } catch {
        $state.dragging = $false
        Note-TickError 'drag-down' $_
    }
})
$window.Add_MouseMove({
    try {
        if ($null -ne $script:dragStart -and $state.dragging) {
            $relPoint = [System.Windows.Input.Mouse]::GetPosition($window)
            $screenPoint = $window.PointToScreen($relPoint)
            $deltaX = $screenPoint.X - $script:dragStart.screenX
            $deltaY = $screenPoint.Y - $script:dragStart.screenY
            if ([math]::Abs($deltaX) -gt 3 -or [math]::Abs($deltaY) -gt 3) { $script:dragStart.moved = $true }
            if ($deltaX -gt 2) { $state.dragDir = 'running-right' }
            elseif ($deltaX -lt -2) { $state.dragDir = 'running-left' }
            $window.Left = $script:dragStart.left + $deltaX
            $window.Top  = $script:dragStart.top + $deltaY
        }
    } catch { Note-TickError 'drag-move' $_ }
})
$window.Add_MouseLeftButtonUp({
    try {
        if ($null -ne $script:dragStart) {
            $moved = [bool]$script:dragStart.moved
            $script:dragStart = $null
            $state.dragging = $false
            try { $window.ReleaseMouseCapture() } catch { }
            if ($moved) { Save-Settings }
            if (-not $moved) {
                if ($script:clickPending) {
                    # 双击 = 跳一下
                    $script:clickPending = $false
                    $script:clickTimer.Stop()
                    Set-Action 'jumping' 1800
                    Play-Tones -freqs @(784, 1046) -durMs 110 -gapMs 100
                } else {
                    $script:clickPending = $true
                    $script:clickTimer.Start()
                }
            }
        }
    } catch { Note-TickError 'click' $_ }
})

# 滚轮缩放：悬停在小宠上滚动即可改大小（与图片查看器一致的手感）
$window.Add_MouseWheel({
    param($sender, $eventArgs)
    try {
        $step = 0.1
        $delta = [double]$eventArgs.Delta
        if ($delta -gt 0) { Set-Scale ([double]$state.scale + $step) $true }
        elseif ($delta -lt 0) { Set-Scale ([double]$state.scale - $step) $true }
        $eventArgs.Handled = $true
    } catch {
        Note-TickError 'wheel-scale' $_
    }
})

# Ctrl+, 打开菜单（与 Codex 桌宠一致）
$window.Add_KeyDown({
    param($sender, $eventArgs)
    try {
        if ($eventArgs.Key -eq [System.Windows.Input.Key]::OemComma -and
            ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
            $menu.Show([System.Windows.Forms.Cursor]::Position)
            $eventArgs.Handled = $true
        }
    } catch { }
})
# 右键 = 菜单
$window.Add_MouseRightButtonUp({
    try { $menu.Show([System.Windows.Forms.Cursor]::Position) } catch { }
})

$window.Add_Closed({
    $pollTimer.Stop(); $animTimer.Stop(); $script:clickTimer.Stop()
    Save-Settings
    try { $notify.Visible = $false } catch { }
    try { if ($mutex) { $mutex.ReleaseMutex() } } catch { }
    Write-Log 'kun-pet-desktop stopped'
})

# 气泡文字长短会让窗口尺寸变化（SizeToContent 从左上角扩展），
# 小宠会跟着上下跳、左右移。这里把「底边 + 水平中心」钉住：
# 气泡向上/向外生长，小宠待在原地不动。
$script:winW = 0.0
$script:winH = 0.0
$script:syncingSize = $false
$script:pendingPosW = 0.0
$script:pendingPosH = 0.0
$window.Add_SizeChanged({
    try {
        if ($script:syncingSize) { return }
        $w = [double]$window.ActualWidth
        $h = [double]$window.ActualHeight
        if ($w -le 0 -or $h -le 0) { return }
        # 首次布局：按上次保存的尺寸还原「底边 + 水平中心」，
        # 这样重启后小宠还停在你放的位置，不会因为气泡行数不同而挪窝
        if ($script:pendingPosH -gt 0) {
            $adjW = ($script:pendingPosW - $w) / 2.0
            $adjH = $script:pendingPosH - $h
            $script:pendingPosW = 0.0
            $script:pendingPosH = 0.0
            $nl = [double]$window.Left + $adjW
            $nt = [double]$window.Top + $adjH
            # 别把窗口还回到屏幕外（气泡长的时候底边可能超出工作区）
            $wa = [System.Windows.SystemParameters]::WorkArea
            if ($nl -lt $wa.Left) { $nl = $wa.Left }
            if ($nl + $w -gt $wa.Right) { $nl = $wa.Right - $w }
            if ($nt + $h -gt $wa.Bottom) { $nt = $wa.Bottom - $h }
            if ($nt -lt $wa.Top) { $nt = $wa.Top }
            $script:syncingSize = $true
            $window.Left = [math]::Round($nl)
            $window.Top = [math]::Round($nt)
            $script:syncingSize = $false
            $script:winW = $w
            $script:winH = $h
            return
        }
        if ($script:winW -gt 0 -and $script:winH -gt 0) {
            $dw = $w - $script:winW
            $dh = $h - $script:winH
            if ([math]::Abs($dw) -gt 0.4 -or [math]::Abs($dh) -gt 0.4) {
                $script:syncingSize = $true
                $window.Left = [math]::Round([double]$window.Left - $dw / 2.0)
                $window.Top  = [math]::Round([double]$window.Top - $dh)
                $script:syncingSize = $false
            }
        }
        $script:winW = $w
        $script:winH = $h
    } catch { Note-TickError 'win-size' $_ }
})

Write-Log 'UI ready, entering message loop'
$null = $window.ShowDialog()
