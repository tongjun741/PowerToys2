<#
.SYNOPSIS
    PowerToys2 自动化构建脚本 - 完整诊断版
.DESCRIPTION
    自动化克隆、配置依赖并构建 PowerToys2 项目
    包含完整的诊断和自动修复功能
.PARAMETER CleanBuild
    是否清理现有目录重新开始
.PARAMETER SkipClone
    跳过克隆步骤（用于已有代码的情况）
.PARAMETER NoCacheClean
    不清理 NuGet 缓存（推荐，避免重新下载）
.PARAMETER DiagnoseOnly
    仅运行诊断，不执行构建
#>

param(
    [switch]$CleanBuild = $false,
    [switch]$SkipClone = $false,
    [switch]$NoCacheClean = $true,
    [switch]$DiagnoseOnly = $false
)

$ErrorActionPreference = "Stop"

$Script:Config = @{
    BaseDir = "D:\PowerToys2"
    RepoUrl = "https://github.com/tongjun741/PowerToys2.git"
    WixVersion = "5.0.2"
    WindowsSDKId = "Microsoft.WindowsSDK.10.0.19041"
}

function Write-StepHeader {
    param([string]$Message)
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  $Message" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
}

function Write-Success { param([string]$Message) Write-Host "  ✓ $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host "  • $Message" -ForegroundColor Yellow }
function Write-Error { param([string]$Message) Write-Host "  ✗ $Message" -ForegroundColor Red }

function Stop-BuildProcesses {
    param([bool]$Verbose = $true)
    if ($Verbose) { Write-Info "停止构建进程..." }
    $processes = @("MSBuild", "dotnet", "VBCSCompiler", "ServiceHub", "PerfWatson")
    $stopped = 0
    foreach ($proc in $processes) {
        $running = Get-Process -Name $proc -ErrorAction SilentlyContinue
        if ($running) {
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
            $stopped += $running.Count
        }
    }
    if ($Verbose -and $stopped -gt 0) { Write-Info "已停止 $stopped 个进程" }
    Start-Sleep -Seconds 3
}

function Invoke-WcautilDiagnosis {
    Write-StepHeader "wcautil.lib 诊断"
    Write-Info "检查库文件..."
    
    $libLocations = @(
        "$($Config.BaseDir)\installer\packages\WixToolset.WcaUtil.$($Config.WixVersion)\build\native\v14\x64\wcautil.lib",
        "$env:USERPROFILE\.nuget\packages\wixtoolset.wcautil\$($Config.WixVersion)\build\native\v14\x64\wcautil.lib"
    )
    
    $foundLibs = 0
    foreach ($loc in $libLocations) {
        if (Test-Path $loc) {
            $size = (Get-Item $loc).Length
            Write-Success "找到: $loc ($size 字节)"
            $foundLibs++
        }
    }
    
    $vcxproj = "$($Config.BaseDir)\installer\PowerToysSetupCustomActionsVNext\PowerToysSetupCustomActionsVNext.vcxproj"
    if (Test-Path $vcxproj) {
        $projContent = Get-Content $vcxproj -Raw
        if ($projContent -match '<AdditionalLibraryDirectories>([^<]+)</AdditionalLibraryDirectories>') {
            Write-Info "库路径配置:"
            $Matches[1] -split ";" | ForEach-Object {
                if ($_ -like "*WixToolset*") { Write-Success "  $_" }
                else { Write-Host "    $_" -ForegroundColor Gray }
            }
        } else {
            Write-Error "未找到 AdditionalLibraryDirectories"
        }
    }
    
    if ($env:LIB -and ($env:LIB -like "*WixToolset*")) {
        Write-Success "LIB 环境变量包含 WiX 路径"
    } else {
        Write-Info "LIB 环境变量未包含 WiX 路径"
    }
    
    return $foundLibs -gt 0
}

function Repair-BuildScript {
    param([string]$ScriptPath)
    Write-Info "检查构建脚本..."
    if (-not (Test-Path "$ScriptPath.original")) {
        Copy-Item $ScriptPath "$ScriptPath.original" -Force
    }
    
    $content = Get-Content $ScriptPath -Raw
    $modified = $false
    
    if ($content -match "git clean -xfd" -and $content -notmatch "# DISABLED.*git clean") {
        $content = $content -replace "(\s+)(git clean -xfd -e '\*\.exe' -- \.\\installer\\ \| Out-Null)", '$1# DISABLED: $2'
        $modified = $true
        Write-Success "已禁用 git clean"
    }
    
    $wixLibPath = "$($Config.BaseDir)\installer\packages\WixToolset.WcaUtil.$($Config.WixVersion)\build\native\v14\x64"
    $wixLibPath += ";$($Config.BaseDir)\installer\packages\WixToolset.Dutil.$($Config.WixVersion)\build\native\v14\x64"
    
    if ($content -notmatch '\$env:LIB.*WixToolset') {
        $envSetup = @"

# WiX 库路径（自动添加）
`$wixLib = "$wixLibPath"
`$env:LIB = "`$wixLib;`$env:LIB"
`$env:LIBPATH = "`$wixLib;`$env:LIBPATH"
Write-Host "[INFO] WiX 库路径已设置" -ForegroundColor Cyan

"@
        if ($content -match '(\r?\n)(# Ensure|function |Write-Host)') {
            $insertPos = $content.IndexOf($Matches[0])
            if ($insertPos -gt 0) {
                $content = $content.Insert($insertPos, $envSetup)
                $modified = $true
                Write-Success "已添加环境变量设置"
            }
        }
    }
    
    if ($modified) {
        Set-Content $ScriptPath -Value $content -NoNewline
        Write-Success "构建脚本已优化"
    }
}

function Remove-OldBackups {
    param([string]$Path, [string]$Pattern)
    $backups = Get-ChildItem -Path $Path -Filter $Pattern -Recurse -ErrorAction SilentlyContinue
    if ($backups) {
        $backups | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Info "已删除 $($backups.Count) 个备份"
    }
}

function Ensure-WixPackages {
    param([string]$InstallerPath)
    Write-Info "确保 WiX 包..."
    
    $possibleWcaUtil = @(
        "$env:USERPROFILE\.nuget\packages\wixtoolset.wcautil\$($Config.WixVersion)",
        "C:\Users\runneradmin\.nuget\packages\wixtoolset.wcautil\$($Config.WixVersion)"
    )
    
    $possibleDutil = @(
        "$env:USERPROFILE\.nuget\packages\wixtoolset.dutil\$($Config.WixVersion)",
        "C:\Users\runneradmin\.nuget\packages\wixtoolset.dutil\$($Config.WixVersion)"
    )
    
    $srcWcaUtil = $null
    $srcDutil = $null
    
    foreach ($loc in $possibleWcaUtil) {
        if (Test-Path $loc) { $srcWcaUtil = $loc; break }
    }
    foreach ($loc in $possibleDutil) {
        if (Test-Path $loc) { $srcDutil = $loc; break }
    }
    
    if (-not $srcWcaUtil) {
        nuget install WixToolset.WcaUtil -Version $Config.WixVersion -OutputDirectory "$env:USERPROFILE\.nuget\packages" -NonInteractive 2>&1 | Out-Null
        $srcWcaUtil = "$env:USERPROFILE\.nuget\packages\wixtoolset.wcautil\$($Config.WixVersion)"
    }
    
    if (-not $srcDutil) {
        nuget install WixToolset.Dutil -Version $Config.WixVersion -OutputDirectory "$env:USERPROFILE\.nuget\packages" -NonInteractive 2>&1 | Out-Null
        $srcDutil = "$env:USERPROFILE\.nuget\packages\wixtoolset.dutil\$($Config.WixVersion)"
    }
    
    $destWcaUtil = "$InstallerPath\packages\WixToolset.WcaUtil.$($Config.WixVersion)"
    $destDutil = "$InstallerPath\packages\WixToolset.Dutil.$($Config.WixVersion)"
    
    if (Test-Path $destWcaUtil) { Remove-Item $destWcaUtil -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $destDutil) { Remove-Item $destDutil -Recurse -Force -ErrorAction SilentlyContinue }
    
    Copy-Item $srcWcaUtil -Destination $destWcaUtil -Recurse -Force
    Copy-Item $srcDutil -Destination $destDutil -Recurse -Force
    Write-Success "WiX 包已复制"
    
    $wcautilLib = "$destWcaUtil\build\native\v14\x64\wcautil.lib"
    if (-not (Test-Path $wcautilLib)) {
        throw "wcautil.lib 缺失"
    }
    Write-Success "wcautil.lib 已验证"
    
    # 修改项目文件 - 使用绝对路径
    $vcxproj = "$($Config.BaseDir)\installer\PowerToysSetupCustomActionsVNext\PowerToysSetupCustomActionsVNext.vcxproj"
    if (Test-Path $vcxproj) {
        if (-not (Test-Path "$vcxproj.original")) {
            Copy-Item $vcxproj "$vcxproj.original" -Force
        }
        
        $content = Get-Content $vcxproj -Raw
        $absLibPath = "$destWcaUtil\build\native\v14\`$(Platform);$destDutil\build\native\v14\`$(Platform)"
        
        if ($content -notmatch "WixToolset\.WcaUtil.*build.*native") {
            if ($content -match '<AdditionalLibraryDirectories>') {
                $content = $content -replace '(<AdditionalLibraryDirectories>)', "`$1$absLibPath;"
                Set-Content $vcxproj -Value $content -NoNewline
                Write-Success "已添加库路径（绝对）"
            }
        }
    }
    
    $libPath = "$destWcaUtil\build\native\v14\x64;$destDutil\build\native\v14\x64"
    $env:LIB = "$libPath;$env:LIB"
    $env:LIBPATH = "$libPath;$env:LIBPATH"
    Write-Success "环境变量已设置"
}

