#Requires -Version 5.1
<#
.SYNOPSIS
  Windows one-click installer for AUTOMATIC1111 Stable Diffusion WebUI,
  AnimateDiff (V2 motion module) and the Simplified Chinese localization.

.DESCRIPTION
  Creates a self-contained folder next to this script:
    _python310\              portable Python 3.10.11
    _downloads\              cached installers / wheels
    _cache\huggingface\      CLIP text-encoder cache (offline)
    stable-diffusion-webui\  the WebUI checkout

  The repository itself stays small; model weights and wheels are downloaded
  from mirrors on first run.

.PARAMETER InstallDir
  WebUI checkout directory. Default: .\stable-diffusion-webui

.PARAMETER PythonDir
  Portable Python directory. Default: .\_python310

.PARAMETER MotionModulePath
  Existing mm_sd_v15_v2.ckpt. If omitted the installer looks in the repo root,
  the WebUI models folder and the Desktop.

.PARAMETER CacheDir
  Cache directory for HuggingFace/Torch/Matplotlib. Default: .\_cache

.PARAMETER SkipModels
  Do not download the SD 1.5 checkpoint (useful when you already have it).

.PARAMETER SkipMotionModule
  Do not download the AnimateDiff motion module.

.PARAMETER SkipClipCache
  Do not pre-populate the CLIP cache (the first model load may then need HF).

.PARAMETER Cpu
  Install CPU PyTorch instead of CUDA 12.8 (slow, but works without NVIDIA).

.PARAMETER ForceZip
  Skip git clone and fetch WebUI/extensions as codeload ZIP archives. Useful on
  networks where github.com:443 is reset but codeload.github.com works.

.PARAMETER CheckOnly
  Print the resolved paths and exit without changing anything.
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$PythonDir,
    [string]$CacheDir,
    [string]$MotionModulePath,
    [string]$WebUiCommit = "1937682a",
    [switch]$SkipModels,
    [switch]$SkipMotionModule,
    [switch]$SkipClipCache,
    [switch]$Cpu,
    [switch]$ForceZip,
    [switch]$CheckOnly,
    [switch]$Launch,
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# ---------------------------------------------------------------------------
# Paths and constants
# ---------------------------------------------------------------------------
$Root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$Root = [IO.Path]::GetFullPath($Root)

if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = Join-Path $Root "stable-diffusion-webui" }
if ([string]::IsNullOrWhiteSpace($PythonDir))  { $PythonDir  = Join-Path $Root "_python310" }
if ([string]::IsNullOrWhiteSpace($CacheDir))   { $CacheDir   = Join-Path $Root "_cache" }

$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$PythonDir  = [IO.Path]::GetFullPath($PythonDir)
$CacheDir   = [IO.Path]::GetFullPath($CacheDir)

$Downloads = Join-Path $Root "_downloads"
$Python    = Join-Path $PythonDir "python.exe"
$StartBat  = Join-Path $Root "start_sd.bat"

$PipIndex = "https://pypi.tuna.tsinghua.edu.cn/simple"
$PipHost  = "pypi.tuna.tsinghua.edu.cn"

$TorchUrl    = "https://mirror.sjtu.edu.cn/pytorch-wheels/cu128/torch-2.7.0%2Bcu128-cp310-cp310-win_amd64.whl"
$TorchVisUrl = "https://mirror.sjtu.edu.cn/pytorch-wheels/cu128/torchvision-0.22.0%2Bcu128-cp310-cp310-win_amd64.whl"

$SdUrl   = "https://modelscope.cn/models/AI-ModelScope/stable-diffusion-v1-5/resolve/master/v1-5-pruned-emaonly.safetensors"
$ClipBase = "https://modelscope.cn/models/AI-ModelScope/clip-vit-large-patch14/resolve/master/"
$MmUrl   = "https://hf-mirror.com/guoyww/animatediff/resolve/main/mm_sd_v15_v2.ckpt"

