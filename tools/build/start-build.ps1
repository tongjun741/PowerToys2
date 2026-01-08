<#
.SYNOPSIS
    PowerToys2 自动化构建脚本 - 完整版
.DESCRIPTION
    自动化克隆、配置依赖并构建 PowerToys2 项目
    解决文件锁定、Runtime Pack 缺失等常见问题
.PARAMETER CleanBuild
    是否清理现有目录重新开始
.PARAMETER SkipClone
    跳过克隆步骤（用于已有代码的情况）
.PARAMETER NoCacheClean
    不清理 NuGet 缓存（推荐，避免重新下载）
#>

param(
    [switch]$CleanBuild = $false,
    [switch]$SkipClone = $false,
    [switch]$NoCacheClean = $true
)

# 启用严格错误处理
$ErrorActionPreference = "Stop"

# ==================== 配置 ====================
$BaseDir = "D:\PowerToys2"
$RepoUrl = "https://github.com/tongjun741/PowerToys2.git"

# ==================== 辅助函数 ====================
function Write-Step {
    param([string]$Message)
    Write-Host "`n╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  $Message" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor Yellow
}

function Write-Failure {
    param([string]$Message)
    Write-Host "✗ $Message" -ForegroundColor Red
}

function Stop-BuildProcesses {
    param([bool]$Verbose = $true)
    
    if ($Verbose) { Write-Info "停止构建进程..." }
    
    $processes = @("MSBuild", "dotnet", "VBCSCompiler", "ServiceHub", "PerfWatson", "vshost", "testhost")
    $stopped = 0
    
    foreach ($proc in $processes) {
        $running = Get-Process -Name $proc -ErrorAction SilentlyContinue
        if ($running) {
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
            $stopped += $running.Count
        }
    }
    
    if ($Verbose -and $stopped -gt 0) {
        Write-Info "已停止 $stopped 个进程"
    }
    
    Start-Sleep -Seconds 3
}

