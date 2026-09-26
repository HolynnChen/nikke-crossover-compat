@echo off
rem ============================================================================
rem  NIKKE hosts 加速器（Windows 版）
rem
rem  用途：NIKKE 的多个域名在国内被解析污染（返回 0.0.0.1 / 127.0.0.1），
rem        不写 hosts 就连不上。本脚本会：
rem          1) 体检：检查 hosts 里已 pin 的域名是否还能连通
rem          2) 选优：用 EDNS Client Subnet 从多个地区解析域名，拿到各地区
rem             会得到的 IP，再从本机实测延迟，挑最快的写回 hosts
rem        域名清单与 macOS 版一致（cloud / *-lobby / *-match / cos-dev / 官网）。
rem
rem  用法（双击运行也行，会自动请求管理员权限）：
rem      fix-nikke-hosts.bat                 体检 + 优化（默认含游戏网关）
rem      fix-nikke-hosts.bat --dry-run       只预览，不改 hosts
rem      fix-nikke-hosts.bat --cdn-only      只动下载 CDN，网关只体检不写入
rem
rem  说明：hosts 改动会影响能否登录游戏，写入后请进游戏确认。
rem        脚本会先备份 hosts 到同目录的 hosts.bak-nikke-<时间戳>。
rem ============================================================================
setlocal
chcp 65001 >nul 2>&1

rem ---- 需要管理员权限：没有就自我提权重启 ----
net session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -ArgumentList '%*'"
    exit /b
)