# Full SHA for the pinned dev commit; codeload accepts full SHAs but not short ones.
$WebUiCommitFull = "1937682a20f7f0442311a1ede68f9f0cb480163b"
$WebUiZip = if ($WebUiCommit -eq "1937682a") {
    "https://codeload.github.com/AUTOMATIC1111/stable-diffusion-webui/zip/$WebUiCommitFull"
} elseif ($WebUiCommit) {
    "https://codeload.github.com/AUTOMATIC1111/stable-diffusion-webui/zip/$WebUiCommit"
} else {
    "https://codeload.github.com/AUTOMATIC1111/stable-diffusion-webui/zip/refs/heads/dev"
}
$AdZip = "https://codeload.github.com/continue-revolution/sd-webui-animatediff/zip/refs/heads/master"
$ZhZip = "https://codeload.github.com/dtlnor/stable-diffusion-webui-localization-zh_CN/zip/refs/heads/Anne"

$env:PIP_INDEX_URL = $PipIndex
$env:PIP_TRUSTED_HOST = $PipHost
$env:PIP_DISABLE_PIP_VERSION_CHECK = "1"
$env:PIP_NO_INPUT = "1"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}
function Write-Info([string]$Message) { Write-Host "    $Message" -ForegroundColor Gray }
function Write-Ok([string]$Message)   { Write-Host "    [OK] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "    [!] $Message" -ForegroundColor Yellow }
function Fail([string]$Message) {
    Write-Host ""
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    if (-not $NoPause) {
        Write-Host ""
        Write-Host "按回车键退出..." -ForegroundColor Yellow
        try { Read-Host | Out-Null } catch { }
    }
    exit 1
}

function Get-CurlPath {
    $c = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $fallback = Join-Path $env:SystemRoot "System32\curl.exe"
    if (Test-Path $fallback) { return $fallback }
    return $null
}
$script:Curl = Get-CurlPath

function Get-RemoteFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Path,
        [long]$MinBytes = 1
    )
    if ((Test-Path $Path) -and ((Get-Item $Path).Length -ge $MinBytes)) {
        Write-Info "已存在，跳过: $(Split-Path $Path -Leaf)"
        return
    }
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    Write-Info "下载: $Url"
    if ($script:Curl) {
        $curlArgs = @("--location", "--fail", "--retry", "4", "--retry-delay", "2",
                      "--connect-timeout", "30", "--output", $Path)
        if (Test-Path $Path) { $curlArgs += @("--continue-at", "-") }
        $curlArgs += $Url
        & $script:Curl @curlArgs
        if ($LASTEXITCODE -ne 0) {
            throw "下载失败 (curl exit $LASTEXITCODE): $Url"
        }
    } else {
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -TimeoutSec 600
    }
    if (-not (Test-Path $Path)) { throw "下载后文件不存在: $Path" }
    $size = (Get-Item $Path).Length
    if ($size -lt $MinBytes) { throw "下载文件过小 ($size bytes): $Url" }
    Write-Ok ("下载完成: {0:N1} MB" -f ($size / 1MB))
}

function Invoke-Pip {
    param([string[]]$Arguments, [string]$What = "pip")
    Write-Info "pip: $What"
    $all = @("-m", "pip") + $Arguments
    & $Python @all
    if ($LASTEXITCODE -ne 0) { throw "pip 失败 ($What), exit $LASTEXITCODE" }
}

function Invoke-PythonProbe {
    param([string]$Code)
    # PowerShell 5.1 turns native stderr into an ErrorRecord. With the global
    # ErrorActionPreference=Stop that would abort the installer the first time
    # torch is missing, so probe with Continue and merge stderr into the output.
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $Python -c $Code 2>&1
        $exit = $LASTEXITCODE
        return [pscustomobject]@{ ExitCode = $exit; Output = (($out | Out-String).Trim()) }
    } finally {
        $ErrorActionPreference = $old
    }
}

function Get-JsonLine {
    param([string]$Text)
    if (-not $Text) { return $null }
    return ($Text -split "`r?`n" | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
}

function Invoke-GitClone {
    param([string]$Url, [string]$Dest, [string[]]$Extra = @())
    $gitArgs = @("clone", "--depth", "1") + $Extra + @($Url, $Dest)
    & $script:Git @gitArgs
    if ($LASTEXITCODE -eq 0) { return }

    Write-Warn "git clone 失败，尝试清空代理后重试..."
    $saved = @{}
    foreach ($name in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy")) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
    try {
        if (Test-Path $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force -ErrorAction SilentlyContinue }
        & $script:Git -c http.proxy= -c https.proxy= @gitArgs
        if ($LASTEXITCODE -ne 0) { throw "git clone 失败: $Url" }
    } finally {
        foreach ($name in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name], "Process")
        }
    }
}

