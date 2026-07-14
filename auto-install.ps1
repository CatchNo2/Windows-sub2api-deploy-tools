<#
.SYNOPSIS
    Sub2API 自动化安装脚本
.DESCRIPTION
    在 Windows 10/11 上自动安装 Sub2API（WSL2 + Docker Desktop + Docker Compose 部署）。
    - 自动检测每一步是否已完成，支持断点续传（重启后再次运行即可继续）
    - 遇到必须手动操作的步骤会暂停，提示操作方法，等待完成后继续
    - 自动配置国内 Docker 镜像加速
    - 支持指定项目路径或自动查找项目
.NOTES
    需以管理员身份运行：右键 PowerShell → 以管理员身份运行
    用法：.\auto-install.ps1
    可选参数：.\auto-install.ps1 -ProjectPath "D:\Git\sub2api"
#>

param(
    # Sub2API 项目路径（留空则自动查找或使用脚本上级目录）
    [string]$ProjectPath = "",
    # Sub2API Web 端口（默认 8787 避免冲突）
    [string]$ServerPort = "8787",
    # 管理员密码（留空则自动生成，可在日志中查看）
    [string]$AdminPassword = "",
    # 是否安装 Codex CLI（可选，非 Sub2API 运行必需）
    [switch]$InstallCodex,
    # 重置安装状态，从头开始
    [switch]$Reset,
    # 跳过管理员权限检查（调试用）
    [switch]$SkipAdminCheck
)

# ============================================================
# 常量与全局变量
# ============================================================
$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateFile = Join-Path $ScriptDir ".install-state.json"
$WSLDistro = "Ubuntu"
$ScriptVersion = "2.1.0"

# ============================================================
# 项目路径自动检测
# ============================================================
# 递归查找包含 deploy/docker-compose.local.yml 的目录（不要求目录名为 sub2api）
function Find-DirectoriesWithDeploy {
    param(
        [string]$Root,
        [int]$MaxDepth = 4,
        [int]$CurrentDepth = 0
    )
    $results = @()
    if ($CurrentDepth -ge $MaxDepth) { return $results }
    try {
        $dirs = Get-ChildItem -Path $Root -Directory -ErrorAction Stop
    } catch {
        return $results
    }
    foreach ($d in $dirs) {
        try {
            if (Test-Path (Join-Path $d.FullName "deploy\docker-compose.local.yml")) {
                $results += $d.FullName
            }
        } catch {}
        $results += Find-DirectoriesWithDeploy -Root $d.FullName -MaxDepth $MaxDepth -CurrentDepth ($CurrentDepth + 1)
    }
    return $results
}

# 对候选目录排序：精确名为 sub2api 优先，其次包含 sub2api，最后其它
function Rank-Candidates {
    param([string[]]$Paths)
    $exact = @(); $contains = @(); $others = @()
    foreach ($p in $Paths) {
        $leaf = Split-Path $p -Leaf
        if ($leaf -eq "sub2api") { $exact += $p }
        elseif ($leaf -match "sub2api") { $contains += $p }
        else { $others += $p }
    }
    return ($exact + $contains + $others)
}

# 候选去重（保留顺序）
function Unique-Paths {
    param([string[]]$Paths)
    $seen = @{}; $out = @()
    foreach ($p in $Paths) {
        $norm = $p.TrimEnd('\').ToLower()
        if (-not $seen.ContainsKey($norm)) {
            $seen[$norm] = $true
            $out += $p
        }
    }
    return $out
}

# 尝试自动克隆 Sub2API 项目（找不到源码时的兜底方案）
function Try-AutoClone {
    param([string]$TargetDir)
    $parent = Split-Path $TargetDir -Parent
    if (-not (Test-Path $parent)) {
        try { New-Item -ItemType Directory -Path $parent -Force | Out-Null } catch { return $null }
    }
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
        Write-Warn "未检测到 git，无法自动克隆。请先安装 Git for Windows 或手动克隆项目。"
        return $null
    }
    Write-Info "正在自动克隆 Sub2API 项目到: $TargetDir"
    try {
        & git clone "https://github.com/Wei-Shaw/sub2api.git" $TargetDir 2>&1 | ForEach-Object { Write-Host $_ }
    } catch {
        Write-Warn "自动克隆失败：$_"
        return $null
    }
    if (Test-Path "$TargetDir\deploy\docker-compose.local.yml") {
        Write-Ok "已自动克隆 Sub2API 项目。"
        return $TargetDir
    }
    return $null
}

