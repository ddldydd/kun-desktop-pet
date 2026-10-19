# Kun Like Pet - build a desktop-shortcut icon from a random installed pet.
# Picks a different pet (when more than one is installed) and a random visible
# idle/wave frame, sits it on a random pastel badge, then writes a classic
# 32bpp DIB icon. DIB entries, not PNG-compressed ones: Explorer on this
# machine draws a PNG-only ICO as the generic "unknown file" icon.
param(
    [string]$OutDir = (Join-Path $PSScriptRoot 'assets'),
    [string]$PetRoot = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$metaPath = Join-Path $OutDir 'kun-pet-icon.json'
$prevId = ''
$prevCell = ''
if (Test-Path -LiteralPath $metaPath) {
    try {
        $prev = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($prev.id) { $prevId = [string]$prev.id }
        if ($null -ne $prev.row -and $null -ne $prev.col) { $prevCell = ('{0},{1}' -f [int]$prev.row, [int]$prev.col) }
    } catch { }
}

function Get-PetSheets([string]$extraRoot) {
    $roots = @()
    if ($extraRoot) { $roots += $extraRoot }
    $codex = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $roots += (Join-Path $env:USERPROFILE '.petdex\pets')
    $roots += (Join-Path $codex 'pets')
    $found = @()
    $seen = @{}
    foreach ($dir in $roots) {
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($sub in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)) {
            $sheet = $null
            foreach ($name in @('spritesheet.png', 'spritesheet.PNG')) {
                $candidate = Join-Path $sub.FullName $name
                if (Test-Path -LiteralPath $candidate) { $sheet = $candidate; break }
            }
            if (-not $sheet) { continue }
            if ($seen.ContainsKey($sheet)) { continue }
            $seen[$sheet] = $true
            $display = $sub.Name
            $jsonPath = Join-Path $sub.FullName 'pet.json'
            if (Test-Path -LiteralPath $jsonPath) {
                try {
                    $meta = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($meta.displayName) { $display = [string]$meta.displayName }
                    elseif ($meta.name) { $display = [string]$meta.name }
                } catch { }
            }
            $found += [pscustomobject]@{ Id = $sub.Name; Display = $display; Sheet = $sheet }
        }
    }
    return $found
}

function Get-HslColor([double]$h, [double]$s, [double]$l) {
    $c = (1.0 - [Math]::Abs((2.0 * $l) - 1.0)) * $s
    $hp = ($h % 360.0) / 60.0
    $x = $c * (1.0 - [Math]::Abs(($hp % 2.0) - 1.0))
    $r1 = 0.0; $g1 = 0.0; $b1 = 0.0
    if ($hp -lt 1) { $r1 = $c; $g1 = $x }
    elseif ($hp -lt 2) { $r1 = $x; $g1 = $c }
    elseif ($hp -lt 3) { $g1 = $c; $b1 = $x }
    elseif ($hp -lt 4) { $g1 = $x; $b1 = $c }
    elseif ($hp -lt 5) { $r1 = $x; $b1 = $c }
    else { $r1 = $c; $b1 = $x }
    $m = $l - ($c / 2.0)
    $r = [int][Math]::Round(($r1 + $m) * 255)
    $g = [int][Math]::Round(($g1 + $m) * 255)
    $b = [int][Math]::Round(($b1 + $m) * 255)
    if ($r -lt 0) { $r = 0 } elseif ($r -gt 255) { $r = 255 }
    if ($g -lt 0) { $g = 0 } elseif ($g -gt 255) { $g = 255 }
    if ($b -lt 0) { $b = 0 } elseif ($b -gt 255) { $b = 255 }
    return [System.Drawing.Color]::FromArgb(255, $r, $g, $b)
}

function New-BadgeColor {
    $hue = Get-Random -Minimum 0 -Maximum 360
    return Get-HslColor $hue 0.45 0.90
}