function Test-FileSize {
    param([string]$Path, [long]$Expected)
    if (-not (Test-Path $Path)) { return $false }
    return ((Get-Item $Path).Length -eq $Expected)
}

# Fallback for networks where github.com:443 is reset but codeload.github.com works.
# Downloads a branch/commit ZIP and copies its single top-level folder into $Dest.
function Get-GitHubZip {
    param([string]$Url, [string]$Dest)
    $leaf = ($Url -split '/')[-1]
    $zip = Join-Path $Downloads ("gh-" + $leaf + ".zip")
    Get-RemoteFile $Url $zip 10000
    $tmp = Join-Path $Downloads ("gh-extract-" + [guid]::NewGuid().ToString("N"))
    $expanded = $false
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            Expand-Archive -Path $zip -DestinationPath $tmp -Force -ErrorAction Stop
            $expanded = $true
            break
        } catch {
            if ($attempt -ge 2) { throw }
            Write-Warn "ZIP 解压失败，删除后重新下载: $Url"
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            Get-RemoteFile $Url $zip 10000
        }
    }
    if (-not $expanded) { throw "ZIP 解压失败: $Url" }
    $top = Get-ChildItem -LiteralPath $tmp -Directory -Force | Select-Object -First 1
    if (-not $top) { throw "ZIP 内容为空: $Url" }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Get-ChildItem -LiteralPath $top.FullName -Force | Copy-Item -Destination $Dest -Recurse -Force
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  Stable Diffusion WebUI - Windows 一键安装" -ForegroundColor White
Write-Host "  A1111 dev + AnimateDiff V2 + 简体中文 + PyTorch 2.7 CUDA 12.8" -ForegroundColor DarkGray
Write-Host ""

Write-Step "解析安装路径"
Write-Info "仓库目录 : $Root"
Write-Info "WebUI    : $InstallDir"
Write-Info "Python   : $PythonDir"
Write-Info "缓存     : $CacheDir"
if ($CheckOnly) {
    Write-Host ""
    Write-Ok "检查完成（未做任何修改）"
    exit 0
}

# ---------------------------------------------------------------------------
# 1. Environment checks
# ---------------------------------------------------------------------------
Write-Step "检查系统环境"
if (-not [Environment]::Is64BitOperatingSystem) { Fail "需要 64 位 Windows。" }
if ($PSVersionTable.PSVersion.Major -lt 5) { Fail "需要 PowerShell 5.1 或更高版本。" }

$drive = (Get-Item $Root).PSDrive
if ($drive -and $drive.Free -lt 20GB) {
    Write-Warn ("剩余空间只有 {0:N1} GB，建议至少 20 GB。" -f ($drive.Free / 1GB))
}

$gitCommand = Get-Command git -ErrorAction SilentlyContinue
if ($gitCommand) {
    $script:Git = $gitCommand.Source
} else {
    $candidates = @(
        (Join-Path $env:ProgramFiles "Git\cmd\git.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Git\cmd\git.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Git\cmd\git.exe")
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { $script:Git = $c; break }
    }
}
if (-not $script:Git) {
    Fail "未找到 Git。请先安装 Git for Windows: https://git-scm.com/download/win"
}
Write-Ok "Git: $script:Git"

$gpuName = $null
$driver = $null
if (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue) {
    try {
        $smi = & nvidia-smi.exe --query-gpu=name,driver_version --format=csv,noheader | Select-Object -First 1
        if ($smi) {
            $parts = $smi -split ","
            $gpuName = $parts[0].Trim()
            if ($parts.Count -gt 1) { $driver = $parts[1].Trim() }
        }
    } catch { }
}
if ($gpuName) {
    Write-Ok "GPU: $gpuName (驱动 $driver)"
    if (-not $Cpu -and $driver) {
        $major = 0
        [void][int]::TryParse(($driver -split "\.")[0], [ref]$major)
        if ($major -gt 0 -and $major -lt 570) {
            Write-Warn "CUDA 12.8 通常需要 570 以上驱动；当前 $driver，可能无法使用 GPU。"
        }
    }
} elseif (-not $Cpu) {
    Write-Warn "未检测到 nvidia-smi。若没有 NVIDIA 显卡，请加 -Cpu 参数。"
}