function Find-ProjectPath {
    # 1. 指定路径
    if (-not [string]::IsNullOrEmpty($ProjectPath)) {
        $resolved = Resolve-Path $ProjectPath -ErrorAction SilentlyContinue
        if ($resolved) {
            $p = $resolved.Path
            # 指定目录本身就是项目
            if (Test-Path "$p\deploy\docker-compose.local.yml") { return $p }
            # 否则在其内部递归查找
            $inner = Rank-Candidates (Find-DirectoriesWithDeploy -Root $p -MaxDepth 4)
            if ($inner.Count -gt 0) { return $inner[0] }
        }
        Write-Err "指定的项目路径无效或缺少 deploy 目录: $ProjectPath"
        return $null
    }

    $candidates = @()

    # 2. 脚本上级目录（适用于 installer 子目录）
    $parentDir = Split-Path -Parent $ScriptDir
    if (Test-Path "$parentDir\deploy\docker-compose.local.yml") {
        $candidates += $parentDir
    }

    # 3. 脚本所在目录（适用于直接放在项目根目录）
    if (Test-Path "$ScriptDir\deploy\docker-compose.local.yml") {
        $candidates += $ScriptDir
    }

    # 4. 常见位置（快速命中精确名 sub2api）
    $quickPaths = @(
        "$env:USERPROFILE\Git\sub2api",
        "$env:USERPROFILE\Desktop\sub2api",
        "$env:USERPROFILE\Documents\sub2api",
        "C:\Git\sub2api",
        "D:\Git\sub2api",
        "E:\Git\sub2api"
    )
    foreach ($path in $quickPaths) {
        if (Test-Path "$path\deploy\docker-compose.local.yml") {
            $candidates += $path
        }
    }

    # 5. 递归搜索常见代码根目录（不再要求目录名为 sub2api）
    $searchRoots = @(
        "$env:USERPROFILE\Git",
        "$env:USERPROFILE\Desktop",
        "$env:USERPROFILE\Documents",
        "$env:USERPROFILE\source",
        "$env:USERPROFILE\projects",
        "C:\Git", "D:\Git", "E:\Git", "F:\Git"
    )
    foreach ($root in $searchRoots) {
        if (Test-Path $root) {
            $candidates += Find-DirectoriesWithDeploy -Root $root -MaxDepth 3
        }
    }

    # 6. 顶层驱动器扫描（仅匹配名称含 sub2api 的目录，开销极小）
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Root } | Select-Object -ExpandProperty Root)) {
        try {
            Get-ChildItem -Path $drive -Directory -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -match "sub2api" -and (Test-Path (Join-Path $_.FullName "deploy\docker-compose.local.yml"))
            } | ForEach-Object { $candidates += $_.FullName }
        } catch {}
    }

    $candidates = Unique-Paths $candidates
    $candidates = Rank-Candidates $candidates

    if ($candidates.Count -eq 0) {
        # 找不到：先尝试自动克隆，再给出手动指引
        Write-Warn "未能自动找到 Sub2API 项目目录。"
        $defaultTarget = "$env:USERPROFILE\Git\sub2api"
        $cloneChoice = Read-Host "是否现在自动克隆 Sub2API 项目到 $defaultTarget ？(Y/n)"
        if ($cloneChoice -notmatch "^[nN]") {
            $cloned = Try-AutoClone -TargetDir $defaultTarget
            if ($cloned) { return $cloned }
        }
        return $null
    }

    if ($candidates.Count -eq 1) {
        Write-Info "自动找到项目路径: $($candidates[0])"
        return $candidates[0]
    }

    # 多个候选：让用户选择
    Write-Manual "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Manual "  发现多个可能的 Sub2API 项目目录，请选择："
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Manual "    [$($i+1)] $($candidates[$i])"
    }
    Write-Manual "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    $choice = Read-Host "请输入序号（直接回车默认选第 1 个）"
    if ([string]::IsNullOrWhiteSpace($choice)) {
        $idx = 0
    } elseif ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $candidates.Count) {
        $idx = [int]$choice - 1
    } else {
        Write-Warn "输入无效，默认选第 1 个。"
        $idx = 0
    }
    return $candidates[$idx]
}

# 查找项目路径（已增强：递归搜索 + 多候选选择 + 自动克隆兜底）
$ProjectDir = Find-ProjectPath
if ([string]::IsNullOrEmpty($ProjectDir)) {
    Write-Err "无法找到 Sub2API 项目目录！"
    Write-Manual "本工具只负责安装运行环境 + 部署，需要你先准备好 Sub2API 项目源码（含 deploy 目录）。"
    Write-Manual ""
    Write-Manual "最快的解决方式："
    Write-Manual ""
    Write-Manual "  方式 A：让脚本自动克隆（重新运行并在提示时输入 Y）"
    Write-Manual "    .\auto-install.ps1"
    Write-Manual ""
    Write-Manual "  方式 B：手动克隆后再运行（推荐，更可控）"
    Write-Manual "    git clone https://github.com/Wei-Shaw/sub2api.git $env:USERPROFILE\Git\sub2api"
    Write-Manual "    .\auto-install.ps1"
    Write-Manual ""
    Write-Manual "  方式 C：克隆到任意位置后，用 -ProjectPath 手动指定"
    Write-Manual "    git clone https://github.com/Wei-Shaw/sub2api.git D:\我的代码\sub2api"
    Write-Manual "    .\auto-install.ps1 -ProjectPath 'D:\我的代码\sub2api'"
    Write-Manual ""
    Write-Manual "  方式 D：直接把本脚本放进 sub2api 项目根目录运行"
    exit 1
}

# 验证项目目录结构
$requiredFiles = @(
    "$ProjectDir\deploy\docker-compose.local.yml",
    "$ProjectDir\deploy\.env.example"
)
foreach ($file in $requiredFiles) {
    if (-not (Test-Path $file)) {
        Write-Err "项目目录缺少必要文件: $file"
        Write-Manual "请确认项目完整克隆，包含 deploy 目录。"
        exit 1
    }
}

# 将 Windows 项目路径转换为 WSL 路径
$drive = $ProjectDir.Substring(0, 1).ToLower()
$relPath = $ProjectDir.Substring(2) -replace '\\', '/'
$WslProjectDir = "/mnt/$drive$relPath"