function Get-OpaqueStats([System.Drawing.Bitmap]$bmp) {
    $w = $bmp.Width
    $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = $data.Stride
        $pixels = New-Object byte[] ($stride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
    } finally {
        $bmp.UnlockBits($data)
    }
    $minX = $w; $minY = $h; $maxX = -1; $maxY = -1; $count = 0
    $step = 1
    if ($w -gt 64) { $step = 2 }
    for ($y = 0; $y -lt $h; $y += $step) {
        $row = $y * $stride
        for ($x = 0; $x -lt $w; $x += $step) {
            if ($pixels[$row + ($x * 4) + 3] -gt 16) {
                $count++
                if ($x -lt $minX) { $minX = $x }
                if ($x -gt $maxX) { $maxX = $x }
                if ($y -lt $minY) { $minY = $y }
                if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }
    # Step-2 misses the exact edge by at most one sampled pixel. Grow the box
    # so the ears/feet are not clipped, then clamp.
    if ($maxX -ge 0 -and $step -gt 1) {
        $minX = [Math]::Max(0, $minX - $step)
        $minY = [Math]::Max(0, $minY - $step)
        $maxX = [Math]::Min($w - 1, $maxX + $step)
        $maxY = [Math]::Min($h - 1, $maxY + $step)
    }
    return @{ MinX = $minX; MinY = $minY; MaxX = $maxX; MaxY = $maxY; Count = $count }
}

function Copy-Cell([System.Drawing.Image]$sheet, [int]$col, [int]$row, [int]$cellW, [int]$cellH) {
    $bmp = New-Object System.Drawing.Bitmap $cellW, $cellH, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::Transparent)
        $dest = New-Object System.Drawing.Rectangle 0, 0, $cellW, $cellH
        $src = New-Object System.Drawing.Rectangle ($col * $cellW), ($row * $cellH), $cellW, $cellH
        $g.DrawImage($sheet, $dest, $src, [System.Drawing.GraphicsUnit]::Pixel)
    } finally {
        $g.Dispose()
    }
    return $bmp
}

function New-ComposedIcon([System.Drawing.Bitmap]$trimmed, [int]$size, [System.Drawing.Color]$badge) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $inset = [Math]::Max(1, [int]($size * 0.04))
        $brush = New-Object System.Drawing.SolidBrush $badge
        try {
            $g.FillEllipse($brush, $inset, $inset, ($size - (2 * $inset) - 1), ($size - (2 * $inset) - 1))
        } finally { $brush.Dispose() }
        $pad = [int]($size * 0.12)
        $avail = $size - (2 * $pad)
        if ($avail -lt 1) { $avail = $size }
        $scale = [Math]::Min($avail / [double]$trimmed.Width, $avail / [double]$trimmed.Height)
        $dw = [Math]::Max(1, [int][Math]::Round($trimmed.Width * $scale))
        $dh = [Math]::Max(1, [int][Math]::Round($trimmed.Height * $scale))
        $dx = [int](($size - $dw) / 2)
        $dy = [int](($size - $dh) / 2)
        $g.DrawImage($trimmed, (New-Object System.Drawing.Rectangle $dx, $dy, $dw, $dh))
    } finally {
        $g.Dispose()
    }
    return $bmp
}