New-Item -ItemType Directory -Force -Path $Downloads | Out-Null

# ---------------------------------------------------------------------------
# 2. Portable Python 3.10
# ---------------------------------------------------------------------------
Write-Step "准备 Python 3.10.11"
if (Test-Path $Python) {
    $pyVer = & $Python -c "import sys; print('%d.%d' % sys.version_info[:2])"
    if ($LASTEXITCODE -ne 0 -or $pyVer -ne "3.10") {
        Fail "现有 Python 不是 3.10 ($pyVer)。请删除 $PythonDir 后重试。"
    }
    Write-Ok "已存在 Python $pyVer"
} else {
    $pyZip = Join-Path $Downloads "python-3.10.11-embed-amd64.zip"
    Get-RemoteFile "https://mirrors.huaweicloud.com/python/3.10.11/python-3.10.11-embed-amd64.zip" $pyZip 8000000
    New-Item -ItemType Directory -Force -Path $PythonDir | Out-Null
    Expand-Archive -Path $pyZip -DestinationPath $PythonDir -Force
    if (-not (Test-Path $Python)) { Fail "Python 解压失败。" }
    Write-Ok "Python 已解压: $PythonDir"
}

# Make the embeddable Python usable: site-packages + the WebUI directory on sys.path.
function Update-PythonPath {
    $sp = Join-Path $PythonDir "Lib\site-packages"
    New-Item -ItemType Directory -Force -Path $sp | Out-Null
    $pth = Join-Path $PythonDir "python310._pth"
    $lines = @("python310.zip", ".", "Lib\site-packages", "", "import site", $InstallDir)
    [IO.File]::WriteAllLines($pth, $lines, (New-Object System.Text.UTF8Encoding($false)))
}
Update-PythonPath

# ---------------------------------------------------------------------------
# 3. pip
# ---------------------------------------------------------------------------
Write-Step "准备 pip"
$sitePackages = Join-Path $PythonDir "Lib\site-packages"
if (Test-Path (Join-Path $sitePackages "pip\__init__.py")) {
    Write-Ok "pip 已存在"
} else {
    $pipWhl = Join-Path $Root "vendor\pip-24.2-py3-none-any.whl"
    if (-not (Test-Path $pipWhl)) {
        $pipWhl = Join-Path $Downloads "pip-24.2-py3-none-any.whl"
        Get-RemoteFile "https://pypi.tuna.tsinghua.edu.cn/packages/d4/55/90db48d85f7689ec6f81c0db0622d704306c5284850383c090e6c7195a5c/pip-24.2-py3-none-any.whl" $pipWhl 1500000
    }
    $pipZip = Join-Path $Downloads "pip-24.2.zip"
    Copy-Item -LiteralPath $pipWhl -Destination $pipZip -Force
    Expand-Archive -Path $pipZip -DestinationPath $sitePackages -Force
    Write-Ok "pip 已解压"
}
& $Python -m pip --version
if ($LASTEXITCODE -ne 0) { Fail "pip 无法运行。" }

