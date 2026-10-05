param(
    [ValidateSet('Install','Uninstall','Check')][string]$Action = 'Install',
    [string]$GamePath,
    [string]$ArchivePath,
    [switch]$NonInteractive
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:PackageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:GameRoot = $null
$script:StateRoot = $null
$script:Manifest = $null
$script:InstallLock = $null
$script:ExtractRoot = $null
$script:Utf8 = New-Object Text.UTF8Encoding($false)

function Say([string]$Message) { Write-Host $Message }
function Hash([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}
function Prop($Object, [string]$Name, $Default = $null) {
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}
function Assert-NoReparse([string]$Path) {
    $part = [IO.Path]::GetFullPath($Path)
    while ($part) {
        if (Test-Path -LiteralPath $part) {
            if ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "为防止写入其他目录，拒绝符号链接或目录联接：$part"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($part.TrimEnd('\'))
        if (!$parent -or $parent -eq $part) { break }
        $part = $parent
    }
}
function Safe-Path([string]$Root, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or
        $Relative.Contains(':') -or $Relative.Contains([char]0) -or $Relative -match '[<>"|?*]') {
        throw "不安全的相对路径：$Relative"
    }
    foreach ($part in ($Relative -split '[/\\]')) {
        if (!$part -or $part -eq '.' -or $part -eq '..' -or $part.EndsWith(' ') -or $part.EndsWith('.')) {
            throw "不安全的路径片段：$Relative"
        }
        if ($part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw "无效文件名：$Relative" }
    }
    $full = [IO.Path]::GetFullPath((Join-Path $Root $Relative.Replace('/', '\')))
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (!$full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "路径超出允许目录：$Relative" }
    Assert-NoReparse $full
    return $full
}
function Assert-GameRelative([string]$Path) {
    if ($Path -notmatch '^(game|renpy)/' -or $Path -match '(?i)(^|/)(saves?|persistent)(/|$)' -or $Path -match '(?i)\.(exe|dll)$') {
        throw "补丁不允许改写此文件：$Path"
    }
    [void](Safe-Path $script:GameRoot $Path)
}
function Ensure-Directory([string]$Path) {
    Assert-NoReparse $Path
    if (Test-Path -LiteralPath $Path) {
        if (!(Test-Path -LiteralPath $Path -PathType Container)) { throw "路径不是目录：$Path" }
    } else { [void][IO.Directory]::CreateDirectory($Path) }
}
function Copy-Safe([string]$From, [string]$To) {
    Assert-NoReparse $From
    Assert-NoReparse $To
    Ensure-Directory ([IO.Path]::GetDirectoryName($To))
    Copy-Item -LiteralPath $From -Destination $To -Force
}
function Remove-ExactFile([string]$Path) {
    Assert-NoReparse $Path
    if (Test-Path -LiteralPath $Path) {
        if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "预期为文件，拒绝删除目录：$Path" }
        Remove-Item -LiteralPath $Path -Force
    }
}
function Write-JsonAtomic($Object, [string]$Path) {
    Assert-NoReparse $Path
    Ensure-Directory ([IO.Path]::GetDirectoryName($Path))
    $tmp = $Path + '.tmp'
    Assert-NoReparse $tmp
    [IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Depth 15), $script:Utf8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Read-Json([string]$Path) {
    Assert-NoReparse $Path
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function File-Matches([string]$Path, $Entry) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    Assert-NoReparse $Path
    if ((Get-Item -LiteralPath $Path).Length -ne [long]$Entry.bytes) { return $false }
    return ((Hash $Path) -eq [string]$Entry.sha256)
}
function Validate-FileList($List, [string]$Kind) {
    if ($null -eq $List) { return }
    $seen = @{}
    foreach ($file in @($List)) {
        if (!$file.path -or $file.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [long]$file.bytes -lt 0) { throw "清单 $Kind 格式无效。" }
        $key = [string]$file.path
        if ($key.Contains('\')) { throw "清单必须使用 / 分隔路径：$key" }
        if ($seen.ContainsKey($key)) { throw "清单含重复路径：$key" }
        $seen[$key] = $true
        if ($Kind -eq 'baseline_files' -or $Kind -eq 'payload_files') { Assert-GameRelative $key }
        elseif ($Kind -eq 'tool_files') {
            if ($key -notmatch '^tools/') { throw "工具文件路径无效：$key" }
            [void](Safe-Path $script:PackageRoot $key)
        } else { [void](Safe-Path $script:GameRoot $key) }
    }
}
function Find-Game {
    $roots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in @('HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam')) {
        if (Test-Path -LiteralPath $key) {
            $reg = Get-ItemProperty -LiteralPath $key
            foreach ($name in @('SteamPath','InstallPath')) {
                $p = Prop $reg $name
                if ($p -and !$roots.Contains([string]$p)) { $roots.Add([string]$p) }
            }
        }
    }
    foreach ($root in @($roots.ToArray())) {
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf -PathType Leaf) {
            $content = Get-Content -LiteralPath $vdf -Raw -Encoding UTF8
            foreach ($m in [regex]::Matches($content, '"(?:path|\d+)"\s+"([A-Za-z]:[^"\r\n]*)"')) {
                $path = $m.Groups[1].Value.Replace('\\','\')
                if (!$roots.Contains($path)) { $roots.Add($path) }
            }
        }
    }
    $found = @()
    foreach ($root in $roots) {
        $p = Join-Path $root 'steamapps\common\Being a DIK\Being a DIK Seasons 1 and 2'
        if (Test-Path -LiteralPath (Join-Path $p 'BeingADIK.exe') -PathType Leaf) { $found += $p }
    }
    $found = @($found | Select-Object -Unique)
    if ($found.Count -eq 1) { return $found[0] }
    if ($NonInteractive) { throw '无法唯一定位游戏。请通过 -GamePath 指定含 BeingADIK.exe 的游戏目录。' }
    if ($found.Count -gt 1) {
        for ($i=0; $i -lt $found.Count; $i++) { Say ("[{0}] {1}" -f ($i+1), $found[$i]) }
        $choice = Read-Host '请输入目录序号，或直接粘贴含 BeingADIK.exe 的目录路径'
        $number = 0
        if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $found.Count) { return $found[$number-1] }
        return $choice.Trim('"')
    }
    return (Read-Host '请粘贴含 BeingADIK.exe 的游戏目录路径（可拖入文件夹）').Trim('"')
}
function Assert-GameStopped {
    $p = @(Get-Process -Name 'BeingADIK','BeingADIK-32','BeingADIK-64' -ErrorAction SilentlyContinue)
    if ($p.Count -gt 0) { throw '请先退出 Being a DIK 游戏，再执行安装、检查或卸载。' }
    # Some RenPy distributions launch the engine as python.exe.
    try {
        $python = @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction Stop)
        foreach ($proc in $python) {
            if ($proc.ExecutablePath -and ([string]$proc.ExecutablePath).StartsWith($script:GameRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw '检测到游戏引擎仍在运行。请先退出游戏。'
            }
        }
    } catch {
        if ($_.Exception.Message -like '检测到*') { throw }
    }
}
function Assert-GameVersion {
    if (!(Test-Path -LiteralPath (Safe-Path $script:GameRoot 'BeingADIK.exe') -PathType Leaf)) { throw '目录中没有 BeingADIK.exe。' }
    $fail = @()
    foreach ($entry in @($script:Manifest.game_checks)) {
        if (!(File-Matches (Safe-Path $script:GameRoot $entry.path) $entry)) { $fail += $entry.path }
    }
    if ($fail.Count -gt 0) { throw ("游戏版本不匹配。本补丁仅适用于清单指定的 Steam 第一、二季 0.8.3。请核对第二季 DLC 和游戏版本；不匹配文件：`n" + ($fail -join "`n")) }
}
function Assert-Package {
    $script:Manifest = Read-Json (Join-Path $script:PackageRoot 'package.json')
    if (!(Prop $script:Manifest 'version') -or !$script:Manifest.game_checks -or !$script:Manifest.payload_files -or !$script:Manifest.baseline_files) { throw '补丁清单缺少必要信息。' }
    foreach ($kind in @('game_checks','baseline_files','payload_files','tool_files')) { Validate-FileList (Prop $script:Manifest $kind @()) $kind }
    $all = @{}
    foreach ($entry in @($script:Manifest.baseline_files) + @($script:Manifest.payload_files)) {
        if ($all.ContainsKey([string]$entry.path)) { throw "基础补丁与修订文件路径重叠：$($entry.path)" }
        $all[[string]$entry.path] = $true
    }
    $markers = @($script:Manifest.payload_files | Where-Object { $_.path -eq 'game/cn_polished/COMPLETE' })
    if ($markers.Count -ne 1) { throw '清单必须包含唯一的修订启用标记。' }
    foreach ($entry in @($script:Manifest.payload_files)) {
        if (!(File-Matches (Safe-Path (Join-Path $script:PackageRoot 'payload') $entry.path) $entry)) { throw "补丁包损坏，请重新下载：$($entry.path)" }
    }
    foreach ($entry in (Prop $script:Manifest 'tool_files' @())) {
        if (!(File-Matches (Safe-Path $script:PackageRoot $entry.path) $entry)) { throw "工具校验失败，请重新下载：$($entry.path)" }
    }
    if ($script:Manifest.upstream.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [long]$script:Manifest.upstream.bytes -lt 1 -or $script:Manifest.upstream.url -notmatch '^https://') { throw '上游下载清单无效。' }
}
function Acquire-Lock {
    Ensure-Directory $script:StateRoot
    $path = Safe-Path $script:StateRoot 'operation.lock'
    try { $script:InstallLock = [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw '无法取得操作锁。可能已有安装器正在运行，或游戏目录不可写；请关闭另一安装器并检查目录权限后重试。' }
}
function Assert-NoShadowSources {
    $listed = @{}
    foreach ($entry in @($script:Manifest.baseline_files) + @($script:Manifest.payload_files)) { $listed[[string]$entry.path] = $true }
    foreach ($entry in @($script:Manifest.baseline_files)) {
        if ($entry.path.EndsWith('.rpyc', [StringComparison]::OrdinalIgnoreCase)) {
            $source = $entry.path.Substring(0, $entry.path.Length - 1)
            if (!$listed.ContainsKey($source) -and (Test-Path -LiteralPath (Safe-Path $script:GameRoot $source))) {
                throw "检测到可能覆盖基础汉化的额外 Ren'Py 源码：$source。请先在游戏目录外备份并移走此旧 MOD 文件，再运行安装器。"
            }
        }
    }
}
function Cleanup-Extraction {
    if (!$script:ExtractRoot) { return }
    try {
        $extractParent = Safe-Path $script:StateRoot 'extract'
        $actual = [IO.Path]::GetFullPath($script:ExtractRoot)
        if ([IO.Path]::GetDirectoryName($actual) -ne $extractParent -or [IO.Path]::GetFileName($actual) -notmatch '^[0-9a-f]{32}$') { throw '临时目录边界校验失败。' }
        Assert-NoReparse $actual
        if (Test-Path -LiteralPath $actual -PathType Container) {
            foreach ($item in @(Get-ChildItem -LiteralPath $actual -Force -Recurse)) { Assert-NoReparse $item.FullName }
            Remove-Item -LiteralPath $actual -Recurse -Force
        }
    } catch { Say ("临时解压目录未能自动清理，可稍后手动删除：" + $script:ExtractRoot) }
}
function Validate-State($State) {
    if ((Prop $State 'format' 0) -ne 1 -or !(Prop $State 'entries') -or !([string]$State.game_root).Equals($script:GameRoot,[StringComparison]::OrdinalIgnoreCase)) { throw '安装记录不属于此游戏目录，或记录格式无效。' }
    $seen = @{}
    foreach ($entry in @($State.entries)) {
        Assert-GameRelative $entry.path
        if ($seen.ContainsKey([string]$entry.path)) { throw '安装记录含重复文件。' }
        $seen[[string]$entry.path] = $true
        if ($entry.existed) {
            if ($entry.before_sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $entry.backup -notmatch '^backups/[0-9a-f-]+/[0-9]+\.bin$') { throw '原文件备份记录无效。' }
            $backup = Safe-Path $script:StateRoot $entry.backup
            if (!(Test-Path -LiteralPath $backup -PathType Leaf) -or (Hash $backup) -ne $entry.before_sha256) { throw "原文件备份缺失或损坏，已停止操作：$($entry.path)" }
        }
        if (!$entry.generated -and $entry.after_sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw '安装后校验记录无效。' }
    }
}
function Preserve-Conflicts($State, [string]$Reason) {
    $conflicts = @()
    foreach ($entry in @($State.entries)) {
        $dest = Safe-Path $script:GameRoot $entry.path
        if (Test-Path -LiteralPath $dest) {
            if (!(Test-Path -LiteralPath $dest -PathType Leaf)) { throw "补丁文件被替换为目录，需先手动处理：$dest" }
            $current = Hash $dest
            # Generated bytecode is not in the package; preserve it before removal/restoration.
            if ($entry.generated -or ($current -ne $entry.after_sha256 -and (!$entry.existed -or $current -ne $entry.before_sha256))) {
                $conflicts += [pscustomobject]@{ path=$entry.path; sha256=$current }
            }
        }
    }
    if ($conflicts.Count) {
        $folder = 'conflicts/' + [Guid]::NewGuid().ToString('N')
        foreach ($item in $conflicts) {
            Copy-Safe (Safe-Path $script:GameRoot $item.path) (Safe-Path $script:StateRoot ($folder + '/' + $item.path))
        }
        Write-JsonAtomic ([ordered]@{reason=$Reason; files=$conflicts}) (Safe-Path $script:StateRoot ($folder + '/files.json'))
        Say ("已单独保留安装后变化的文件和生成的编译文件：" + (Safe-Path $script:StateRoot $folder))
    }
}
function Restore-State($State, [string]$Reason) {
    Validate-State $State
    Preserve-Conflicts $State $Reason
    # Disable the revision before touching any other files; restore the previous marker last.
    $ordered = @($State.entries | Where-Object { $_.path -ne 'game/cn_polished/COMPLETE' }) + @($State.entries | Where-Object { $_.path -eq 'game/cn_polished/COMPLETE' })
    Remove-ExactFile (Safe-Path $script:GameRoot 'game/cn_polished/COMPLETE')
    foreach ($entry in $ordered) {
        $dest = Safe-Path $script:GameRoot $entry.path
        if ($entry.existed) { Copy-Safe (Safe-Path $script:StateRoot $entry.backup) $dest }
        else { Remove-ExactFile $dest }
    }
    foreach ($entry in @($State.entries)) {
        $dest = Safe-Path $script:GameRoot $entry.path
        if ($entry.existed) {
            if ((Hash $dest) -ne $entry.before_sha256) { throw "恢复后的文件校验失败：$($entry.path)" }
        } elseif (Test-Path -LiteralPath $dest) { throw "新增文件未能移除：$($entry.path)" }
    }
}
function Recover-Interrupted {
    $pending = Safe-Path $script:StateRoot 'installing.json'
    if (Test-Path -LiteralPath $pending -PathType Leaf) {
        Say '检测到上次安装未完成，正在使用备份恢复安装前状态……'
        $state = Read-Json $pending
        Restore-State $state 'interrupted-install'
        Write-JsonAtomic $state (Safe-Path $script:StateRoot ('history/recovered-' + [Guid]::NewGuid().ToString('N') + '.json'))
        Remove-ExactFile (Safe-Path $script:StateRoot 'installed.json')
        Remove-ExactFile $pending
        Say '安装前状态已恢复。'
    }
}
function Get-BaselineRoot {
    $complete = $true
    foreach ($entry in @($script:Manifest.baseline_files)) {
        if (!(File-Matches (Safe-Path $script:GameRoot $entry.path) $entry)) { $complete = $false; break }
    }
    if ($complete) { Say '检测到完整的同版基础汉化，将直接安装润色与修复。'; return $script:GameRoot }
    $archive = $ArchivePath
    if (!$archive) {
        $cache = Safe-Path $script:PackageRoot 'cache/BAD_CN_0.09.rar'
        if (Test-Path -LiteralPath $cache -PathType Leaf) { $archive = $cache }
    }
    if (!$archive) {
        $archive = Safe-Path $script:StateRoot 'downloads/BAD_CN_0.09.rar'
        Ensure-Directory ([IO.Path]::GetDirectoryName($archive))
        $expect = [pscustomobject]@{sha256=$script:Manifest.upstream.sha256; bytes=$script:Manifest.upstream.bytes}
        if (!(File-Matches $archive $expect)) {
            Say '正在从原汉化项目的 GitHub 发布页下载基础补丁（约 274 MiB）……'
            $part = $archive + '.part'
            Assert-NoReparse $part
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                $client = New-Object Net.WebClient
                try { $client.DownloadFile([string]$script:Manifest.upstream.url, $part) } finally { $client.Dispose() }
                if (!(File-Matches $part $expect)) { throw '下载文件的大小或 SHA-256 不符。' }
                Move-Item -LiteralPath $part -Destination $archive -Force
            } catch {
                throw ("基础补丁下载失败：" + $_.Exception.Message + "`n请从原项目发布页手动下载：" + $script:Manifest.upstream.release_url + "`n然后执行：install.cmd -GamePath `"$script:GameRoot`" -ArchivePath `"下载的补丁.rar`"")
            }
        }
    }
    $archive = [IO.Path]::GetFullPath($archive)
    Assert-NoReparse $archive
    if (!(File-Matches $archive ([pscustomobject]@{sha256=$script:Manifest.upstream.sha256; bytes=$script:Manifest.upstream.bytes}))) { throw '基础补丁压缩包的大小或 SHA-256 不匹配。请使用 CN_Ver0.09 发布页的原始 RAR 文件。' }
    $unrar = Safe-Path $script:PackageRoot 'tools/UnRAR.exe'
    $toolEntry = @((Prop $script:Manifest 'tool_files' @()) | Where-Object { $_.path -eq 'tools/UnRAR.exe' })
    if ($toolEntry.Count -ne 1 -or !(File-Matches $unrar $toolEntry[0])) { throw '缺少经过校验的 UnRAR 工具。请重新解压完整补丁包。' }
    $work = Safe-Path $script:StateRoot ('extract/' + [Guid]::NewGuid().ToString('N'))
    $script:ExtractRoot = $work
    $outer = Safe-Path $work 'outer'
    $inner = Safe-Path $work 'inner'
    Ensure-Directory $outer
    Ensure-Directory $inner
    Say '正在解压并核对基础汉化文件……'
    & $unrar 'x' '-pvetoy' '-o+' '-y' '-idq' $archive ($outer + '\') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "外层 RAR 解压失败（退出码 $LASTEXITCODE）。" }
    $nested = @(Get-ChildItem -LiteralPath $outer -File -Recurse | Where-Object { $_.Extension -eq '.vetoy' })
    if ($nested.Count -ne 1) { throw '基础补丁压缩包结构与预期不符。' }
    Assert-NoReparse $nested[0].FullName
    & $unrar 'x' '-pvetoy' '-o+' '-y' '-idq' $nested[0].FullName ($inner + '\') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "内层 RAR 解压失败（退出码 $LASTEXITCODE）。" }
    foreach ($entry in @($script:Manifest.baseline_files)) {
        if (!(File-Matches (Safe-Path $inner $entry.path) $entry)) { throw "基础汉化解压文件校验失败：$($entry.path)" }
    }
    return $inner
}
function Install-Patch {
    Assert-GameVersion
    Recover-Interrupted
    Assert-NoShadowSources
    $statePath = Safe-Path $script:StateRoot 'installed.json'
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $existing = Read-Json $statePath
        Validate-State $existing
        if ([string]$existing.version -ne [string]$script:Manifest.version) { throw '检测到其他版本的社区补丁。请先用原补丁包卸载，再安装此版本。' }
        $changed = @()
        foreach ($entry in @($existing.entries)) {
            if (!$entry.generated) {
                $p = Safe-Path $script:GameRoot $entry.path
                if (!(Test-Path -LiteralPath $p -PathType Leaf) -or (Hash $p) -ne $entry.after_sha256) { $changed += $entry.path }
            }
        }
        if ($changed.Count) { throw ("已安装的文件后来发生变化。为保留这些修改，请先运行 uninstall.cmd，再重新安装。`n" + ($changed -join "`n")) }
        Say '此版本汉化已经完整安装，无需重复处理。'
        return
    }
    $baseline = Get-BaselineRoot
    $sources = @{}
    $files = @($script:Manifest.baseline_files) + @($script:Manifest.payload_files)
    foreach ($entry in @($script:Manifest.baseline_files)) { $sources[[string]$entry.path] = Safe-Path $baseline $entry.path }
    foreach ($entry in @($script:Manifest.payload_files)) { $sources[[string]$entry.path] = Safe-Path (Join-Path $script:PackageRoot 'payload') $entry.path }
    foreach ($entry in $files) { if (!(File-Matches $sources[[string]$entry.path] $entry)) { throw "源文件校验失败：$($entry.path)" } }
    Assert-GameStopped
    $transaction = [Guid]::NewGuid().ToString('N')
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $index = @{}
    foreach ($entry in $files) {
        $index[[string]$entry.path] = $true
        $entries.Add([pscustomobject][ordered]@{path=[string]$entry.path; existed=$false; before_sha256=$null; after_sha256=[string]$entry.sha256; backup=$null; generated=$false})
    }
    foreach ($entry in $files) {
        if ($entry.path.EndsWith('.rpy',[StringComparison]::OrdinalIgnoreCase)) {
            $compiled = $entry.path + 'c'
            if (!$index.ContainsKey($compiled)) {
                Assert-GameRelative $compiled
                $entries.Add([pscustomobject][ordered]@{path=$compiled; existed=$false; before_sha256=$null; after_sha256=$null; backup=$null; generated=$true})
                $index[$compiled] = $true
            }
        }
    }
    Say ("正在备份安装前文件，共核对 {0} 个路径……" -f $entries.Count)
    $i = 0
    foreach ($entry in $entries) {
        $dest = Safe-Path $script:GameRoot $entry.path
        if (Test-Path -LiteralPath $dest) {
            if (!(Test-Path -LiteralPath $dest -PathType Leaf)) { throw "目标被同名目录占用：$dest" }
            $entry.existed = $true
            $entry.before_sha256 = Hash $dest
            $entry.backup = 'backups/' + $transaction + '/' + $i.ToString('D5') + '.bin'
            $backup = Safe-Path $script:StateRoot $entry.backup
            Copy-Safe $dest $backup
            if ((Hash $backup) -ne $entry.before_sha256) { throw "备份校验失败：$($entry.path)" }
        }
        $i++
    }
    $state = [pscustomobject][ordered]@{format=1; version=[string]$script:Manifest.version; game_root=$script:GameRoot; installed_utc=[DateTime]::UtcNow.ToString('o'); transaction=$transaction; entries=$entries.ToArray()}
    $pending = Safe-Path $script:StateRoot 'installing.json'
    Write-JsonAtomic $state $pending
    try {
        # Existing bytecode for a patched source must not shadow the new source.
        Remove-ExactFile (Safe-Path $script:GameRoot 'game/cn_polished/COMPLETE')
        foreach ($entry in @($entries | Where-Object { $_.generated })) { Remove-ExactFile (Safe-Path $script:GameRoot $entry.path) }
        $ordered = @($files | Where-Object { $_.path -ne 'game/cn_polished/COMPLETE' })
        foreach ($entry in $ordered) {
            $dest = Safe-Path $script:GameRoot $entry.path
            if (!(File-Matches $dest $entry)) { Copy-Safe $sources[[string]$entry.path] $dest }
            if (!(File-Matches $dest $entry)) { throw "安装文件校验失败：$($entry.path)" }
        }
        Write-JsonAtomic $state $statePath
        $marker = @($files | Where-Object { $_.path -eq 'game/cn_polished/COMPLETE' })[0]
        Copy-Safe $sources[[string]$marker.path] (Safe-Path $script:GameRoot $marker.path)
        if (!(File-Matches (Safe-Path $script:GameRoot $marker.path) $marker)) { throw '启用标记写入失败。' }
        Remove-ExactFile $pending
    } catch {
        $failure = $_.Exception.Message
        Say '安装未完成，正在恢复安装前文件……'
        try {
            Restore-State $state 'failed-install'
            Remove-ExactFile $statePath
            Remove-ExactFile $pending
        } catch { throw ("安装失败：$failure`n自动恢复尚未完成：" + $_.Exception.Message + "`n请保留 .badik-cn-community 文件夹，排除文件占用后再次运行安装器。") }
        throw "安装失败，已恢复安装前状态：$failure"
    }
    Say '汉化安装完成。正常通过 Steam 启动游戏即可；不需要保持安装器开启。'
    Say '安装前文件保存在游戏目录的 .badik-cn-community 中，请保留此目录以便卸载恢复。'
}
function Uninstall-Patch {
    Recover-Interrupted
    $statePath = Safe-Path $script:StateRoot 'installed.json'
    if (!(Test-Path -LiteralPath $statePath -PathType Leaf)) { Say '没有发现本社区安装器的安装记录，无需卸载。'; return }
    $state = Read-Json $statePath
    Say '正在恢复运行本安装器之前的文件……'
    Restore-State $state 'uninstall'
    Write-JsonAtomic $state (Safe-Path $script:StateRoot ('history/uninstalled-' + [Guid]::NewGuid().ToString('N') + '.json'))
    Remove-ExactFile $statePath
    Say '卸载完成，已恢复安装前状态。玩家存档未被修改。备份与冲突副本仍保留在 .badik-cn-community 中。'
}
function Check-Patch {
    Assert-GameVersion
    Assert-NoShadowSources
    $pending = Safe-Path $script:StateRoot 'installing.json'
    if (Test-Path -LiteralPath $pending) { throw '检测到未完成的安装。请运行 install.cmd，安装器将先恢复安装前状态。' }
    $missing = @()
    foreach ($entry in @($script:Manifest.baseline_files) + @($script:Manifest.payload_files)) {
        if (!(File-Matches (Safe-Path $script:GameRoot $entry.path) $entry)) { $missing += $entry.path }
    }
    if ($missing.Count) { throw ("游戏版本检查通过，但汉化文件不完整或发生变化，共 {0} 项：`n{1}" -f $missing.Count, ($missing -join "`n")) }
    $statePath = Safe-Path $script:StateRoot 'installed.json'
    if (Test-Path -LiteralPath $statePath -PathType Leaf) { Validate-State (Read-Json $statePath) }
    Say '检查通过：游戏版本、基础汉化、中文润色文件和安装备份均正常。'
}

try {
    if (!$GamePath) { $GamePath = Find-Game }
    if ([string]::IsNullOrWhiteSpace($GamePath)) { throw '未提供游戏目录。' }
    $script:GameRoot = [IO.Path]::GetFullPath($GamePath.Trim('"')).TrimEnd('\')
    # Accept the Steam app directory as well as the directory containing the executable.
    if (!(Test-Path -LiteralPath (Join-Path $script:GameRoot 'BeingADIK.exe') -PathType Leaf)) {
        $child = Join-Path $script:GameRoot 'Being a DIK Seasons 1 and 2'
        if (Test-Path -LiteralPath (Join-Path $child 'BeingADIK.exe') -PathType Leaf) { $script:GameRoot = $child }
    }
    if (!(Test-Path -LiteralPath $script:GameRoot -PathType Container)) { throw '指定的游戏目录不存在。' }
    Assert-NoReparse $script:GameRoot
    if (!(Test-Path -LiteralPath (Safe-Path $script:GameRoot 'BeingADIK.exe') -PathType Leaf)) { throw '目录中没有 BeingADIK.exe，请选择正确的游戏目录。' }
    $script:StateRoot = Safe-Path $script:GameRoot '.badik-cn-community'
    Assert-GameStopped
    Assert-Package
    Acquire-Lock
    Say ("游戏目录：" + $script:GameRoot)
    switch ($Action) {
        'Install' { Install-Patch }
        'Uninstall' { Uninstall-Patch }
        'Check' { Check-Patch }
    }
    exit 0
} catch {
    Write-Host ("操作停止：" + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    Cleanup-Extraction
    if ($null -ne $script:InstallLock) { $script:InstallLock.Dispose() }
}