rem ---- 把本文件里 #PS_BEGIN 之后的 PowerShell 代码抽出来执行 ----
set "PSFILE=%TEMP%\nikke-hosts-%RANDOM%%RANDOM%.ps1"
set "PSLINE="
for /f "delims=:" %%L in ('findstr /n "^#PS_BEGIN$" "%~f0"') do set "PSLINE=%%L"
if not defined PSLINE (
    echo [ERROR] Marker #PS_BEGIN not found in this file.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$c = Get-Content -LiteralPath '%~f0' -Encoding UTF8; $i = [int]'%PSLINE%'; $c[$i..($c.Length - 1)] | Set-Content -LiteralPath '%PSFILE%' -Encoding UTF8"
if not exist "%PSFILE%" (
    echo [ERROR] Failed to extract the PowerShell payload.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PSFILE%" %*
set "RC=%ERRORLEVEL%"
del "%PSFILE%" >nul 2>&1

echo.
echo Press any key to close this window...
pause >nul
exit /b %RC%

#PS_BEGIN
# ============================================================================
#  NIKKE hosts 加速器 —— PowerShell 实现（与 macOS 版 fix-nikke-hosts.sh 对齐）
#  兼容 Windows PowerShell 5.1（不依赖 PowerShell 7 的 -Parallel）
#
#  延迟指标：优先用 ICMP 真实 RTT；不回 ICMP 的节点退回 TLS 握手耗时。
#  不用 TCP 连接耗时排序 —— 本机若有代理/游戏加速器（国内很常见），
#  TCP 连接会在本地就被应答，耗时全变成十几毫秒，排序完全失真。
#  注意 TLS 值在大批量并发下会受排队影响而偏大，仅作兜底参考。
# ============================================================================

$ErrorActionPreference = 'Stop'
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
    # 默认每个 ServicePoint 只允许 2 个并发连接，会把并发 DoH 排成队列
    [Net.ServicePointManager]::DefaultConnectionLimit = 32
} catch { }

# ----------------------------------------------------------------- 参数解析
$DryRun  = $false
$CdnOnly = $false
foreach ($a in $args) {
    switch -Regex ([string]$a) {
        '^(--dry-run|-DryRun|-WhatIf)$' { $DryRun  = $true; continue }
        '^(--cdn-only|-CdnOnly)$'       { $CdnOnly = $true; continue }
        '^(-h|--help|-\?)$' {
            Write-Host '用法: fix-nikke-hosts.bat [--dry-run] [--cdn-only]'
            Write-Host '  --dry-run   只体检与测速，不修改 hosts'
            Write-Host '  --cdn-only  只优化下载 CDN，游戏网关只体检不写入'
            exit 0
        }
        default { Write-Host "未知参数: $a"; exit 2 }
    }
}

$HostsPath = if ($env:NIKKE_HOSTS_PATH) { $env:NIKKE_HOSTS_PATH }
             else { Join-Path $env:SystemRoot 'System32\drivers\etc\hosts' }
$Marker = '#UHE_'

# 域名清单：cdn = 可换节点（下载 CDN）；gateway = 游戏网关；plain = 只体检
$Domains = @(
    [pscustomobject]@{ Name = 'cloud.nikke-kr.com';        Kind = 'cdn'     }
    [pscustomobject]@{ Name = 'global-lobby.nikke-kr.com'; Kind = 'gateway' }
    [pscustomobject]@{ Name = 'global-match.nikke-kr.com'; Kind = 'gateway' }
    [pscustomobject]@{ Name = 'jp-lobby.nikke-kr.com';     Kind = 'gateway' }
    [pscustomobject]@{ Name = 'jp-match.nikke-kr.com';     Kind = 'gateway' }
    [pscustomobject]@{ Name = 'kr-lobby.nikke-kr.com';     Kind = 'gateway' }
    [pscustomobject]@{ Name = 'kr-match.nikke-kr.com';     Kind = 'gateway' }
    [pscustomobject]@{ Name = 'sea-lobby.nikke-kr.com';    Kind = 'gateway' }
    [pscustomobject]@{ Name = 'sea-match.nikke-kr.com';    Kind = 'gateway' }
    [pscustomobject]@{ Name = 'hmt-lobby.nikke-kr.com';    Kind = 'gateway' }
    [pscustomobject]@{ Name = 'hmt-match.nikke-kr.com';    Kind = 'gateway' }
    [pscustomobject]@{ Name = 'cos-dev.nikke-kr.com';      Kind = 'plain'   }
    [pscustomobject]@{ Name = 'nikke-kr.com';              Kind = 'plain'   }
)

# 用于"模拟各地区解析"的网段（不必精确，能代表该地区即可）
$Regions = @(
    [pscustomobject]@{ Subnet = '210.140.0.0/24'; Name = '日本'     }
    [pscustomobject]@{ Subnet = '168.126.63.0/24'; Name = '韩国'     }
    [pscustomobject]@{ Subnet = '203.116.0.0/24'; Name = '新加坡'   }
    [pscustomobject]@{ Subnet = '202.64.0.0/24';  Name = '香港'     }
    [pscustomobject]@{ Subnet = '168.95.0.0/24';  Name = '台湾'     }
    [pscustomobject]@{ Subnet = '203.113.0.0/24'; Name = '越南'     }
    [pscustomobject]@{ Subnet = '171.100.0.0/24'; Name = '泰国'     }
    [pscustomobject]@{ Subnet = '8.8.8.0/24';     Name = '美国西部' }
    [pscustomobject]@{ Subnet = '4.2.2.0/24';     Name = '美国东部' }
    [pscustomobject]@{ Subnet = '80.128.0.0/24';  Name = '德国'     }
    [pscustomobject]@{ Subnet = '1.128.0.0/24';   Name = '澳洲'     }
    [pscustomobject]@{ Subnet = '49.32.0.0/24';   Name = '印度'     }
)

$TimeoutMs = 2500   # 单个候选的 TCP 连接超时
$DohWaitMs = 8000   # 单个 DoH 查询的等待上限

# ------------------------------------------------------------------- 工具函数
function Read-HostsLines {
    if (Test-Path -LiteralPath $HostsPath) {
        return ,@([System.IO.File]::ReadAllLines($HostsPath, [System.Text.Encoding]::UTF8))
    }
    return ,@()
}

# 写入 hosts：UTF-8 不带 BOM（hosts 文件带 BOM 可能被部分解析器误读）
function Write-HostsLines {
    param([object[]]$Lines)
    $text = ($Lines -join "`r`n") + "`r`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $item = Get-Item -LiteralPath $HostsPath -Force
    $wasReadOnly = $item.IsReadOnly
    if ($wasReadOnly) { $item.IsReadOnly = $false }
    [System.IO.File]::WriteAllText($HostsPath, $text, $utf8NoBom)
    if ($wasReadOnly) { (Get-Item -LiteralPath $HostsPath -Force).IsReadOnly = $true }
}

function Get-CurrentPin {
    param([string]$Domain, [string[]]$Lines)
    foreach ($line in $Lines) {
        $body = ($line -split '#')[0]
        $cols = $body -split '\s+' | Where-Object { $_ -ne '' }
        if ($cols.Count -ge 2) {
            for ($i = 1; $i -lt $cols.Count; $i++) {
                if ($cols[$i] -eq $Domain) { return $cols[0] }
            }
        }
    }
    return $null
}

# 并发 DoH：一次把所有查询发出去，再统一收结果
function Resolve-AllDoh {
    param([object[]]$Queries, [int]$Batch = 24)
    $results = New-Object System.Collections.ArrayList
    # 分批发送：一次性并发 100+ 条 HTTPS 会大量失败（实测 168 条只剩几条成功）
    for ($offset = 0; $offset -lt $Queries.Count; $offset += $Batch) {
        $last = [Math]::Min($offset + $Batch - 1, $Queries.Count - 1)
        $chunk = @($Queries[$offset..$last])
        $pending = New-Object System.Collections.ArrayList
        foreach ($q in $chunk) {
            $url = "https://dns.google/resolve?name=$($q.Domain)&type=A&edns_client_subnet=$($q.Subnet)"
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('accept', 'application/dns-json')
            try {
                [void]$pending.Add([pscustomobject]@{
                    Query = $q
                    Wc    = $wc
                    Task  = $wc.DownloadStringTaskAsync($url)
                })
            } catch { }
        }
        foreach ($p in $pending) {
            try {
                if ($p.Task.Wait($DohWaitMs)) {
                    $json = $p.Task.Result | ConvertFrom-Json
                    foreach ($ans in $json.Answer) {
                        if ($ans.type -eq 1) {
                            $ip = [string]$ans.data
                            if ($ip -eq '0.0.0.1' -or $ip -eq '127.0.0.1') { continue }
                            [void]$results.Add([pscustomobject]@{
                                Domain = $p.Query.Domain
                                Region = $p.Query.Region
                                Ip     = $ip
                            })
                        }
                    }
                }
            } catch { }
            try { $p.Wc.Dispose() } catch { }
        }
    }
    return $results
}

# 并发 ICMP：真实 RTT，不受本机代理/加速器影响
function Measure-IcmpParallel {
    param([object[]]$Targets, [int]$Timeout = 1500)
    $items = New-Object System.Collections.ArrayList
    foreach ($t in $Targets) {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $task = $null
        try { $task = $ping.SendPingAsync($t.Ip, $Timeout) } catch { $task = $null }
        [void]$items.Add([pscustomobject]@{ Target = $t; Ping = $ping; Task = $task; Ms = -1 })
    }
    foreach ($it in $items) {
        if ($null -ne $it.Task) {
            try {
                if ($it.Task.Wait($Timeout + 1500)) {
                    $reply = $it.Task.Result
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $it.Ms = [int]$reply.RoundtripTime
                    }
                }
            } catch { }
        }
        try { $it.Ping.Dispose() } catch { }
    }
    return $items
}

