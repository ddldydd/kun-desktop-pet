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