# ---------------------------------------------------------------------------
# 4. WebUI checkout
# ---------------------------------------------------------------------------
Write-Step "获取 AUTOMATIC1111 WebUI (dev)"
$zipInstall = $false
if (Test-Path (Join-Path $InstallDir "launch.py")) {
    Write-Ok "WebUI 已存在"
} else {
    if ((Test-Path $InstallDir) -and (Get-ChildItem -Force $InstallDir | Select-Object -First 1)) {
        Fail "目录非空且不是 WebUI: $InstallDir"
    }
    if ($ForceZip) {
        Write-Info "-ForceZip：跳过 git clone，使用 codeload ZIP"
        if (Test-Path $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue }
        Get-GitHubZip $WebUiZip $InstallDir
        if (-not (Test-Path (Join-Path $InstallDir "launch.py"))) { Fail "ZIP 解压后找不到 launch.py: $InstallDir" }
        $zipInstall = $true
        Write-Ok "WebUI 已通过 ZIP 安装（固定提交 $WebUiCommit）"
    } else {
        try {
            Invoke-GitClone "https://github.com/AUTOMATIC1111/stable-diffusion-webui.git" $InstallDir @("--branch", "dev")
            Write-Ok "WebUI 已克隆"
        } catch {
            Write-Warn "git clone 失败，改用 GitHub ZIP 下载..."
            if (Test-Path $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue }
            Get-GitHubZip $WebUiZip $InstallDir
            if (-not (Test-Path (Join-Path $InstallDir "launch.py"))) { Fail "ZIP 解压后找不到 launch.py: $InstallDir" }
            $zipInstall = $true
            Write-Ok "WebUI 已通过 ZIP 安装（固定提交 $WebUiCommit）"
        }
    }
}
if (Test-Path (Join-Path $InstallDir ".git")) {
    & $script:Git -C $InstallDir config core.longpaths true
}