# 并发 TCP 连接测速：先把所有连接都发起，再逐个收取完成时间（只用于判断可达）
function Measure-TcpParallel {
    param([object[]]$Targets)
    $items = New-Object System.Collections.ArrayList
    foreach ($t in $Targets) {
        $client = New-Object System.Net.Sockets.TcpClient
        try { $client.NoDelay = $true } catch { }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $iar = $null
        try { $iar = $client.BeginConnect($t.Ip, 443, $null, $null) } catch { $iar = $null }
        [void]$items.Add([pscustomobject]@{
            Target = $t; Client = $client; Sw = $sw; Iar = $iar; Ok = $false; Ms = -1
        })
    }
    foreach ($it in $items) {
        if ($null -ne $it.Iar) {
            try {
                if ($it.Iar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
                    $it.Client.EndConnect($it.Iar)
                    $it.Ok = $true
                }
            } catch { $it.Ok = $false }
        }
        $it.Sw.Stop()
        $it.Ms = [int]$it.Sw.ElapsedMilliseconds
    }
    return $items
}

# 并发 ICMP：真实 RTT，不受本机代理/加速器影响
function Measure-IcmpParallel {
    param([object[]]$Targets, [int]$Timeout = 1500)
    $items = New-Object System.Collections.ArrayList
    foreach ($t in $Targets) {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $task = $null
        try { $task = $ping.SendPingAsync($t.Ip, $Timeout) } catch { $task = $null }
        [void]$items.Add([pscustomobject]@{ Target = $t; Ping = $ping; Task = $task; Ms = -1 })
    }
    foreach ($it in $items) {
        if ($null -ne $it.Task) {
            try {
                if ($it.Task.Wait($Timeout + 1500)) {
                    $reply = $it.Task.Result
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $it.Ms = [int]$reply.RoundtripTime
                    }
                }
            } catch { }
        }
        try { $it.Ping.Dispose() } catch { }
    }
    return $items
}

