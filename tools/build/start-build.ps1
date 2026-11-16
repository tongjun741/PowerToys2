<#
.SYNOPSIS
    PowerToys2 自动化构建脚本 - 最终修复版
.DESCRIPTION
    修复 NUGET_PACKAGES 环境变量路径问题
#>

param(
    [switch]$CleanBuild = $false,
    [switch]$SkipClone = $false,
    [switch]$NoCacheClean = $true,
    [switch]$DiagnoseOnly = $false
)

$ErrorActionPreference = "Stop"

$Script:Config = @{
    BaseDir      = "D:\PowerToys2"
    RepoUrl      = "https://github.com/tongjun741/PowerToys2.git"
    WixVersion   = "5.0.2"
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
    
    Write-Info "检查 NUGET_PACKAGES 环境变量..."
    if ($env:NUGET_PACKAGES) {
        Write-Info "当前值: $env:NUGET_PACKAGES"
        $wcautilPath = "$env:NUGET_PACKAGES\wixtoolset.wcautil\$($Config.WixVersion)\build\native\v14\x64\wcautil.lib"
        if (Test-Path $wcautilPath) {
            Write-Success "该路径下 wcautil.lib 存在"
        }
        else {
            Write-Error "该路径下 wcautil.lib 不存在"
            Write-Info "预期位置: $wcautilPath"
        }
    }
    else {
        Write-Error "NUGET_PACKAGES 环境变量未设置"
    }
    
    $vcxproj = "$($Config.BaseDir)\installer\PowerToysSetupCustomActionsVNext\PowerToysSetupCustomActionsVNext.vcxproj"
    if (Test-Path $vcxproj) {
        $projContent = Get-Content $vcxproj -Raw
        if ($projContent -match '<AdditionalLibraryDirectories>([^<]+)</AdditionalLibraryDirectories>') {
            Write-Info "项目库路径配置:"
            $Matches[1] -split ";" | ForEach-Object {
                if ($_ -like "*WixToolset*" -or $_ -like "*NUGET_PACKAGES*") { 
                    Write-Success "  $_" 
                }
                else { 
                    Write-Host "    $_" -ForegroundColor Gray 
                }
            }
        }
    }
    
    Write-Info "检查 LIB 环境变量..."
    if ($env:LIB) {
        $libPaths = $env:LIB -split ";"
        $hasWix = $false
        foreach ($path in $libPaths) {
            if ($path -like "*WixToolset*" -or $path -like "*wcautil*") {
                Write-Success "  $path"
                $hasWix = $true
            }
        }
        if (-not $hasWix) {
            Write-Error "LIB 不包含 WiX 路径"
        }
    }
    
    return $foundLibs -gt 0
}