function New-ProceduralPet([int]$size, [System.Drawing.Color]$badge) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $inset = [Math]::Max(1, [int]($size * 0.04))
        $bb = New-Object System.Drawing.SolidBrush $badge
        try { $g.FillEllipse($bb, $inset, $inset, ($size - (2 * $inset) - 1), ($size - (2 * $inset) - 1)) }
        finally { $bb.Dispose() }
        $species = Get-Random -Minimum 0 -Maximum 4
        $body = Get-HslColor (Get-Random -Minimum 0 -Maximum 360) 0.55 0.62
        $belly = Get-HslColor (Get-Random -Minimum 0 -Maximum 360) 0.25 0.92
        $cheek = [System.Drawing.Color]::FromArgb(230, 255, 140, 160)
        $bodyBrush = New-Object System.Drawing.SolidBrush $body
        $bellyBrush = New-Object System.Drawing.SolidBrush $belly
        $cheekBrush = New-Object System.Drawing.SolidBrush $cheek
        $ink = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 40, 48, 60))
        $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        try {
            $cx = $size / 2.0
            $bodyW = $size * 0.62
            $bodyH = $size * 0.50
            $bodyX = $cx - ($bodyW / 2.0)
            $bodyY = $size * 0.30
            if ($species -eq 1) {
                $g.FillEllipse($bodyBrush, ($cx - $bodyW * 0.42), ($size * 0.16), ($bodyW * 0.28), ($bodyH * 0.42))
                $g.FillEllipse($bodyBrush, ($cx + $bodyW * 0.14), ($size * 0.16), ($bodyW * 0.28), ($bodyH * 0.42))
            } elseif ($species -eq 2) {
                $g.FillEllipse($bodyBrush, ($cx - $bodyW * 0.34), ($size * 0.08), ($bodyW * 0.18), ($bodyH * 0.55))
                $g.FillEllipse($bodyBrush, ($cx + $bodyW * 0.16), ($size * 0.08), ($bodyW * 0.18), ($bodyH * 0.55))
            }
            $g.FillEllipse($bodyBrush, $bodyX, $bodyY, $bodyW, $bodyH)
            $g.FillEllipse($bellyBrush, ($cx - $bodyW * 0.28), ($bodyY + $bodyH * 0.38), ($bodyW * 0.56), ($bodyH * 0.42))
            $eye = [Math]::Max(2, [int]($size * 0.07))
            $eyeY = [int]($bodyY + $bodyH * 0.28)
            $g.FillEllipse($ink, [int]($cx - $bodyW * 0.22), $eyeY, $eye, [int]($eye * 1.15))
            $g.FillEllipse($ink, [int]($cx + $bodyW * 0.08), $eyeY, $eye, [int]($eye * 1.15))
            $gl = [Math]::Max(1, [int]($eye * 0.35))
            $g.FillEllipse($white, [int]($cx - $bodyW * 0.22 + $eye * 0.15), ($eyeY + 1), $gl, $gl)
            $g.FillEllipse($white, [int]($cx + $bodyW * 0.08 + $eye * 0.15), ($eyeY + 1), $gl, $gl)
            $cheekW = [Math]::Max(3, [int]($size * 0.10))
            $g.FillEllipse($cheekBrush, [int]($cx - $bodyW * 0.40), [int]($eyeY + $eye), $cheekW, [int]($cheekW * 0.7))
            $g.FillEllipse($cheekBrush, [int]($cx + $bodyW * 0.22), [int]($eyeY + $eye), $cheekW, [int]($cheekW * 0.7))
            if ($species -eq 3) {
                $bill = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 176, 64))
                try { $g.FillEllipse($bill, [int]($cx - $size * 0.08), [int]($eyeY + $eye * 1.6), [int]($size * 0.16), [int]($size * 0.08)) }
                finally { $bill.Dispose() }
            } else {
                $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 40, 48, 60), [Math]::Max(1.5, $size * 0.025))
                try { $g.DrawArc($pen, [int]($cx - $size * 0.08), [int]($eyeY + $eye * 1.5), [int]($size * 0.16), [int]($size * 0.10), 10, 160) }
                finally { $pen.Dispose() }
            }
        } finally {
            $bodyBrush.Dispose(); $bellyBrush.Dispose(); $cheekBrush.Dispose(); $ink.Dispose(); $white.Dispose()
        }
    } finally {
        $g.Dispose()
    }
    return $bmp
}

function ConvertTo-DibEntry([System.Drawing.Bitmap]$bmp) {
    $w = $bmp.Width
    $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = $data.Stride
        $pixels = New-Object byte[] ($stride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
    } finally {
        $bmp.UnlockBits($data)
    }
    $maskStride = [int]([Math]::Floor(($w + 31) / 32) * 4)
    $mask = New-Object byte[] ($maskStride * $h)
    $andBit = [byte[]](0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ms
    $bw.Write([UInt32]40)
    $bw.Write([Int32]$w)
    $bw.Write([Int32]($h * 2))
    $bw.Write([UInt16]1)
    $bw.Write([UInt16]32)
    $bw.Write([UInt32]0)
    $bw.Write([UInt32](($w * $h * 4) + ($maskStride * $h)))
    $bw.Write([Int32]0)
    $bw.Write([Int32]0)
    $bw.Write([UInt32]0)
    $bw.Write([UInt32]0)
    for ($y = $h - 1; $y -ge 0; $y--) {
        $rowStart = $y * $stride
        $maskRow = ($h - 1 - $y) * $maskStride
        for ($x = 0; $x -lt $w; $x++) {
            $i = $rowStart + ($x * 4)
            $a = $pixels[$i + 3]
            if ($a -lt 16) {
                $mi = $maskRow + [int][Math]::Floor($x / 8.0)
                $mask[$mi] = [byte]($mask[$mi] -bor $andBit[$x % 8])
                $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0)
            } else {
                $bw.Write([byte]$pixels[$i])
                $bw.Write([byte]$pixels[$i + 1])
                $bw.Write([byte]$pixels[$i + 2])
                $bw.Write([byte]$a)
            }
        }
    }
    $bw.Write($mask)
    $bw.Flush()
    $bytes = $ms.ToArray()
    $bw.Dispose()
    return ,$bytes
}