# 并发 TLS 握手：既做证书校验（确认该 IP 真为这个域名服务），
# 又拿到一个真实往返时间。
# ★ 为什么不用 TCP 连接时间做排序：本机若有代理/游戏加速器（国内很常见），
#   TCP 连接会在本地就被应答，耗时全部变成十几毫秒，排序完全失真。
#   TLS 握手必须真正抵达源站，且 TLS1.3 只需 1 个 RTT，与 ICMP 可比。
function Measure-TlsParallel {
    param([object[]]$TcpItems, [int]$Timeout = 4000)
    $items = New-Object System.Collections.ArrayList
    foreach ($it in $TcpItems) {
        $rec = [pscustomobject]@{
            Target = $it.Target; Ssl = $null; Async = $null; Sw = $null
            Ok = $false; Ms = -1; Err = ''
        }
        if ($it.Ok) {
            try {
                $rec.Ssl = New-Object System.Net.Security.SslStream($it.Client.GetStream(), $false)
                # 秒表必须在"发起握手"这一刻启动：所有握手几乎同时开始，
                # 各自完成的时间才可横向比较；放到后面等待时才启动会全部测成 0ms
                $rec.Sw = [System.Diagnostics.Stopwatch]::StartNew()
                $rec.Async = $rec.Ssl.BeginAuthenticateAsClient($rec.Target.Domain, $null, $null)
            } catch { $rec.Err = 'handshake-init' }
        }
        [void]$items.Add($rec)
    }
    foreach ($rec in $items) {
        if ($null -eq $rec.Async) { continue }
        try {
            if ($rec.Async.AsyncWaitHandle.WaitOne($Timeout)) {
                $rec.Ssl.EndAuthenticateAsClient($rec.Async)
                $rec.Ok = $rec.Ssl.IsAuthenticated
            } else {
                $rec.Err = 'timeout'
            }
        } catch { $rec.Err = 'cert-or-tls' }
        $rec.Sw.Stop()
        $rec.Ms = [int]$rec.Sw.ElapsedMilliseconds
        try { $rec.Ssl.Dispose() } catch { }
    }
    foreach ($it in $TcpItems) { try { $it.Client.Close() } catch { } }
    return $items
}