if ($WebUiCommit -and -not $zipInstall -and (Test-Path (Join-Path $InstallDir ".git"))) {
    Write-Info "尝试固定到测试过的提交 $WebUiCommit"
    $head = (& $script:Git -C $InstallDir rev-parse HEAD | Select-Object -First 1)
    if ($head -and $head.Trim().StartsWith($WebUiCommit)) {
        Write-Ok "WebUI 已是 $WebUiCommit"
    } else {
        $fetched = $false
        & $script:Git -C $InstallDir fetch --depth 1 origin $WebUiCommit
        if ($LASTEXITCODE -eq 0) {
            $fetched = $true
        } else {
            Write-Warn "git fetch 失败，清空代理后重试..."
            $saved = @{}
            foreach ($name in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy")) {
                $saved[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
                [Environment]::SetEnvironmentVariable($name, $null, "Process")
            }
            try {
                & $script:Git -c http.proxy= -c https.proxy= -C $InstallDir fetch --depth 1 origin $WebUiCommit
                if ($LASTEXITCODE -eq 0) { $fetched = $true }
            } finally {
                foreach ($name in $saved.Keys) {
                    [Environment]::SetEnvironmentVariable($name, $saved[$name], "Process")
                }
            }
        }
        if ($fetched) {
            & $script:Git -C $InstallDir checkout --detach $WebUiCommit
            if ($LASTEXITCODE -eq 0) { Write-Ok "已切换到 $WebUiCommit" }
            else { Write-Warn "无法切换提交，继续使用 dev 最新版。" }
        } else {
            Write-Warn "无法获取提交 $WebUiCommit，继续使用 dev 最新版。"
        }
    }
}

# The WebUI must be importable before launch.py runs.
Update-PythonPath

# ---------------------------------------------------------------------------
# 5. PyTorch
# ---------------------------------------------------------------------------
Write-Step "安装 PyTorch 2.7"
$probe = Invoke-PythonProbe "import json, torch; d={'v': torch.__version__, 'cuda': torch.cuda.is_available()}; print(json.dumps(d))"
$torchOk = $false
$torchInfo = $null
if ($probe.ExitCode -eq 0) {
    $json = Get-JsonLine $probe.Output
    if ($json) {
        try { $torchInfo = $json | ConvertFrom-Json } catch { }
    }
}
if ($torchInfo) {
    Write-Info "已安装 torch $($torchInfo.v) (CUDA: $($torchInfo.cuda))"
    if ($Cpu) {
        $torchOk = ($torchInfo.v -notmatch '\+cu')
    } else {
        $torchOk = ($torchInfo.v -match '^2\.7\.0\+cu128') -and $torchInfo.cuda
    }
}

if (-not $torchOk) {
    if ($Cpu) {
        Invoke-Pip @("install", "torch==2.7.0", "torchvision==0.22.0", "--no-cache-dir", "--progress-bar", "off") "CPU torch"
    } else {
        Invoke-Pip @("install", $TorchUrl, $TorchVisUrl, "--no-cache-dir", "--progress-bar", "off",
                     "--index-url", $PipIndex, "--trusted-host", $PipHost) "CUDA 12.8 torch"
    }
    $probe = Invoke-PythonProbe "import json, torch; d={'v': torch.__version__, 'cuda': torch.cuda.is_available()}; print(json.dumps(d))"
    if ($probe.ExitCode -ne 0) { Fail "torch 安装后无法导入。`n$($probe.Output)" }
    $json = Get-JsonLine $probe.Output
    if (-not $json) { Fail "torch 安装后无法读取版本信息。`n$($probe.Output)" }
    $torchInfo = $json | ConvertFrom-Json
    if (-not $Cpu -and -not $torchInfo.cuda) {
        Fail "torch 已安装，但 CUDA 不可用。请更新 NVIDIA 驱动到 570+，或使用 -Cpu。"
    }
    Write-Ok "torch $($torchInfo.v) 就绪 (CUDA: $($torchInfo.cuda))"
} else {
    Write-Ok "torch 已就绪"
}

# ---------------------------------------------------------------------------
# 6. Python dependencies
# ---------------------------------------------------------------------------
Write-Step "安装 WebUI 依赖"
Invoke-Pip @("install", "setuptools==69.5.1", "wheel==0.48.0", "--no-cache-dir") "setuptools / wheel"
$req = Join-Path $InstallDir "requirements_versions.txt"
if (-not (Test-Path $req)) { Fail "找不到 requirements_versions.txt" }
Invoke-Pip @("install", "-r", $req, "--no-build-isolation", "--prefer-binary", "--no-cache-dir") "requirements_versions.txt"

$clipZip = Join-Path $Root "vendor\clip-openai.zip"
if (-not (Test-Path $clipZip)) {
    $clipZip = Join-Path $Downloads "clip-openai.zip"
    Get-RemoteFile "https://github.com/openai/CLIP/archive/d50d76daa670286dd6cacf3bcd80b5e4823fc8e1.zip" $clipZip 3000000
}
Invoke-Pip @("install", "--no-build-isolation", $clipZip, "--no-cache-dir") "openai/CLIP"

# ---------------------------------------------------------------------------
# 7. Extensions
# ---------------------------------------------------------------------------
Write-Step "安装扩展"
$extRoot = Join-Path $InstallDir "extensions"
New-Item -ItemType Directory -Force -Path $extRoot | Out-Null

$adDir = Join-Path $extRoot "sd-webui-animatediff"
if (-not (Test-Path (Join-Path $adDir "scripts\animatediff.py"))) {
    if ($ForceZip) {
        Write-Info "-ForceZip：使用 codeload ZIP 安装 AnimateDiff"
        if (Test-Path $adDir) { Remove-Item -LiteralPath $adDir -Recurse -Force -ErrorAction SilentlyContinue }
        Get-GitHubZip $AdZip $adDir
        if (-not (Test-Path (Join-Path $adDir "scripts\animatediff.py"))) { Fail "AnimateDiff ZIP 解压失败: $adDir" }
        Write-Ok "AnimateDiff 扩展已通过 ZIP 安装"
    } else {
        try {
            Invoke-GitClone "https://github.com/continue-revolution/sd-webui-animatediff.git" $adDir @("--branch", "master")
            Write-Ok "AnimateDiff 扩展已安装"
        } catch {
            Write-Warn "git clone 失败，改用 GitHub ZIP 下载 AnimateDiff..."
            if (Test-Path $adDir) { Remove-Item -LiteralPath $adDir -Recurse -Force -ErrorAction SilentlyContinue }
            Get-GitHubZip $AdZip $adDir
            if (-not (Test-Path (Join-Path $adDir "scripts\animatediff.py"))) { Fail "AnimateDiff ZIP 解压失败: $adDir" }
            Write-Ok "AnimateDiff 扩展已通过 ZIP 安装"
        }
    }
} else {
    Write-Ok "AnimateDiff 扩展已存在"
}

$zhDir = Join-Path $extRoot "stable-diffusion-webui-localization-zh_CN"
if (-not (Test-Path (Join-Path $zhDir "localizations\zh_CN.json"))) {
    if ($ForceZip) {
        Write-Info "-ForceZip：使用 codeload ZIP 安装中文语言包"
        if (Test-Path $zhDir) { Remove-Item -LiteralPath $zhDir -Recurse -Force -ErrorAction SilentlyContinue }
        Get-GitHubZip $ZhZip $zhDir
        if (-not (Test-Path (Join-Path $zhDir "localizations\zh_CN.json"))) { Fail "中文语言包 ZIP 解压失败: $zhDir" }
        Write-Ok "中文语言包已通过 ZIP 安装"
    } else {
        try {
            Invoke-GitClone "https://github.com/dtlnor/stable-diffusion-webui-localization-zh_CN.git" $zhDir @("--branch", "Anne")
            Write-Ok "中文语言包已安装"
        } catch {
            Write-Warn "git clone 失败，改用 GitHub ZIP 下载中文语言包..."
            if (Test-Path $zhDir) { Remove-Item -LiteralPath $zhDir -Recurse -Force -ErrorAction SilentlyContinue }
            Get-GitHubZip $ZhZip $zhDir
            if (-not (Test-Path (Join-Path $zhDir "localizations\zh_CN.json"))) { Fail "中文语言包 ZIP 解压失败: $zhDir" }
            Write-Ok "中文语言包已通过 ZIP 安装"
        }
    }
} else {
    Write-Ok "中文语言包已存在"
}

Invoke-Pip @("install", "av==17.1.0", "imageio-ffmpeg==0.8.1", "--no-cache-dir") "AnimateDiff 视频依赖"

# ---------------------------------------------------------------------------
# 8. Models
# ---------------------------------------------------------------------------
$sdDir = Join-Path $InstallDir "models\Stable-diffusion"
$mmDir = Join-Path $adDir "model"
New-Item -ItemType Directory -Force -Path $sdDir, $mmDir | Out-Null

if (-not $SkipModels) {
    Write-Step "下载 SD 1.5 模型 (约 4.0 GB)"
    $sdFile = Join-Path $sdDir "v1-5-pruned-emaonly.safetensors"
    if (Test-FileSize $sdFile 4265146304) {
        Write-Ok "SD 1.5 已存在"
    } else {
        Get-RemoteFile $SdUrl $sdFile 4000000000
        if (-not (Test-FileSize $sdFile 4265146304)) {
            $actual = (Get-Item $sdFile).Length
            Fail "SD 1.5 大小不正确 ($actual / 4265146304)，请删除后重试: $sdFile"
        }
        Write-Ok "SD 1.5 下载完成"
    }
}

if (-not $SkipMotionModule) {
    Write-Step "安装 AnimateDiff 运动模块"
    $mmDest = Join-Path $mmDir "mm_sd_v15_v2.ckpt"
    if (Test-FileSize $mmDest 1817888431) {
        Write-Ok "运动模块已存在"
    } else {
        $candidates = @()
        if ($MotionModulePath) {
            if (Test-Path $MotionModulePath -PathType Container) {
                $candidates += (Join-Path $MotionModulePath "mm_sd_v15_v2.ckpt")
            } else {
                $candidates += $MotionModulePath
            }
        }
        $candidates += @(
            (Join-Path $Root "mm_sd_v15_v2.ckpt"),
            (Join-Path $InstallDir "mm_sd_v15_v2.ckpt"),
            (Join-Path $env:USERPROFILE "Desktop\mm_sd_v15_v2.ckpt")
        )
        $found = $null
        foreach ($c in $candidates) {
            if ($c -and (Test-Path $c -PathType Leaf)) { $found = $c; break }
        }
        if ($found) {
            Write-Info "从本地复制: $found"
            Copy-Item -LiteralPath $found -Destination $mmDest -Force
        } else {
            Write-Warn "未找到本地 mm_sd_v15_v2.ckpt，开始从 hf-mirror 下载 (约 1.7 GB，可能较慢)"
            Get-RemoteFile $MmUrl $mmDest 1800000000
        }
        if (-not (Test-FileSize $mmDest 1817888431)) {
            $actual = (Get-Item $mmDest).Length
            Fail "运动模块大小不正确 ($actual / 1817888431)。可手动放置到: $mmDest"
        }
        Write-Ok "运动模块就绪"
    }
}

# ---------------------------------------------------------------------------
# 9. CLIP cache
# ---------------------------------------------------------------------------
if (-not $SkipClipCache) {
    Write-Step "准备 CLIP 文本编码器缓存 (离线)"
    $snapHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    $hfRepo = Join-Path $CacheDir "huggingface\hub\models--openai--clip-vit-large-patch14"
    $snap = Join-Path $hfRepo "snapshots\$snapHash"
    New-Item -ItemType Directory -Force -Path $snap, (Join-Path $hfRepo "refs") | Out-Null

    $clipFiles = @(
        @{ Name = "config.json";             Min = 1000 },
        @{ Name = "tokenizer_config.json";   Min = 500 },
        @{ Name = "special_tokens_map.json"; Min = 200 },
        @{ Name = "vocab.json";              Min = 500000 },
        @{ Name = "merges.txt";              Min = 300000 },
        @{ Name = "tokenizer.json";          Min = 1000000 },
        @{ Name = "model.safetensors";       Min = 1600000000 }
    )
    foreach ($f in $clipFiles) {
        $dest = Join-Path $snap $f.Name
        if ((Test-Path $dest) -and ((Get-Item $dest).Length -ge $f.Min)) {
            Write-Info "已存在: $($f.Name)"
        } else {
            Get-RemoteFile ($ClipBase + $f.Name) $dest $f.Min
        }
    }
    [IO.File]::WriteAllText((Join-Path $hfRepo "refs\main"), $snapHash, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok "CLIP 缓存就绪"
}

# ---------------------------------------------------------------------------
# 10. config.json and launcher
# ---------------------------------------------------------------------------
Write-Step "写入配置"
$config = [ordered]@{
    "sd_model_checkpoint" = "v1-5-pruned-emaonly.safetensors [6ce0161689]"
    "localization" = "zh_CN"
    "animatediff_model_path" = $null
    "animatediff_default_save_formats" = @("GIF", "PNG")
    "animatediff_save_to_custom" = $true
}
$configJson = $config | ConvertTo-Json -Depth 6
$configPath = Join-Path $InstallDir "config.json"
[IO.File]::WriteAllText($configPath, $configJson, (New-Object System.Text.UTF8Encoding($false)))
Write-Ok "config.json 已写入"

Write-Step "生成启动脚本"
$batch = @'
@echo off
setlocal
set "ROOT=%~dp0"
set "PYTHON=__PYTHON__"
set "WEBUI=__WEBUI__"
set "HF_HOME=__CACHE__\huggingface"
set "TRANSFORMERS_CACHE=__CACHE__\huggingface\hub"
set "TORCH_HOME=__CACHE__\torch"
set "MPLCONFIGDIR=__CACHE__\matplotlib"
set "HF_HUB_OFFLINE=1"

if not exist "%PYTHON%" (
  echo [ERROR] Python not found: %PYTHON%
  pause
  exit /b 1
)
if not exist "%WEBUI%\launch.py" (
  echo [ERROR] WebUI not found: %WEBUI%
  pause
  exit /b 1
)

cd /d "%WEBUI%"
"%PYTHON%" launch.py --api --ckpt "models\Stable-diffusion\v1-5-pruned-emaonly.safetensors" --no-half-vae __EXTRA__ %*
echo.
echo WebUI stopped.
pause
'@
$batch = $batch.Replace("__PYTHON__", $Python).Replace("__WEBUI__", $InstallDir).Replace("__CACHE__", $CacheDir)
$extra = ""
if ($Cpu) { $extra = "--skip-torch-cuda-test --use-cpu all --no-half" }
$batch = $batch.Replace("__EXTRA__", $extra)
[IO.File]::WriteAllText($StartBat, $batch, (New-Object System.Text.UTF8Encoding($false)))
Write-Ok "启动脚本: $StartBat"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " 安装完成！" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host " 启动: $StartBat" -ForegroundColor White
Write-Host " 地址: http://127.0.0.1:7860" -ForegroundColor White
Write-Host ""
Write-Host " 首次启动会加载模型，约需 1-3 分钟。" -ForegroundColor Gray
Write-Host " 8GB 显存建议 AnimateDiff 使用 8-16 帧、512x512；OOM 时加 --medvram。" -ForegroundColor Gray
Write-Host ""

if ($Launch) {
    Start-Process -FilePath $StartBat -WorkingDirectory $Root
}