function Get-AverageColor([System.Drawing.Bitmap]$bmp) {
    $w = $bmp.Width; $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = $data.Stride
        $pixels = New-Object byte[] ($stride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
    } finally { $bmp.UnlockBits($data) }
    $rs = 0L; $gs = 0L; $bs = 0L; $n = 0L
    for ($y = 0; $y -lt $h; $y += 2) {
        $row = $y * $stride
        for ($x = 0; $x -lt $w; $x += 2) {
            $i = $row + ($x * 4)
            if ($pixels[$i + 3] -gt 32) {
                $bs += $pixels[$i]; $gs += $pixels[$i + 1]; $rs += $pixels[$i + 2]; $n++
            }
        }
    }
    if ($n -lt 1) { return @{ R = 0; G = 0; B = 0; N = 0 } }
    return @{ R = [int]($rs / $n); G = [int]($gs / $n); B = [int]($bs / $n); N = [int]$n }
}

$badge = New-BadgeColor
$pickedId = 'generated'
$pickedDisplay = '随机小宠物'
$pickedRow = -1
$pickedCol = -1
$master = $null
$sheetImg = $null
$trimmed = $null

try {
    $sheets = @(Get-PetSheets $PetRoot)
    $pool = $sheets
    if ($prevId -and $sheets.Count -gt 1) {
        $others = @($sheets | Where-Object { $_.Id -ne $prevId })
        if ($others.Count -gt 0) { $pool = $others }
    }
    if ($pool.Count -gt 0) {
        $pet = $pool[(Get-Random -Minimum 0 -Maximum $pool.Count)]
        $sheetImg = [System.Drawing.Image]::FromFile($pet.Sheet)
        $cols = 8
        $rows = 9
        $cellW = [int]($sheetImg.Width / $cols)
        $cellH = [int]($sheetImg.Height / $rows)
        if ($cellW -ge 8 -and $cellH -ge 8) {
            $wantRows = @(0, 3)
            $cands = @()
            foreach ($row in $wantRows) {
                if ($row -ge $rows) { continue }
                for ($col = 0; $col -lt $cols; $col++) {
                    $cell = Copy-Cell $sheetImg $col $row $cellW $cellH
                    $stats = Get-OpaqueStats $cell
                    $key = '{0},{1}' -f $row, $col
                    if ($stats.MaxX -ge 0 -and $stats.Count -ge 40 -and $key -ne $prevCell) {
                        $cands += [pscustomobject]@{ Row = $row; Col = $col; Cell = $cell; Stats = $stats }
                    } else {
                        $cell.Dispose()
                    }
                }
            }
            if ($cands.Count -eq 0) {
                foreach ($row in $wantRows) {
                    $cell = Copy-Cell $sheetImg 0 $row $cellW $cellH
                    $stats = Get-OpaqueStats $cell
                    if ($stats.MaxX -ge 0 -and $stats.Count -ge 20) {
                        $cands += [pscustomobject]@{ Row = $row; Col = 0; Cell = $cell; Stats = $stats }
                        break
                    }
                    $cell.Dispose()
                }
            }
            if ($cands.Count -gt 0) {
                $choice = $cands[(Get-Random -Minimum 0 -Maximum $cands.Count)]
                $st = $choice.Stats
                $bw = $st.MaxX - $st.MinX + 1
                $bh = $st.MaxY - $st.MinY + 1
                $trimmed = New-Object System.Drawing.Bitmap $bw, $bh, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                $gt = [System.Drawing.Graphics]::FromImage($trimmed)
                try {
                    $gt.DrawImage($choice.Cell, (New-Object System.Drawing.Rectangle 0, 0, $bw, $bh), (New-Object System.Drawing.Rectangle $st.MinX, $st.MinY, $bw, $bh), [System.Drawing.GraphicsUnit]::Pixel)
                } finally { $gt.Dispose() }
                $pickedId = [string]$pet.Id
                $pickedDisplay = [string]$pet.Display
                $pickedRow = [int]$choice.Row
                $pickedCol = [int]$choice.Col
                foreach ($c in $cands) { $c.Cell.Dispose() }
            }
        }
    }
    if ($null -eq $trimmed) {
        $master = New-ProceduralPet 256 $badge
    } else {
        $master = New-ComposedIcon $trimmed 256 $badge
    }
} finally {
    if ($trimmed) { $trimmed.Dispose() }
    if ($sheetImg) { $sheetImg.Dispose() }
}