try {
    $startTime = Get-Date
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║          PowerToys2 自动化构建脚本 v4.0                    ║" -ForegroundColor Cyan
    Write-Host "║          包含完整诊断和自动修复                            ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    
    if ($DiagnoseOnly) {
        Set-Location $Config.BaseDir
        $result = Invoke-WcautilDiagnosis
        Write-Host ""
        if ($result) { Write-Host "✓ 诊断完成" -ForegroundColor Green }
        else { Write-Host "✗ 发现问题" -ForegroundColor Yellow }
        exit 0
    }
    
    if (-not $SkipClone) {
        Write-StepHeader "步骤 1/10: 准备项目"
        Set-Location "D:\"
        if (Test-Path $Config.BaseDir) {
            if ($CleanBuild) {
                Stop-BuildProcesses -Verbose $false
                Remove-Item $Config.BaseDir -Recurse -Force
                Write-Success "已清理"
            }
        }
        if (-not (Test-Path $Config.BaseDir)) {
            git clone $Config.RepoUrl
            Write-Success "已克隆"
        }
        Set-Location $Config.BaseDir
        git submodule update --init --recursive | Out-Null
        Write-Success "子模块已更新"
    } else {
        Write-StepHeader "步骤 1/10: 使用现有代码"
        Set-Location $Config.BaseDir
    }
    
    Write-StepHeader "步骤 2/10: 清理进程"
    Stop-BuildProcesses
    Write-Success "完成"
    
    Write-StepHeader "步骤 3/10: 安装工具"
    dotnet tool install --global wix --version $Config.WixVersion 2>&1 | Out-Null
    winget install --id $Config.WindowsSDKId --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
    Write-Success "完成"
    
    Write-StepHeader "步骤 4/10: 配置 Heat"
    $PackagesDir = "$($Config.BaseDir)\packages"
    New-Item -ItemType Directory -Path $PackagesDir -Force | Out-Null
    nuget install wixtoolset.heat -Version $Config.WixVersion -OutputDirectory $PackagesDir -NonInteractive 2>&1 | Out-Null
    $heatPath = "$PackagesDir\wixtoolset.heat.$($Config.WixVersion)\tools\net472\x64"
    if (Test-Path $heatPath) { $env:PATH += ";$heatPath" }
    Write-Success "完成"
    
    Write-StepHeader "步骤 5/10: 安装 WiX 依赖"
    Set-Location "$($Config.BaseDir)\installer"
    nuget install WixToolset.WcaUtil -Version $Config.WixVersion -OutputDirectory packages -NonInteractive 2>&1 | Out-Null
    nuget install WixToolset.Dutil -Version $Config.WixVersion -OutputDirectory packages -NonInteractive 2>&1 | Out-Null
    Ensure-WixPackages -InstallerPath "$($Config.BaseDir)\installer"
    Set-Location $Config.BaseDir
    
    Write-StepHeader "步骤 6/10: 配置环境"
    $env:NUGET_PACKAGES = "$($Config.BaseDir)\installer\packages"
    Write-Success "完成"
    
    Write-StepHeader "步骤 7/10: 恢复依赖"
    if (-not $NoCacheClean) { dotnet nuget locals all --clear }
    dotnet restore --force 2>&1 | Out-Null
    dotnet restore --runtime win-x64 --force 2>&1 | Out-Null
    Write-Success "完成"
    
    Write-StepHeader "步骤 8/10: 优化脚本"
    Repair-BuildScript -ScriptPath "$($Config.BaseDir)\tools\build\build-installer.ps1"
    Remove-OldBackups -Path "$($Config.BaseDir)\installer" -Pattern "*.wxs.bk"
    Write-Success "完成"
    
    Write-StepHeader "步骤 9/10: 验证"
    $wcautilLib = "$($Config.BaseDir)\installer\packages\WixToolset.WcaUtil.$($Config.WixVersion)\build\native\v14\x64\wcautil.lib"
    if (Test-Path $wcautilLib) { Write-Success "wcautil.lib 就绪" }
    else { throw "wcautil.lib 缺失" }
    
    Write-StepHeader "步骤 10/10: 构建"
    Stop-BuildProcesses -Verbose $false
    Start-Sleep -Seconds 2
    Write-Host ""
    Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    & pwsh "$($Config.BaseDir)\tools\build\build-installer.ps1"
    $exitCode = $LASTEXITCODE
    Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    
    if ($exitCode -eq 0) {
        $duration = (Get-Date) - $startTime
        Write-Host ""
        Write-StepHeader "✓ 构建成功！"
        Write-Info "耗时: $($duration.ToString('hh\:mm\:ss'))"
        
        $installers = Get-ChildItem -Path "$($Config.BaseDir)\installer" -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -like "*PowerToys*" -and $_.Length -gt 1MB } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5
        
        if ($installers) {
            Write-Host ""
            foreach ($i in $installers) {
                $sizeMB = [math]::Round($i.Length / 1MB, 2)
                Write-Host "  ✓ $($i.Name) ($sizeMB MB)" -ForegroundColor Green
                Write-Host "    $($i.FullName)" -ForegroundColor Gray
            }
        }
        Write-Host ""
        Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "║                  🎉 构建完成！ 🎉                          ║" -ForegroundColor Green
        Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    } else {
        throw "构建失败: $exitCode"
    }
    
} catch {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║                      ❌ 失败 ❌                            ║" -ForegroundColor Red
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    Write-Error "错误: $_"
    
    Write-Host ""
    Write-Host "━━━ 自动诊断 ━━━" -ForegroundColor Yellow
    try {
        if (Test-Path $Config.BaseDir) {
            Set-Location $Config.BaseDir
            Invoke-WcautilDiagnosis | Out-Null
        }
    } catch {}
    Write-Host "━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    
    Write-Host ""
    Write-Host "  📋 日志: $($Config.BaseDir)\installer\build.release.x64.errors.log" -ForegroundColor Yellow
    Write-Host "  💡 诊断: .\start-build.ps1 -DiagnoseOnly" -ForegroundColor Yellow
    Write-Host "  🔄 重试: .\start-build.ps1 -CleanBuild" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}