# ----------------------------------------------------------------------- 主流程
$started = Get-Date
Write-Host '=========================================================='
Write-Host ' NIKKE hosts 体检 + 优化（Windows）'
if ($DryRun)  { Write-Host ' 模式：--dry-run（不会修改 hosts）' }
if ($CdnOnly) { Write-Host ' 范围：仅 CDN 类（--cdn-only）' } else { Write-Host ' 范围：CDN 类 + 网关类' }
Write-Host '=========================================================='
Write-Host ''
Write-Host "hosts 文件: $HostsPath"
Write-Host ''

$hostsLines = Read-HostsLines

Write-Host '[1/3] 并发解析各地区的候选 IP ...'
$queries = New-Object System.Collections.ArrayList
foreach ($d in $Domains) {
    foreach ($r in $Regions) {
        [void]$queries.Add([pscustomobject]@{ Domain = $d.Name; Subnet = $r.Subnet; Region = $r.Name })
    }
}
$ecs = Resolve-AllDoh -Queries $queries
Write-Host ("      完成：{0} 条候选记录" -f $ecs.Count)

Write-Host '[2/3] 并发实测连通性与延迟 ...'
$targets = New-Object System.Collections.ArrayList
foreach ($d in $Domains) {
    $pin = Get-CurrentPin -Domain $d.Name -Lines $hostsLines
    if ($pin) { [void]$targets.Add([pscustomobject]@{ Domain = $d.Name; Ip = $pin }) }
    foreach ($e in $ecs) {
        if ($e.Domain -eq $d.Name) {
            [void]$targets.Add([pscustomobject]@{ Domain = $d.Name; Ip = $e.Ip })
        }
    }
}
$targets = @($targets | Sort-Object Domain, Ip -Unique)
$tcp  = Measure-TcpParallel  -Targets $targets
$icmp = Measure-IcmpParallel -Targets $targets
$tls  = Measure-TlsParallel  -TcpItems $tcp