$sizes = @(16, 32, 48, 256)
$bitmaps = @()
try {
    foreach ($s in $sizes) {
        if ($s -eq 256) { $bitmaps += $master; continue }
        $scaled = New-Object System.Drawing.Bitmap $s, $s, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($scaled)
        try {
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.DrawImage($master, 0, 0, $s, $s)
        } finally { $g.Dispose() }
        $bitmaps += $scaled
    }

    $pngPath = Join-Path $OutDir 'kun-pet-icon.png'
    $master.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)

    $entries = New-Object System.Collections.Generic.List[byte[]]
    foreach ($b in $bitmaps) { $entries.Add((ConvertTo-DibEntry $b)) }

    $icoPath = Join-Path $OutDir 'kun-pet-icon.ico'
    $fs = [System.IO.File]::Create($icoPath)
    $iw = New-Object System.IO.BinaryWriter $fs
    try {
        $iw.Write([UInt16]0)
        $iw.Write([UInt16]1)
        $iw.Write([UInt16]$sizes.Count)
        $offset = 6 + (16 * $sizes.Count)
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $s = $sizes[$i]
            $dim = $s
            if ($s -ge 256) { $dim = 0 }
            $iw.Write([byte]$dim)
            $iw.Write([byte]$dim)
            $iw.Write([byte]0)
            $iw.Write([byte]0)
            $iw.Write([UInt16]1)
            $iw.Write([UInt16]32)
            $iw.Write([UInt32]$entries[$i].Length)
            $iw.Write([UInt32]$offset)
            $offset += $entries[$i].Length
        }
        foreach ($e in $entries) { $iw.Write($e) }
    } finally {
        $iw.Dispose()
    }

    $expect = Get-AverageColor $bitmaps[2]
    $probeType = @'
using System;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Drawing.Imaging;
public static class KunPetIconProbe {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern uint PrivateExtractIcons(string szFileName, int nIconIndex, int cxIcon, int cyIcon,
        IntPtr[] phicon, uint[] piconid, uint nIcons, uint flags);
    public static void Save(string ico, int size, string png) {
        IntPtr[] handles = new IntPtr[1];
        uint[] ids = new uint[1];
        uint n = PrivateExtractIcons(ico, 0, size, size, handles, ids, 1, 0);
        if (n == 0 || handles[0] == IntPtr.Zero) throw new Exception("PrivateExtractIcons failed");
        using (Icon tmp = Icon.FromHandle(handles[0]))
        using (Bitmap raw = tmp.ToBitmap())
        using (Bitmap bmp = new Bitmap(raw.Width, raw.Height, PixelFormat.Format32bppArgb)) {
            using (Graphics g = Graphics.FromImage(bmp)) { g.DrawImage(raw, 0, 0); }
            bmp.Save(png, ImageFormat.Png);
        }
    }
}
'@
    if (-not ('KunPetIconProbe' -as [type])) {
        Add-Type -TypeDefinition $probeType -ReferencedAssemblies System.Drawing
    }
    $probePng = Join-Path $OutDir 'icon-probe-48.png'
    [KunPetIconProbe]::Save($icoPath, 48, $probePng)
    $probeBmp = [System.Drawing.Bitmap]::FromFile($probePng)
    try { $got = Get-AverageColor $probeBmp } finally { $probeBmp.Dispose() }
    Remove-Item -LiteralPath $probePng -Force -ErrorAction SilentlyContinue
    $drift = [Math]::Abs($expect.R - $got.R) + [Math]::Abs($expect.G - $got.G) + [Math]::Abs($expect.B - $got.B)
    if ($got.N -lt 30 -or $drift -gt 120) {
        throw ("icon round-trip failed: expect RGB {0},{1},{2} got {3},{4},{5} drift={6}" -f $expect.R, $expect.G, $expect.B, $got.R, $got.G, $got.B, $drift)
    }

    $badgeHex = '#{0:X2}{1:X2}{2:X2}' -f $badge.R, $badge.G, $badge.B
    $metaObj = [pscustomobject]@{
        id = $pickedId
        displayName = $pickedDisplay
        row = $pickedRow
        col = $pickedCol
        badge = $badgeHex
        createdAt = (Get-Date).ToString('s')
    }
    $json = $metaObj | ConvertTo-Json -Compress
    $utf8 = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($metaPath, $json, $utf8)

    Write-Output ("pet={0}" -f $pickedId)
    Write-Output ("display={0}" -f $pickedDisplay)
    Write-Output ("cell={0},{1}" -f $pickedRow, $pickedCol)
    Write-Output ("badge={0}" -f $badgeHex)
    Write-Output ("png={0}" -f $pngPath)
    Write-Output ("ico={0}" -f $icoPath)
    Write-Output ("roundtrip=ok drift={0}" -f $drift)
} finally {
    foreach ($b in $bitmaps) { if ($b) { $b.Dispose() } }
}