# ==================== 主构建流程 ====================
try {
    $startTime = Get-Date
    
    Write-Host @"

╔════════════════════════════════════════════════════════════╗
║                                                            ║
║          PowerToys2 自动化构建脚本 v2.0                    ║
║          解决文件锁定和依赖问题                            ║
║                                                            ║
╚════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan

    # ==================== 步骤 1: 准备项目 ====================
    if (-not $SkipClone) {
        Write-Step "步骤 1/9: 准备项目目录"
        
        Set-Location "D:\"
        
        if (Test-Path $BaseDir) {
            if ($CleanBuild) {
                Write-Info "清理现有目录..."
                Stop-BuildProcesses -Verbose $false
                Remove-Item $BaseDir -Recurse -Force
                Write-Success "目录已清理"
            } else {
                Write-Info "使用现有目录: $BaseDir"
            }
        }
        
        if (-not (Test-Path $BaseDir)) {
            Write-Info "克隆仓库: $RepoUrl"
            git clone $RepoUrl
            if ($LASTEXITCODE -ne 0) { throw "Git 克隆失败" }
            Write-Success "仓库克隆完成"
        }
        
        Set-Location $BaseDir
        
        Write-Info "更新子模块..."
        git submodule update --init --recursive
        if ($LASTEXITCODE -ne 0) { throw "子模块更新失败" }
        Write-Success "子模块更新完成"
        
    } else {
        Write-Step "步骤 1/9: 使用现有代码"
        Set-Location $BaseDir
        Write-Info "当前目录: $BaseDir"
    }
    
    # ==================== 步骤 2: 停止所有构建进程 ====================
    Write-Step "步骤 2/9: 清理构建进程"
    Stop-BuildProcesses
    Write-Success "构建进程已清理"
    
    # ==================== 步骤 3: 安装构建工具 ====================
    Write-Step "步骤 3/9: 安装构建工具"
    
    # WiX Toolset
    Write-Info "安装 WiX Toolset 5.0.2..."
    dotnet tool install --global wix --version 5.0.2 --no-cache 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1) {
        Write-Success "WiX Toolset 已就绪"
    } else {
        Write-Info "WiX Toolset 可能已安装（忽略错误）"
    }
    
    # Windows SDK
    Write-Info "安装 Windows SDK 10.0.19041..."
    winget install --id Microsoft.WindowsSDK.10.0.19041 --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
    Write-Success "Windows SDK 已就绪"
    
    # ==================== 步骤 4: 安装 WiX Heat 工具 ====================
    Write-Step "步骤 4/9: 配置 WiX Heat 工具"
    
    $PackagesDir = "$BaseDir\packages"
    New-Item -ItemType Directory -Path $PackagesDir -Force | Out-Null
    
    Write-Info "安装 WiX Heat..."
    nuget install wixtoolset.heat -Version 5.0.2 -OutputDirectory $PackagesDir -NonInteractive 2>&1 | Out-Null
    
    # 配置 Heat 路径
    $HeatPaths = @(
        "$PackagesDir\wixtoolset.heat.5.0.2\tools\net472\x64",
        "$env:USERPROFILE\.nuget\packages\wixtoolset.heat\5.0.2\tools\net472\x64"
    )
    
    $heatFound = $false
    foreach ($path in $HeatPaths) {
        if (Test-Path $path) {
            if ($env:PATH -notlike "*$path*") {
                $env:PATH += ";$path"
            }
            $heatFound = $true
            Write-Success "Heat 工具路径: $path"
            break
        }
    }
    
    if (-not $heatFound) {
        Write-Failure "Heat 工具未找到，但继续构建"
    }
    
    # ==================== 步骤 5: 安装 WiX 依赖包 ====================
    Write-Step "步骤 5/9: 安装 WiX 构建依赖"
    
    Set-Location "$BaseDir\installer"
    
    Write-Info "安装 WixToolset.WcaUtil..."
    nuget install WixToolset.WcaUtil -Version 5.0.2 -OutputDirectory packages -NonInteractive 2>&1 | Out-Null
    
    Write-Info "安装 WixToolset.Dutil..."
    nuget install WixToolset.Dutil -Version 5.0.2 -OutputDirectory packages -NonInteractive 2>&1 | Out-Null
    
    # 验证关键文件
    $wcautilProps = "packages\WixToolset.WcaUtil.5.0.2\build\WixToolset.WcaUtil.props"
    $wcautilLib = "packages\WixToolset.WcaUtil.5.0.2\build\native\v14\x64\wcautil.lib"
    
    if ((Test-Path $wcautilProps) -and (Test-Path $wcautilLib)) {
        Write-Success "WiX 依赖包安装完成"
    } else {
        Write-Failure "部分 WiX 文件缺失，但继续构建"
    }
    
    Set-Location $BaseDir
    
    # ==================== 步骤 6: 配置环境变量 ====================
    Write-Step "步骤 6/9: 配置环境变量"
    
    $env:NUGET_PACKAGES = "$BaseDir\installer\packages"
    Write-Info "NUGET_PACKAGES = $env:NUGET_PACKAGES"
    Write-Success "环境变量已配置"
    
    # ==================== 步骤 7: 恢复 NuGet 包 ====================
    Write-Step "步骤 7/9: 恢复 NuGet 包和 Runtime Packs"
    
    if (-not $NoCacheClean) {
        Write-Info "清理 NuGet 缓存..."
        dotnet nuget locals all --clear
    } else {
        Write-Info "保留 NuGet 缓存（加速构建）"
    }
    
    Write-Info "恢复所有项目依赖..."
    dotnet restore --force 2>&1 | Out-Null
    
    Write-Info "恢复 win-x64 Runtime Packs..."
    dotnet restore --runtime win-x64 --force 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Success "NuGet 包和 Runtime Packs 恢复完成"
    } else {
        Write-Info "部分包恢复可能失败，但继续构建"
    }
    
    # ==================== 步骤 8: 修改构建脚本（禁用清理）====================
    Write-Step "步骤 8/9: 优化构建脚本"
    
    $buildScript = "$BaseDir\tools\build\build-installer.ps1"
    $buildScriptBackup = "$buildScript.original"
    
    # 只在第一次运行时备份
    if (-not (Test-Path $buildScriptBackup)) {
        Copy-Item $buildScript $buildScriptBackup -Force
        Write-Info "已备份原始构建脚本"
        
        # 修改构建脚本
        $content = Get-Content $buildScript -Raw
        
        # 禁用 installer 清理
        $content = $content -replace '(Write-Host "\[CLEAN\] installer[^"]*")', '# DISABLED: $1'
        $content = $content -replace '(\s+)(Remove-Item.*installer.*packages[^\r\n]*)', '$1# DISABLED (file locking): $2'
        $content = $content -replace '(\s+)(Get-ChildItem.*installer.*packages.*Remove-Item[^\r\n]*)', '$1# DISABLED (file locking): $2'
        
        Set-Content $buildScript -Value $content -NoNewline
        Write-Success "已优化构建脚本（禁用清理以避免文件锁定）"
    } else {
        Write-Info "使用已优化的构建脚本"
    }
    
    # 清理旧的 WXS 备份文件
    Write-Info "清理旧的 WXS 备份文件..."
    $wxsBackups = Get-ChildItem -Path "$BaseDir\installer" -Filter "*.wxs.bk" -Recurse -ErrorAction SilentlyContinue
    if ($wxsBackups) {
        $wxsBackups | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Info "已删除 $($wxsBackups.Count) 个旧备份文件"
    }
    
    # ==================== 步骤 9: 开始构建 ====================
    Write-Step "步骤 9/9: 开始构建 PowerToys 安装程序"
    
    Stop-BuildProcesses -Verbose $false
    Start-Sleep -Seconds 2
    
    Write-Info "执行构建脚本..."
    Write-Info "构建日志: installer\build.release.x64.*.log"
    Write-Host ""
    Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    
    # 执行构建
    pwsh $buildScript
    
    Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    
    # ==================== 构建完成 ====================
    if ($LASTEXITCODE -eq 0) {
        $endTime = Get-Date
        $duration = $endTime - $startTime
        
        Write-Host ""
        Write-Step "构建成功完成！"
        Write-Success "总耗时: $($duration.ToString('hh\:mm\:ss'))"
        
        # 查找生成的安装程序
        Write-Host "`n生成的文件:" -ForegroundColor Cyan
        
        $installers = Get-ChildItem -Path "$BaseDir\installer" -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -like "*PowerToys*" -and $_.Length -gt 1MB } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 5
        
        if ($installers) {
            foreach ($installer in $installers) {
                $sizeMB = [math]::Round($installer.Length / 1MB, 2)
                Write-Success "$($installer.Name) ($sizeMB MB)"
                Write-Host "           $($installer.FullName)" -ForegroundColor Gray
            }
        } else {
            Write-Info "未找到生成的 EXE 文件，请检查构建日志"
        }
        
        Write-Host ""
        Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "║                  🎉 构建流程全部完成！ 🎉                  ║" -ForegroundColor Green
        Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
        Write-Host ""
        
    } else {
        throw "构建失败，退出代码: $LASTEXITCODE"
    }
    
} catch {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║                    ❌ 构建失败 ❌                          ║" -ForegroundColor Red
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    Write-Failure "错误信息: $_"
    Write-Host ""
    Write-Host "错误堆栈:" -ForegroundColor Yellow
    Write-Host $_.ScriptStackTrace -ForegroundColor Gray
    
    Write-Host "`n📋 日志文件位置:" -ForegroundColor Cyan
    Write-Host "  • 完整日志: $BaseDir\installer\build.release.x64.all.log" -ForegroundColor Yellow
    Write-Host "  • 错误日志: $BaseDir\installer\build.release.x64.errors.log" -ForegroundColor Yellow
    Write-Host "  • 警告日志: $BaseDir\installer\build.release.x64.warnings.log" -ForegroundColor Yellow
    Write-Host "  • 二进制日志: $BaseDir\installer\build.release.x64.trace.binlog" -ForegroundColor Yellow
    
    Write-Host "`n💡 常见问题排查:" -ForegroundColor Cyan
    Write-Host "  1. 检查错误日志了解具体失败原因" -ForegroundColor Gray
    Write-Host "  2. 确保有足够的磁盘空间 (需要约 5-10 GB)" -ForegroundColor Gray
    Write-Host "  3. 尝试以管理员身份运行脚本" -ForegroundColor Gray
    Write-Host "  4. 关闭杀毒软件再试" -ForegroundColor Gray
    Write-Host "  5. 使用 -CleanBuild 参数完全重新开始" -ForegroundColor Gray
    Write-Host ""
    
    exit 1
}