$icmpOf = @{ }
foreach ($m in $icmp) { $icmpOf["$($m.Target.Domain)|$($m.Target.Ip)"] = $m.Ms }
$latOf = @{ }
foreach ($m in $tls) {
    $key = "$($m.Target.Domain)|$($m.Target.Ip)"
    $im  = $icmpOf[$key]
    $useIcmp = ($null -ne $im -and $im -ge 0)
    $ms = $m.Ms
    if ($useIcmp) { $ms = $im }
    $latOf[$key] = [pscustomobject]@{
        Ok   = $m.Ok          # 证书校验通过才算可用
        Ms   = $ms
        Icmp = $useIcmp
        Err  = $m.Err
    }
}
Write-Host ("      完成：实测 {0} 个候选（证书校验通过 {1} 个）" -f `
            $tls.Count, (@($tls | Where-Object { $_.Ok }).Count))
Write-Host '[3/3] 汇总'
Write-Host ''

$wanted = [ordered]@{ }
foreach ($d in $Domains) {
    $domain = $d.Name
    Write-Host ("-- $domain  [{0}]" -f $d.Kind)

    $pin = Get-CurrentPin -Domain $domain -Lines $hostsLines
    if ($pin) {
        $m = $latOf["$domain|$pin"]
        if ($m -and $m.Ok) {
            } else {
            Write-Host ("   hosts 现值 : {0,-16} 不可达（过期了，需要换）" -f $pin)
        }
    } else {
        Write-Host '   hosts 现值 : （未 pin）'
    }

    if ($d.Kind -eq 'plain') { Write-Host ''; continue }

    $cands = @($ecs | Where-Object { $_.Domain -eq $domain } |
               Sort-Object Ip -Unique |
               Sort-Object { $x = $latOf["$domain|$($_.Ip)"]; if ($x -and $x.Ok) { $x.Ms } else { 999999 } })
    if ($cands.Count -eq 0) { Write-Host '   （没有候选，跳过）'; Write-Host ''; continue }

    Write-Host '   候选(ECS 各地区解析)与实测:'
    $ranked = @()
    foreach ($c in $cands) {
        $m = $latOf["$domain|$($c.Ip)"]
        if (-not $m) { continue }
        $mark = 'OK '; if (-not $m.Ok) { $mark = '-- ' }
        $src = 'TLS'; if ($m.Icmp) { $src = 'ICMP' }
        Write-Host ("     {0,-16} {1} {2,5} ms {3,-4} ({4})" -f $c.Ip, $mark, $m.Ms, $src, $c.Region)
        if ($m.Ok) { $ranked += [pscustomobject]@{ Ip = $c.Ip; Ms = $m.Ms } }
    }

    # $ranked 里只剩证书校验通过的候选，第一个就是最快且可用的
    $best = $null
    if ($ranked.Count -gt 0) { $best = $ranked[0].Ip }
    if ($best) { Write-Host ("   -> 选定: {0}" -f $best) }

    if ($best -and $best -ne $pin) {
        if ($d.Kind -eq 'cdn' -or -not $CdnOnly) {
            if ($DryRun) {
                Write-Host ("   [dry-run] 将写入: {0} {1}" -f $best, $domain)
            } else {
                $wanted[$domain] = $best
            }
        } else {
            Write-Host '   （网关类；如只想动 CDN 类请加 --cdn-only）'
        }
    } elseif ($best) {
        Write-Host '   （现值已是最快，无需改动）'
    }
    Write-Host ''
}

# ---------------------------------------------------------------------- 写入
if ($wanted.Count -gt 0) {
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "$HostsPath.bak-nikke-$stamp"
    try {
        Copy-Item -LiteralPath $HostsPath -Destination $backup -Force
        Write-Host "已备份: $backup"
    } catch {
        Write-Host "警告：备份失败（$($_.Exception.Message)），仍继续写入"
    }

    $out = New-Object System.Collections.ArrayList
    $done = New-Object System.Collections.ArrayList
    foreach ($line in $hostsLines) {
        $body = ($line -split '#')[0]
        $cols = $body -split '\s+' | Where-Object { $_ -ne '' }
        $hit = $null
        if ($cols.Count -ge 2) {
            foreach ($name in $wanted.Keys) {
                for ($i = 1; $i -lt $cols.Count; $i++) {
                    if ($cols[$i] -eq $name) { $hit = $name; break }
                }
                if ($hit) { break }
            }
        }
        if ($hit) {
            [void]$out.Add("$($wanted[$hit]) $hit $Marker")
            [void]$done.Add($hit)
        } else {
            [void]$out.Add($line)
        }
    }
    foreach ($name in $wanted.Keys) {
        if ($done -notcontains $name) { [void]$out.Add("$($wanted[$name]) $name $Marker") }
    }
    Write-HostsLines -Lines $out

    Write-Host ''
    Write-Host '--- 改动对比 ---'
    $before = @()
    if (Test-Path -LiteralPath $backup) {
        $before = [System.IO.File]::ReadAllLines($backup, [System.Text.Encoding]::UTF8)
    }
    Compare-Object -ReferenceObject $before -DifferenceObject $out |
        ForEach-Object {
            if ($_.SideIndicator -eq '=>') { Write-Host ("  + {0}" -f $_.InputObject) }
            else { Write-Host ("  - {0}" -f $_.InputObject) }
        }
    Write-Host ''
    try { ipconfig /flushdns | Out-Null } catch { }
    Write-Host ("已更新 {0} 个域名，DNS 缓存已刷新。重启游戏生效。" -f $wanted.Count)
} else {
    Write-Host '结论：无需写入任何改动。'
}

Write-Host ''
Write-Host ("耗时 {0:N1} 秒" -f ((Get-Date) - $started).TotalSeconds)