function Repair-BuildScript {
    param([string]$ScriptPath)
    Write-Info "优化构建脚本..."
    if (-not (Test-Path "$ScriptPath.original")) {
        Copy-Item $ScriptPath "$ScriptPath.original" -Force
    }
    
    $content = Get-Content $ScriptPath -Raw
    $modified = $false
    
    # 禁用 git clean
    if ($content -match "git clean -xfd" -and $content -notmatch "# DISABLED.*git clean") {
        $content = $content -replace "(\s+)(git clean -xfd -e '\*\.exe' -- \.\\installer\\ \| Out-Null)", '$1# DISABLED: $2'
        $modified = $true
    }
    
    # 在构建脚本开头设置正确的环境变量
    $wixLibPath = "$($Config.BaseDir)\installer\packages\WixToolset.WcaUtil.$($Config.WixVersion)\build\native\v14\x64"
    $wixLibPath += ";$($Config.BaseDir)\installer\packages\WixToolset.Dutil.$($Config.WixVersion)\build\native\v14\x64"
    
    # 重点：确保 NUGET_PACKAGES 指向正确的位置
    $nugetPackagesPath = "$($Config.BaseDir)\installer\packages"
    
    if ($content -notmatch '\$env:NUGET_PACKAGES.*installer.*packages') {
        $envSetup = @"

# 设置正确的 NUGET_PACKAGES 路径（关键修复）
`$env:NUGET_PACKAGES = "$nugetPackagesPath"
Write-Host "[INFO] NUGET_PACKAGES = `$env:NUGET_PACKAGES" -ForegroundColor Cyan

# 设置 WiX 库路径
`$wixLib = "$wixLibPath"
if (`$env:LIB) {
    `$env:LIB = "`$wixLib;`$env:LIB"
} else {
    `$env:LIB = `$wixLib
}
if (`$env:LIBPATH) {
    `$env:LIBPATH = "`$wixLib;`$env:LIBPATH"
} else {
    `$env:LIBPATH = `$wixLib
}
Write-Host "[INFO] LIB 路径已设置" -ForegroundColor Cyan

"@
        if ($content -match '(\r?\n)(# Ensure|function |Write-Host|\$repoRoot)') {
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
    else {
        Write-Info "构建脚本已是最新"
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
    Write-Info "准备 WiX 包..."
    
    # 确定源包位置
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
    
    # 如果不存在，安装
    if (-not $srcWcaUtil) {
        nuget install WixToolset.WcaUtil -Version $Config.WixVersion -OutputDirectory "$env:USERPROFILE\.nuget\packages" -NonInteractive 2>&1 | Out-Null
        $srcWcaUtil = "$env:USERPROFILE\.nuget\packages\wixtoolset.wcautil\$($Config.WixVersion)"
    }
    
    if (-not $srcDutil) {
        nuget install WixToolset.Dutil -Version $Config.WixVersion -OutputDirectory "$env:USERPROFILE\.nuget\packages" -NonInteractive 2>&1 | Out-Null
        $srcDutil = "$env:USERPROFILE\.nuget\packages\wixtoolset.dutil\$($Config.WixVersion)"
    }
    
    # 复制到 installer\packages（小写目录名，匹配 NUGET_PACKAGES 的引用）
    $destWcaUtil = "$InstallerPath\packages\wixtoolset.wcautil\$($Config.WixVersion)"
    $destDutil = "$InstallerPath\packages\wixtoolset.dutil\$($Config.WixVersion)"
    
    # 同时也复制到大写目录名（兼容性）
    $destWcaUtilUpper = "$InstallerPath\packages\WixToolset.WcaUtil.$($Config.WixVersion)"
    $destDutilUpper = "$InstallerPath\packages\WixToolset.Dutil.$($Config.WixVersion)"
    
    # 删除旧的
    @($destWcaUtil, $destDutil, $destWcaUtilUpper, $destDutilUpper) | ForEach-Object {
        if (Test-Path $_) {
            Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    # 复制（小写）
    Copy-Item $srcWcaUtil -Destination $destWcaUtil -Recurse -Force
    Copy-Item $srcDutil -Destination $destDutil -Recurse -Force
    
    # 复制（大写）
    Copy-Item $srcWcaUtil -Destination $destWcaUtilUpper -Recurse -Force
    Copy-Item $srcDutil -Destination $destDutilUpper -Recurse -Force
    
    Write-Success "WiX 包已复制（小写和大写目录）"
    
    # 验证
    $wcautilLibLower = "$destWcaUtil\build\native\v14\x64\wcautil.lib"
    $wcautilLibUpper = "$destWcaUtilUpper\build\native\v14\x64\wcautil.lib"
    
    if ((Test-Path $wcautilLibLower) -and (Test-Path $wcautilLibUpper)) {
        Write-Success "wcautil.lib 已验证（两个位置）"
    }
    else {
        throw "wcautil.lib 验证失败"
    }
    
    # 设置环境变量（使用大写路径）
    $libPath = "$destWcaUtilUpper\build\native\v14\x64;$destDutilUpper\build\native\v14\x64"
    $env:LIB = "$libPath;$env:LIB"
    $env:LIBPATH = "$libPath;$env:LIBPATH"
    
    # 关键：设置 NUGET_PACKAGES 到 installer\packages
    $env:NUGET_PACKAGES = "$InstallerPath\packages"
    
    Write-Success "环境变量已配置"
    Write-Info "NUGET_PACKAGES = $env:NUGET_PACKAGES"
    Write-Info "LIB 包含 WiX 路径"
}

try {
    $startTime = Get-Date
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║          PowerToys2 自动化构建脚本 v4.1                    ║" -ForegroundColor Cyan
    Write-Host "║          修复 NUGET_PACKAGES 路径问题                      ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    
    if ($DiagnoseOnly) {
        Set-Location $Config.BaseDir
        Invoke-WcautilDiagnosis | Out-Null
        exit 0
    }
    
    if (-not $SkipClone) {
        Write-StepHeader "步骤 1/10: 准备项目"
        Set-Location "D:\"
        if (Test-Path $Config.BaseDir) {
            if ($CleanBuild) {
                Stop-BuildProcesses -Verbose $false
                Remove-Item $Config.BaseDir -Recurse -Force
            }
        }
        if (-not (Test-Path $Config.BaseDir)) {
            git clone -b tray-menu $Config.RepoUrl
        }
        Set-Location $Config.BaseDir
        git submodule update --init --recursive | Out-Null
        Write-Success "完成"
    }
    else {
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
    
    Write-StepHeader "步骤 6/10: 配置环境（重要）"
    # 这里再次确认 NUGET_PACKAGES
    $env:NUGET_PACKAGES = "$($Config.BaseDir)\installer\packages"
    Write-Success "NUGET_PACKAGES = $env:NUGET_PACKAGES"
    
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
    # 验证小写路径（项目使用这个）
    $wcautilLibLower = "$($Config.BaseDir)\installer\packages\wixtoolset.wcautil\$($Config.WixVersion)\build\native\v14\x64\wcautil.lib"
    if (Test-Path $wcautilLibLower) {
        Write-Success "wcautil.lib 已就绪（小写路径）"
    }
    else {
        Write-Error "wcautil.lib 缺失（小写路径）"
    }
    
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
        
        $installers = Get-ChildItem -Path "$($Config.BaseDir)\installer\PowerToysSetupVNext" -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue | 
        Where-Object { $_.Length -gt 1MB } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 5
        
        if ($installers) {
            Write-Host ""
            Write-Host "  生成的安装包:" -ForegroundColor Cyan
            foreach ($i in $installers) {
                $sizeMB = [math]::Round($i.Length / 1MB, 2)
                Write-Host "    ✓ $($i.Name) ($sizeMB MB)" -ForegroundColor Green
                Write-Host "      $($i.FullName)" -ForegroundColor Gray
            }
        }
        Write-Host ""
        Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "║                  🎉 构建完成！ 🎉                          ║" -ForegroundColor Green
        Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    }
    else {
        throw "构建失败: $exitCode"
    }
    
}
catch {
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
    }
    catch {}
    Write-Host "━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    
    Write-Host ""
    Write-Host "  📋 错误日志: $($Config.BaseDir)\installer\build.release.x64.errors.log" -ForegroundColor Yellow
    Write-Host "  📄 完整日志: $($Config.BaseDir)\installer\build.release.x64.all.log" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  💡 诊断: .\start-build.ps1 -DiagnoseOnly" -ForegroundColor Cyan
    Write-Host "  🔄 重试: .\start-build.ps1 -CleanBuild" -ForegroundColor Cyan
    Write-Host ""
    exit 1
}