# ============================================================
# 工具函数：输出
# ============================================================
function Write-Info  { param([string]$Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "[OK]    $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }
function Write-Step  { param([string]$Msg) Write-Host "`n========== $Msg ==========" -ForegroundColor Magenta }
function Write-Manual { param([string]$Msg) Write-Host $Msg -ForegroundColor Yellow }

# ============================================================
# 工具函数：等待用户确认
# ============================================================
function Wait-UserContinue {
    param([string]$Prompt = "完成后按回车键继续...")
    Write-Host ""
    Write-Host -NoNewline $Prompt -ForegroundColor Yellow
    Read-Host
}

# ============================================================
# 工具函数：清理 WSL 输出中的 \r
# ============================================================
function Clean-WSLOutput {
    param($RawOutput)
    if ($null -eq $RawOutput) { return "" }
    $lines = @($RawOutput | ForEach-Object { ($_ -replace "`0", "" -replace "`r", "").Trim() } | Where-Object { $_ -ne "" })
    return ($lines -join "`n")
}

function Clean-WSLOutputLines {
    param($RawOutput)
    if ($null -eq $RawOutput) { return @() }
    return @($RawOutput | ForEach-Object { ($_ -replace "`0", "" -replace "`r", "").Trim() } | Where-Object { $_ -ne "" })
}

# ============================================================
# 工具函数：网络检查
# ============================================================
function Test-NetworkConnection {
    param([string]$Url = "https://github.com", [int]$TimeoutSeconds = 10)
    try {
        $request = [System.Net.WebRequest]::Create($Url)
        $request.Timeout = $TimeoutSeconds * 1000
        $request.Method = "HEAD"
        $response = $request.GetResponse()
        $response.Close()
        return $true
    } catch {
        return $false
    }
}

function Test-GitHubConnection {
    return Test-NetworkConnection -Url "https://github.com" -TimeoutSeconds 15
}

# ============================================================
# 工具函数：状态管理
# ============================================================
function Load-State {
    if ($Reset -and (Test-Path $StateFile)) {
        Remove-Item $StateFile -Force
        Write-Info "已重置安装状态。"
    }
    if (Test-Path $StateFile) {
        try {
            $content = Get-Content $StateFile -Raw -Encoding UTF8
            $state = $content | ConvertFrom-Json
            # 版本不兼容时自动重置
            if ($state.script_version -ne $ScriptVersion) {
                Write-Info "脚本版本已更新 (v$($state.script_version) -> v$ScriptVersion)，重置状态。"
                Remove-Item $StateFile -Force
                return Load-State
            }
            return $state
        } catch {
            Write-Warn "状态文件损坏，将重新开始。"
            Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
        }
    }
    $newState = [PSCustomObject]@{
        script_version = $ScriptVersion
        steps  = [PSCustomObject]@{}
        config = [PSCustomObject]@{
            server_port = $ServerPort
        }
    }
    return $newState
}

function Save-State {
    param($State)
    $State | ConvertTo-Json -Depth 10 | Set-Content $StateFile -Encoding UTF8
}

function Test-StepDone {
    param($State, [string]$StepName)
    return ($State.steps.$StepName -eq $true)
}

function Set-StepDone {
    param($State, [string]$StepName)
    $State.steps | Add-Member -NotePropertyName $StepName -NotePropertyValue $true -Force
    Save-State $State
}

# ============================================================
# 工具函数：在 WSL 中执行命令
# ============================================================

# 执行单行 bash 命令，返回清理后的字符串
function Invoke-WSL {
    param([string]$Command, [switch]$NoErrorCheck)
    $raw = & wsl -d $WSLDistro bash -c $Command 2>&1
    $code = $LASTEXITCODE
    $output = Clean-WSLOutput $raw
    if (-not $NoErrorCheck -and $code -ne 0) {
        Write-Err "WSL 命令失败 (退出码 $code): $Command"
        if ($output) { Write-Host $output -ForegroundColor DarkGray }
    }
    return $output
}

# 执行多行 bash 脚本（通过临时文件，避免引号转义问题）
function Invoke-WSLScript {
    param([Parameter(Mandatory)][string]$Script, [switch]$NoErrorCheck)
    # 写入临时文件（UTF-8 无 BOM，LF 行尾）
    $tempFile = [System.IO.Path]::GetTempFileName()
    $scriptContent = $Script -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($tempFile, $scriptContent, [System.Text.UTF8Encoding]::new($false))
    # 转为 WSL 路径 (C:\Users\... -> /mnt/c/Users/...)
    $tf = $tempFile -replace '\\', '/'
    $d = $tf.Substring(0, 1).ToLower()
    $wslPath = "/mnt/$d" + $tf.Substring(2)
    # 执行
    $raw = & wsl -d $WSLDistro bash $wslPath 2>&1
    $code = $LASTEXITCODE
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    $output = Clean-WSLOutput $raw
    if (-not $NoErrorCheck -and $code -ne 0) {
        Write-Err "WSL 脚本失败 (退出码 $code)"
        if ($output) { Write-Host $output -ForegroundColor DarkGray }
    }
    return $output
}

# ============================================================
# 检测函数
# ============================================================

function Test-AdminPrivilege {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($current)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-WingetAvailable {
    try {
        $null = Get-Command winget -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Test-WSLAvailable {
    try {
        $raw = & wsl --status 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Get-WSLDistroList {
    try {
        $raw = & wsl --list --quiet 2>&1
        # wsl --list 输出为 UTF-16LE，需去除 null 字节
        $text = ($raw | ForEach-Object { $_ -replace "`0", "" }) -join "`n"
        return $text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    } catch {
        return @()
    }
}

function Test-UbuntuInstalled {
    $distros = Get-WSLDistroList
    foreach ($d in $distros) {
        if ($d -match "Ubuntu") { return $true }
    }
    return $false
}

function Test-UbuntuInitialized {
    # 检查 /home 下是否有非 root 用户的家目录（说明已完成初始化）
    try {
        $raw = & wsl -d $WSLDistro bash -c 'ls /home/ 2>/dev/null | grep -v "^$"' 2>&1
        $users = Clean-WSLOutput $raw
        return ($LASTEXITCODE -eq 0 -and $users -ne "")
    } catch {
        return $false
    }
}

function Test-DockerInstalled {
    # 检查 Docker Desktop 是否已安装
    $ddPath = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $ddPath) { return $true }
    try {
        $null = Get-Command docker -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Test-DockerRunning {
    try {
        $null = & docker version 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Test-DockerWSLIntegration {
    try {
        $null = & wsl -d $WSLDistro docker version 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# ============================================================
# 步骤 1：安装 WSL2
# ============================================================
function Step-InstallWSL {
    Write-Step "步骤 1/10：安装 WSL2"

    if (Test-WSLAvailable -and (Get-WSLDistroList).Count -gt 0) {
        Write-Ok "WSL2 已安装且存在发行版，跳过。"
        return $true
    }

    if (-not (Test-WSLAvailable)) {
        Write-Info "正在安装 WSL2（需要管理员权限）..."
        & wsl --install --no-launch 2>&1 | ForEach-Object { Write-Host $_ }

        if ($LASTEXITCODE -ne 0) {
            Write-Warn "wsl --install 返回非零退出码，可能需要手动安装。"
        }

        Write-Warn "WSL2 安装完成，需要重启电脑才能生效。"
        Write-Manual "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        Write-Manual "  请执行以下操作："
        Write-Manual "  1. 保存所有工作"
        Write-Manual "  2. 重启电脑"
        Write-Manual "  3. 重启后，再次以管理员身份打开 PowerShell"
        Write-Manual "  4. 重新运行此脚本："
        Write-Manual "     .\auto-install.ps1"
        Write-Manual "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        Wait-UserContinue "重启并重新运行脚本后，按回车继续..."
        # 重启后重新运行时，会再次检测
        if (Test-WSLAvailable -and (Get-WSLDistroList).Count -gt 0) {
            Write-Ok "WSL2 已就绪。"
            return $true
        }
        Write-Err "WSL2 仍未就绪，请手动安装后重试。"
        return $false
    }

    # WSL 已安装但没有发行版
    if (-not (Test-UbuntuInstalled)) {
        Write-Info "WSL 已安装但缺少 Ubuntu 发行版，正在安装..."
        & wsl --install -d $WSLDistro --no-launch 2>&1 | ForEach-Object { Write-Host $_ }
        if (Test-UbuntuInstalled) {
            Write-Ok "Ubuntu 发行版已安装。"
        } else {
            Write-Err "Ubuntu 发行版安装失败，请手动运行：wsl --install -d $WSLDistro"
            return $false
        }
    }

    Write-Ok "WSL2 已就绪。"
    return $true
}

# ============================================================
# 步骤 2：初始化 Ubuntu（手动） + 配置免密 sudo
# ============================================================
function Step-InitUbuntu {
    Write-Step "步骤 2/10：初始化 Ubuntu"

    if (Test-UbuntuInitialized) {
        $user = Clean-WSLOutput (& wsl -d $WSLDistro bash -c 'whoami' 2>&1)
        Write-Ok "Ubuntu 已初始化（用户: $user），跳过。"
        return $true
    }

    Write-Manual "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Manual "  Ubuntu 需要首次初始化，请执行以下操作："
    Write-Manual ""
    Write-Manual "  方式一（推荐）：在此 PowerShell 中直接运行："
    Write-Manual "     wsl -d $WSLDistro"
    Write-Manual ""
    Write-Manual "  方式二：在 Windows 开始菜单搜索 'Ubuntu' 并打开"
    Write-Manual ""
    Write-Manual "  初始化步骤："
    Write-Manual "  1. 等待首次启动（可能需要 1-2 分钟）"
    Write-Manual "  2. 当提示 'Enter new UNIX username:' 时，输入: admin"
    Write-Manual "  3. 当提示输入密码时，输入你想要的密码（如 123456）"
    Write-Manual "  4. 确认密码"
    Write-Manual "  5. 看到 admin@... 提示符说明初始化成功"
    Write-Manual "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Wait-UserContinue "Ubuntu 初始化完成后，按回车继续..."

    if (Test-UbuntuInitialized) {
        Write-Ok "Ubuntu 初始化成功。"
        return $true
    }

    Write-Err "Ubuntu 仍未初始化，请确认操作已完成。"
    return $false
}

# ============================================================
# 步骤 3：验证 WSL2 + 配置免密 sudo
# ============================================================
function Step-VerifyWSL {
    Write-Step "步骤 3/10：验证 WSL2"

    $raw = & wsl --list --verbose 2>&1
    $text = Clean-WSLOutput $raw
    Write-Host $text

    # 检查 Ubuntu 是否为 WSL2（Running/Stopped 都是正常状态）
    if ($text -match "Ubuntu\s+\S+\s+2") {
        Write-Ok "WSL2 验证通过：Ubuntu 已是 WSL2 模式。"
    } elseif ($text -match "Ubuntu\s+\S+\s+1") {
        Write-Warn "Ubuntu 当前是 WSL1 模式，正在转换为 WSL2..."
        & wsl --set-version $WSLDistro 2 2>&1 | ForEach-Object { Write-Host $_ }
        & wsl --set-default-version 2 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            Write-Err "WSL2 转换失败。"
            return $false
        }
        Write-Ok "已转换为 WSL2。"
    } elseif ($text -match "Ubuntu") {
        # 有 Ubuntu 但无法判断版本，尝试设置默认版本
        Write-Info "正在确认 WSL2 配置..."
        & wsl --set-default-version 2 2>&1 | ForEach-Object { Write-Host $_ }
        Write-Ok "WSL2 配置完成。"
    } else {
        Write-Err "WSL2 验证失败：未找到 Ubuntu 发行版。"
        return $false
    }

    # 同时配置免密 sudo
    $sudoCheck = Invoke-WSL -NoErrorCheck 'sudo -n true 2>/dev/null && echo "NOPASSWD_OK" || echo "NEED_PASSWORD"'
    if ($sudoCheck -match "NOPASSWD_OK") {
        Write-Ok "免密 sudo 已配置。"
        return $true
    }

    # 自动配置免密 sudo
    $wslUser = Clean-WSLOutput (& wsl -d $WSLDistro bash -c 'whoami' 2>&1)
    Write-Info "当前 WSL 用户: $wslUser，正在自动配置免密 sudo..."

    # 先删除可能存在的损坏文件，再写入正确的配置
    # 使用 Invoke-WSLScript 避免引号转义问题
    $sudoScript = @"
#!/bin/bash
sudo rm -f /etc/sudoers.d/nopasswd
echo '$wslUser ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/nopasswd > /dev/null
sudo chmod 440 /etc/sudoers.d/nopasswd
echo 'SUDO_OK'
"@
    $sudoResult = Invoke-WSLScript $sudoScript -NoErrorCheck

    # 验证结果（忽略旧文件的语法错误 stderr 输出）
    $recheck = Invoke-WSL -NoErrorCheck 'sudo -n true 2>/dev/null && echo "NOPASSWD_OK" || echo "NEED_PASSWORD"'
    if ($recheck -match "NOPASSWD_OK") {
        Write-Ok "免密 sudo 自动配置成功。"
        return $true
    }

    # 自动配置失败，提示手动操作
    Write-Warn "免密 sudo 自动配置失败，需要手动配置。"
    Write-Manual "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Manual "  请打开 Ubuntu 终端（或运行 wsl -d $WSLDistro），依次执行："
    Write-Manual ""
    Write-Manual "    sudo rm -f /etc/sudoers.d/nopasswd"
    Write-Manual "    echo '$wslUser ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/nopasswd"
    Write-Manual "    sudo chmod 440 /etc/sudoers.d/nopasswd"
    Write-Manual ""
    Write-Manual "  输入密码后，sudo 将不再需要密码。"
    Write-Manual "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Wait-UserContinue "配置完成后，按回车继续..."

    $recheck2 = Invoke-WSL -NoErrorCheck 'sudo -n true 2>/dev/null && echo "NOPASSWD_OK" || echo "NEED_PASSWORD"'
    if ($recheck2 -match "NOPASSWD_OK") {
        Write-Ok "免密 sudo 配置成功。"
    } else {
        Write-Warn "免密 sudo 仍未配置，后续步骤可能需要手动执行。"
    }
    return $true
}

# ============================================================
# 步骤 4：安装 Docker Desktop（手动下载安装）
# ============================================================
function Step-InstallDocker {
    Write-Step "步骤 4/10：安装 Docker Desktop"

    if (Test-DockerInstalled) {
        Write-Ok "Docker Desktop 已安装，跳过。"
        return $true
    }

    Write-Manual "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Manual "  需要手动安装 Docker Desktop，请执行以下操作："
    Write-Manual ""
    Write-Manual "  1. 打开浏览器访问: https://www.docker.com/products/docker-desktop/"
    Write-Manual "  2. 下载 'Docker Desktop for Windows'（选择 AMD64 版本）"
    Write-Manual "  3. 双击下载的安装包 (Docker Desktop Installer.exe)"
    Write-Manual "  4. 安装时确保勾选 'Use WSL 2 instead of Hyper-V'"
    Write-Manual "  5. 安装完成后启动 Docker Desktop"
    Write-Manual "  6. 等待 Docker Desktop 完全启动（系统托盘图标变为绿色）"
    Write-Manual ""
    Write-Manual "  或者，可在此 PowerShell 中用 winget 安装："
    Write-Manual "     winget install -e --id Docker.DockerDesktop"
    Write-Manual "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    $choice = Read-Host "是否要用 winget 自动安装 Docker Desktop？(y/N)"
    if ($choice -match "^[yY]") {
        if (Test-WingetAvailable) {
            Write-Info "正在通过 winget 安装 Docker Desktop..."
            & winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements 2>&1 | ForEach-Object { Write-Host $_ }
            Write-Warn "如果安装成功，请启动 Docker Desktop 并等待其完全就绪。"
        } else {
            Write-Warn "winget 未安装，请先安装 App Installer 或手动安装 Docker Desktop。"
            Write-Manual "安装 winget: https://aka.ms/getwinget"
            Wait-UserContinue "手动安装并启动 Docker Desktop 后，按回车继续..."
        }
    } else {
        Wait-UserContinue "手动安装并启动 Docker Desktop 后，按回车继续..."
    }

    # 等待 Docker 就绪
    Write-Info "等待 Docker Desktop 启动..."
    $maxWait = 120
    $waited = 0
    while ($waited -lt $maxWait) {
        if (Test-DockerRunning) {
            Write-Ok "Docker Desktop 已运行。"
            return $true
        }
        Start-Sleep -Seconds 5
        $waited += 5
        Write-Host -NoNewline "."
    }
    Write-Host ""

    if (Test-DockerInstalled) {
        Write-Warn "Docker Desktop 已安装但未运行。请手动启动 Docker Desktop。"
        Wait-UserContinue "启动 Docker Desktop 后按回车继续..."
        if (Test-DockerRunning) {
            Write-Ok "Docker Desktop 已运行。"
            return $true
        }
    }

    Write-Err "Docker Desktop 未就绪。"
    return $false
}

# ============================================================
# 步骤 5：配置 Docker WSL 集成 + 国内镜像加速（手动）
# ============================================================
function Step-DockerWSLIntegration {
    Write-Step "步骤 5/10：配置 Docker Desktop"

    # 检查 WSL 集成
    $wslOk = Test-DockerWSLIntegration
    # 检查镜像加速
    $ddConfigPath = "$env:USERPROFILE\.docker\daemon.json"
    $hasMirror = $false
    if (Test-Path $ddConfigPath) {
        try {
            $cfg = Get-Content $ddConfigPath -Raw | ConvertFrom-Json
            if ($cfg.'registry-mirrors' -and $cfg.'registry-mirrors'.Count -gt 0) {
                $hasMirror = $true
            }
        } catch {}
    }

    if ($wslOk -and $hasMirror) {
        Write-Ok "Docker WSL 集成和镜像加速已配置，跳过。"
        return $true
    }

    if (-not $wslOk) {
        Write-Manual "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        Write-Manual "  需要在 Docker Desktop 中启用 Ubuntu 的 WSL 集成："
        Write-Manual ""
        Write-Manual "  1. 打开 Docker Desktop"
        Write-Manual "  2. 点击右上角齿轮图标进入 Settings"
        Write-Manual "  3. 导航到 Resources -> WSL Integration"
        Write-Manual "  4. 打开 'Enable integration with my default WSL distro'"
        Write-Manual "  5. 在下方开启 '$WSLDistro' 的开关"
        Write-Manual "  6. 点击 'Apply & Restart'"
        Write-Manual "  7. 等待 Docker Desktop 重启完成"
        Write-Manual "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        Wait-UserContinue "WSL 集成配置完成后，按回车继续..."

        if (-not (Test-DockerWSLIntegration)) {
            Write-Err "Docker WSL 集成仍未生效。请确认 Docker Desktop 设置中已启用 Ubuntu 集成。"
            return $false
        }
        Write-Ok "Docker WSL 集成验证通过。"
    }

    # 配置国内镜像加速（如果未配置）
    if (-not $hasMirror) {
        Write-Info "正在配置国内 Docker 镜像加速..."
        $daemonConfig = @{
            "builder" = @{
                "gc" = @{
                    "defaultKeepStorage" = "20GB"
                    "enabled" = $true
                }
            }
            "experimental" = $false
            "registry-mirrors" = @(
                "https://docker.xuanyuan.me"
                "https://docker.1ms.run"
                "https://docker.m.daocloud.io"
            )
        }
        $json = $daemonConfig | ConvertTo-Json -Depth 5
        $json | Set-Content $ddConfigPath -Encoding UTF8
        Write-Ok "镜像加速配置已写入: $ddConfigPath"
        Write-Warn "需要重启 Docker Desktop 才能生效。"

        # 尝试重启 Docker Desktop
        Write-Info "正在尝试重启 Docker Desktop..."
        $ddExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
        if (Test-Path $ddExe) {
            Get-Process "Docker Desktop" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            Start-Process $ddExe
            Write-Info "Docker Desktop 正在重启..."
            Start-Sleep -Seconds 15
        } else {
            Wait-UserContinue "请手动重启 Docker Desktop 后按回车继续..."
        }

        # 等待 Docker 恢复
        $maxWait = 60
        $waited = 0
        while ($waited -lt $maxWait) {
            if (Test-DockerWSLIntegration) {
                Write-Ok "Docker 重启完成，镜像加速已生效。"
                return $true
            }
            Start-Sleep -Seconds 5
            $waited += 5
            Write-Host -NoNewline "."
        }
        Write-Host ""
        Write-Warn "Docker 重启超时，请手动确认 Docker Desktop 正在运行。"
    }

    return $true
}

# ============================================================
# 步骤 6：Ubuntu 基础环境
# ============================================================
function Step-UbuntuBaseEnv {
    Write-Step "步骤 6/10：安装 Ubuntu 基础环境"

    # 检测是否已安装
    $check = Invoke-WSL -NoErrorCheck 'which openssl git curl >/dev/null 2>&1 && echo "INSTALLED" || echo "MISSING"'
    if ($check -eq "INSTALLED") {
        Write-Ok "基础环境已安装，跳过。"
        return $true
    }

    Write-Info "正在更新系统并安装基础工具（git, curl, openssl）..."
    $script = @'
#!/bin/bash
set -e
sudo apt-get update -y
sudo apt-get install -y git curl openssl ca-certificates
echo "APT_DONE"
'@
    $result = Invoke-WSLScript $script -NoErrorCheck
    Write-Host $result

    if (-not ($result -match "APT_DONE")) {
        Write-Err "基础环境安装失败。"
        Write-Manual "请手动在 Ubuntu 中运行: sudo apt update && sudo apt install -y git curl openssl"
        return $false
    }

    $recheck = Invoke-WSL -NoErrorCheck 'which openssl git curl >/dev/null 2>&1 && echo "INSTALLED" || echo "MISSING"'
    if ($recheck -eq "INSTALLED") {
        Write-Ok "基础环境安装完成。"
        return $true
    }

    Write-Err "基础环境安装失败。请手动在 Ubuntu 中运行: sudo apt update && sudo apt install -y git curl openssl"
    return $false
}

# ============================================================
# 步骤 7：安装 Node.js 和 Codex CLI（可选）
# ============================================================
function Step-InstallNodeAndCodex {
    Write-Step "步骤 7/10：安装 Node.js$(if ($InstallCodex) { ' 和 Codex CLI' } else { '（可选，已跳过）' })"

    if (-not $InstallCodex) {
        Write-Info "未指定 -InstallCodex 参数，跳过。如需安装请运行: .\auto-install.ps1 -InstallCodex"
        return $true
    }

    # 检测 Node.js
    $nodeCheck = Invoke-WSL -NoErrorCheck 'node -v 2>/dev/null || echo "NOT_INSTALLED"'
    if ($nodeCheck -match "NOT_INSTALLED") {
        Write-Info "正在安装 Node.js 20.x..."
        $script = @'
#!/bin/bash
set -e
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
'@
        $result = Invoke-WSLScript $script
        Write-Host $result
    } else {
        Write-Ok "Node.js 已安装: $nodeCheck"
    }

    # 安装 Codex CLI
    $codexCheck = Invoke-WSL -NoErrorCheck 'codex --version 2>/dev/null || echo "NOT_INSTALLED"'
    if ($codexCheck -match "NOT_INSTALLED") {
        Write-Info "正在安装 Codex CLI..."
        $result = Invoke-WSL 'sudo npm install -g @openai/codex'
        Write-Host $result
    } else {
        Write-Ok "Codex CLI 已安装: $codexCheck"
    }

    return $true
}

# ============================================================
# 步骤 8：部署准备（配置文件、密钥、.env）
# ============================================================
function Step-DeployPrepare {
    Write-Step "步骤 8/10：准备 Sub2API 部署配置"

    # 精确检测：文件是否真的存在
    $fileCheck = Invoke-WSL -NoErrorCheck 'test -f ~/sub2api-deploy/docker-compose.local.yml && test -f ~/sub2api-deploy/.env && echo "READY" || echo "NOT_READY"'
    if ($fileCheck -eq "READY") {
        Write-Ok "部署配置已存在，跳过。"
        return $true
    }

    Write-Info "正在准备部署目录和配置文件..."
    Write-Info "项目目录(Windows): $ProjectDir"
    Write-Info "项目目录(WSL):     $WslProjectDir"

    # 先验证源文件可访问
    $srcCheck = Invoke-WSL -NoErrorCheck "test -f '$WslProjectDir/deploy/docker-compose.local.yml' && echo 'SRC_OK' || echo 'SRC_MISSING'"
    if ($srcCheck -notmatch "SRC_OK") {
        Write-Err "无法访问项目部署文件: $WslProjectDir/deploy/"
        Write-Manual "请确认项目路径正确，且 WSL 可以访问 Windows 文件系统。"
        return $false
    }

    $deployScript = @"
#!/bin/bash
set -e

DEPLOY_DIR="`$HOME/sub2api-deploy"
SRC="$WslProjectDir/deploy"

# 创建部署目录
mkdir -p "`$DEPLOY_DIR"
cd "`$DEPLOY_DIR"

# 复制 docker-compose 配置
cp "`$SRC/docker-compose.local.yml" .
echo "COPIED_COMPOSE"

# 复制 .env.example 并生成 .env
cp "`$SRC/.env.example" .env.example
cp .env.example .env
echo "COPIED_ENV"

# 生成密钥
JWT_SECRET=`$(openssl rand -hex 32)
TOTP_KEY=`$(openssl rand -hex 32)
PG_PASS=`$(openssl rand -hex 32)

# 更新 .env 中的密钥（用 | 分隔避免路径冲突）
sed -i "s|^JWT_SECRET=.*|JWT_SECRET=`$JWT_SECRET|" .env
sed -i "s|^TOTP_ENCRYPTION_KEY=.*|TOTP_ENCRYPTION_KEY=`$TOTP_KEY|" .env
sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=`$PG_PASS|" .env
sed -i "s|^SERVER_PORT=.*|SERVER_PORT=$ServerPort|" .env

# 设置管理员密码（如果指定）
ADMIN_PW="$AdminPassword"
if [ -n "`$ADMIN_PW" ]; then
    sed -i "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=`$ADMIN_PW|" .env
fi

# 创建数据目录
mkdir -p data postgres_data redis_data

# 设置 .env 文件权限
chmod 600 .env

echo ""
echo "========== 部署配置已生成 =========="
echo "部署目录: `$DEPLOY_DIR"
echo "Web 端口: $ServerPort"
echo "POSTGRES_PASSWORD: `$PG_PASS"
echo "JWT_SECRET: `$JWT_SECRET"
echo "TOTP_ENCRYPTION_KEY: `$TOTP_KEY"
if [ -z "`$ADMIN_PW" ]; then
    echo "ADMIN_PASSWORD: (未设置，首次启动将自动生成)"
else
    echo "ADMIN_PASSWORD: (已设置)"
fi
echo "===================================="
echo "DEPLOY_DONE"
"@

    $result = Invoke-WSLScript $deployScript -NoErrorCheck
    Write-Host $result

    if (-not ($result -match "DEPLOY_DONE")) {
        Write-Err "部署配置准备失败。请查看上方错误信息。"
        return $false
    }

    # 最终验证文件确实存在
    $verify = Invoke-WSL -NoErrorCheck 'test -f ~/sub2api-deploy/docker-compose.local.yml && test -f ~/sub2api-deploy/.env && echo "VERIFIED" || echo "VERIFY_FAILED"'
    if ($verify -match "VERIFIED") {
        Write-Ok "部署配置已生成并验证。"
        return $true
    }

    Write-Err "部署配置文件验证失败。"
    return $false
}

# ============================================================
# 步骤 9：启动容器
# ============================================================
function Step-StartContainers {
    Write-Step "步骤 9/10：启动 Docker 容器"

    # 先验证 compose 文件存在
    $fileCheck = Invoke-WSL -NoErrorCheck 'test -f ~/sub2api-deploy/docker-compose.local.yml && echo "FILE_OK" || echo "FILE_MISSING"'
    if ($fileCheck -notmatch "FILE_OK") {
        Write-Err "docker-compose.local.yml 文件不存在，请重新运行脚本并使用 -Reset 参数。"
        return $false
    }

    # 检测容器是否已在运行
    $runningCheck = Invoke-WSL -NoErrorCheck 'docker ps --filter "name=sub2api" --format "{{.Names}}" 2>/dev/null | grep -c sub2api'
    if ($runningCheck -match "^[1-9]") {
        Write-Ok "Sub2API 容器已在运行，跳过。"
        return $true
    }

    Write-Info "正在拉取镜像并启动容器（首次可能需要几分钟，请耐心等待）..."
    $script = @'
#!/bin/bash
set -e
cd ~/sub2api-deploy
echo "Starting docker compose..."
docker compose -f docker-compose.local.yml up -d 2>&1
echo "COMPOSE_UP_DONE"
'@
    $result = Invoke-WSLScript $script -NoErrorCheck
    Write-Host $result

    if (-not ($result -match "COMPOSE_UP_DONE")) {
        Write-Err "docker compose up 失败。"
        # 尝试查看日志
        $logs = Invoke-WSL -NoErrorCheck 'cd ~/sub2api-deploy && docker compose -f docker-compose.local.yml logs --tail=20 2>&1'
        if ($logs) { Write-Host $logs }
        return $false
    }

    # 等待容器启动
    Write-Info "等待容器启动..."
    $maxWait = 120
    $waited = 0
    while ($waited -lt $maxWait) {
        $runCheck = Invoke-WSL -NoErrorCheck 'docker ps --filter "name=sub2api" --format "{{.Names}}" 2>/dev/null | grep -c sub2api'
        if ($runCheck -match "^[1-9]") {
            Write-Ok "Sub2API 容器已启动。"
            return $true
        }
        Start-Sleep -Seconds 5
        $waited += 5
        Write-Host -NoNewline "."
    }
    Write-Host ""

    # 最后一次检查
    $status = Invoke-WSL -NoErrorCheck 'cd ~/sub2api-deploy && docker compose -f docker-compose.local.yml ps 2>&1'
    Write-Host $status
    $logs = Invoke-WSL -NoErrorCheck 'cd ~/sub2api-deploy && docker compose -f docker-compose.local.yml logs --tail=30 2>&1'
    Write-Host $logs
    Write-Err "容器启动超时。请查看上方日志排查问题。"
    return $false
}

# ============================================================
# 步骤 10：验证并获取管理员密码
# ============================================================
function Step-VerifyAndGetPassword {
    Write-Step "步骤 10/10：验证服务并获取管理员密码"

    # 等待服务完全就绪
    Write-Info "等待 Sub2API 服务就绪..."
    $maxWait = 90
    $waited = 0
    $healthy = $false
    while ($waited -lt $maxWait) {
        $healthCheck = Invoke-WSL -NoErrorCheck 'docker exec sub2api wget -q -T 3 -O /dev/null http://localhost:8080/health 2>/dev/null && echo "HEALTHY" || echo "WAITING"'
        if ($healthCheck -match "HEALTHY") {
            $healthy = $true
            break
        }
        Start-Sleep -Seconds 5
        $waited += 5
        Write-Host -NoNewline "."
    }
    Write-Host ""

    if ($healthy) {
        Write-Ok "Sub2API 服务已就绪（健康检查通过）。"
    } else {
        Write-Warn "服务健康检查未通过（可能还在初始化数据库）。"
        # 显示容器日志帮助排查
        $logs = Invoke-WSL -NoErrorCheck 'cd ~/sub2api-deploy && docker compose -f docker-compose.local.yml logs --tail=20 sub2api 2>&1'
        if ($logs) {
            Write-Info "容器日志（最后 20 行）："
            Write-Host $logs -ForegroundColor DarkGray
        }
    }

    # 获取管理员密码
    if ([string]::IsNullOrEmpty($AdminPassword)) {
        Write-Info "正在从日志中获取自动生成的管理员密码..."
        Start-Sleep -Seconds 3
        $pwLogs = Invoke-WSL -NoErrorCheck 'cd ~/sub2api-deploy && docker compose -f docker-compose.local.yml logs sub2api 2>&1 | grep -i "admin password" | tail -5'
        if ($pwLogs) {
            Write-Host ""
            Write-Host "管理员密码信息：" -ForegroundColor Green
            Write-Host $pwLogs -ForegroundColor White
        } else {
            Write-Warn "未在日志中找到管理员密码，可能还在生成中。"
            Write-Info "稍后手动查看: wsl -d $WSLDistro bash -c 'cd ~/sub2api-deploy && docker compose -f docker-compose.local.yml logs sub2api | grep -i password'"
        }
    } else {
        Write-Ok "管理员密码已通过环境变量设置: $AdminPassword"
    }

    # 显示最终信息
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  Sub2API 安装完成！" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Web 管理后台:  http://localhost:$ServerPort" -ForegroundColor White
    Write-Host "  管理员邮箱:    admin@sub2api.local" -ForegroundColor White
    if (-not [string]::IsNullOrEmpty($AdminPassword)) {
        Write-Host "  管理员密码:    $AdminPassword" -ForegroundColor White
    } else {
        Write-Host "  管理员密码:    见上方日志输出（或稍后手动查看）" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "  常用命令（在 Ubuntu 中执行）：" -ForegroundColor Cyan
    Write-Host "    cd ~/sub2api-deploy"
    Write-Host "    docker compose -f docker-compose.local.yml ps             # 查看容器状态"
    Write-Host "    docker compose -f docker-compose.local.yml logs -f sub2api # 查看日志"
    Write-Host "    docker compose -f docker-compose.local.yml down           # 停止"
    Write-Host "    docker compose -f docker-compose.local.yml up -d          # 启动"
    Write-Host "    docker compose -f docker-compose.local.yml restart        # 重启"
    Write-Host ""
    Write-Host "  进入 Ubuntu:   wsl -d $WSLDistro" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Green

    # 尝试打开浏览器
    $openBrowser = Read-Host "`n是否打开浏览器访问 Web 管理后台？(Y/n)"
    if ($openBrowser -notmatch "^[nN]") {
        Start-Process "http://localhost:$ServerPort"
    }

    return $true
}

# ============================================================
# 主流程
# ============================================================
function Main {
    # 检测 Windows 版本
    $osInfo = [System.Environment]::OSVersion
    $osVersion = "Windows"
    try {
        $regKey = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop
        $osVersion = "Windows $($regKey.CurrentMajorVersionNumber).$($regKey.CurrentMinorVersionNumber) (Build $($regKey.CurrentBuildNumber))"
    } catch {}

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Magenta
    Write-Host "  Sub2API 自动化安装程序 v$ScriptVersion" -ForegroundColor Magenta
    Write-Host "  环境: $osVersion + WSL2 + Docker Desktop" -ForegroundColor Magenta
    Write-Host "============================================================" -ForegroundColor Magenta
    Write-Host ""
    Write-Info "项目目录(Windows): $ProjectDir"
    Write-Info "项目目录(WSL):     $WslProjectDir"
    Write-Info "Web 端口:          $ServerPort"
    if ($InstallCodex) { Write-Info "安装 Codex CLI:    是" }
    Write-Host ""

    # 检查网络连接
    Write-Info "检查网络连接..."
    if (-not (Test-GitHubConnection)) {
        Write-Warn "无法连接到 GitHub，某些功能可能受限。"
        Write-Manual "如果遇到网络问题，请配置代理或使用国内镜像。"
        Write-Host ""
    }

    # 检查管理员权限
    if (-not $SkipAdminCheck -and -not (Test-AdminPrivilege)) {
        Write-Err "此脚本需要管理员权限运行。"
        Write-Manual "请右键 PowerShell -> 以管理员身份运行，然后执行："
        Write-Manual "  .\auto-install.ps1"
        return
    }

    # 加载状态
    $state = Load-State
    Write-Info "状态文件: $StateFile"

    # 按步骤执行
    $steps = @(
        @{ Name = "wsl_install";          Function = "Step-InstallWSL" }
        @{ Name = "ubuntu_init";          Function = "Step-InitUbuntu" }
        @{ Name = "wsl_verify";           Function = "Step-VerifyWSL" }
        @{ Name = "docker_install";       Function = "Step-InstallDocker" }
        @{ Name = "docker_wsl_integration"; Function = "Step-DockerWSLIntegration" }
        @{ Name = "ubuntu_base";          Function = "Step-UbuntuBaseEnv" }
        @{ Name = "node_codex";           Function = "Step-InstallNodeAndCodex" }
        @{ Name = "deploy_prepare";       Function = "Step-DeployPrepare" }
        @{ Name = "deploy_start";         Function = "Step-StartContainers" }
        @{ Name = "deploy_verify";        Function = "Step-VerifyAndGetPassword" }
    )

    foreach ($step in $steps) {
        $stepName = $step.Name
        $funcName = $step.Function

        if (Test-StepDone $state $stepName) {
            Write-Info "[$stepName] 已完成，跳过。"
            continue
        }

        # 执行步骤
        $result = & $funcName

        if ($result) {
            Set-StepDone $state $stepName
            Write-Ok "[$stepName] 完成。"
        } else {
            Write-Err "[$stepName] 失败。请根据上方提示解决问题后重新运行脚本。"
            Write-Info "已完成的步骤不会重复执行（断点续传）。"
            Write-Info "如需重新开始，请运行: .\auto-install.ps1 -Reset"
            return
        }
    }

    Write-Host ""
    Write-Ok "所有步骤已完成！Sub2API 已成功安装并运行。"
}

# 运行主流程
Main
