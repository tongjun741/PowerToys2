<#
.SYNOPSIS
    PowerToys2 自动化构建脚本
.DESCRIPTION
    自动化克隆、配置依赖并构建 PowerToys2 项目
.PARAMETER CleanBuild
    是否清理现有目录重新开始
.PARAMETER SkipClone
    跳过克隆步骤（用于已有代码的情况）
#>

param(
    [switch]$CleanBuild = $false,
    [switch]$SkipClone = $false
)

# 启用严格错误处理
$ErrorActionPreference = "Stop"

# 配置
$BaseDir = "D:\PowerToys2"
$RepoUrl = "https://github.com/tongjun741/PowerToys2.git"

# 颜色输出函数
function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
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

# 清理构建进程
function Stop-BuildProcesses {
    Write-Step "清理构建进程"
    $processes = @("MSBuild", "dotnet", "VBCSCompiler", "ServiceHub", "PerfWatson")
    
    foreach ($proc in $processes) {
        $running = Get-Process -Name $proc -ErrorAction SilentlyContinue
        if ($running) {
            Write-Info "停止进程: $proc"
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
    
    Start-Sleep -Seconds 3
    Write-Success "进程清理完成"
}

# 主构建流程
try {
    Write-Host @"
╔════════════════════════════════════════════════════════════╗
║          PowerToys2 自动化构建脚本                          ║
╚════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

    # 步骤 1: 克隆或清理项目
    if (-not $SkipClone) {
        Write-Step "步骤 1: 准备项目目录"
        
        Set-Location "D:\"
        
        if (Test-Path $BaseDir) {
            if ($CleanBuild) {
                Write-Info "清理现有目录..."
                Stop-BuildProcesses
                Remove-Item $BaseDir -Recurse -Force
                Write-Success "目录已清理"
            } else {
                Write-Info "使用现有目录"
            }
        }
        
        if (-not (Test-Path $BaseDir)) {
            Write-Info "克隆仓库: $RepoUrl"
            git clone $RepoUrl
            Write-Success "仓库克隆完成"
        }
        
        Set-Location $BaseDir
        
        Write-Info "更新子模块..."
        git submodule update --init --recursive
        Write-Success "子模块更新完成"
    } else {
        Write-Step "步骤 1: 跳过克隆，使用现有代码"
        Set-Location $BaseDir
    }
    
    # 步骤 2: 安装构建工具
    Write-Step "步骤 2: 安装构建工具"
    
    Write-Info "安装 WiX Toolset 5.0.2..."
    dotnet tool install --global wix --version 5.0.2 --no-cache 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "WiX Toolset 已安装"
    } else {
        Write-Info "WiX Toolset 可能已安装（忽略错误）"
    }
    
    Write-Info "安装 Windows SDK 10.0.19041..."
    winget install --id Microsoft.WindowsSDK.10.0.19041 --silent --accept-package-agreements --accept-source-agreements 2>$null
    Write-Success "Windows SDK 安装完成"
    
    # 步骤 3: 安装 WiX Heat 工具
    Write-Step "步骤 3: 安装 WiX Heat 工具"
    
    $PackagesDir = "$BaseDir\packages"
    New-Item -ItemType Directory -Path $PackagesDir -Force | Out-Null
    
    Write-Info "安装 WiX Heat 到: $PackagesDir"
    nuget install wixtoolset.heat -Version 5.0.2 -OutputDirectory $PackagesDir -NonInteractive | Out-Null
    
    # 配置 Heat 路径
    $HeatPaths = @(
        "$PackagesDir\wixtoolset.heat.5.0.2\tools\net472\x64",
        "$env:USERPROFILE\.nuget\packages\wixtoolset.heat\5.0.2\tools\net472\x64"
    )
    
    foreach ($path in $HeatPaths) {
        if (Test-Path $path) {
            $env:PATH += ";$path"
            Write-Success "Heat 路径已添加: $path"
            break
        }
    }
    
    # 验证 Heat 安装
    try {
        heat.exe -? | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Heat 工具验证成功"
        }
    } catch {
        Write-Failure "Heat 工具验证失败，但继续构建"
    }
    
    # 步骤 4: 安装 WiX 构建依赖包
    Write-Step "步骤 4: 安装 WiX 构建依赖包"
    
    Set-Location "$BaseDir\installer"
    
    Write-Info "安装 WixToolset.WcaUtil 5.0.2..."
    nuget install WixToolset.WcaUtil -Version 5.0.2 -OutputDirectory packages -NonInteractive | Out-Null
    
    Write-Info "安装 WixToolset.Dutil 5.0.2..."
    nuget install WixToolset.Dutil -Version 5.0.2 -OutputDirectory packages -NonInteractive | Out-Null
    
    # 验证关键文件
    $wcautilProps = "packages\WixToolset.WcaUtil.5.0.2\build\WixToolset.WcaUtil.props"
    $wcautilLib = "packages\WixToolset.WcaUtil.5.0.2\build\native\v14\x64\wcautil.lib"
    
    if (Test-Path $wcautilProps) {
        Write-Success "WcaUtil Props 文件已安装"
    } else {
        Write-Failure "WcaUtil Props 文件缺失: $wcautilProps"
    }
    
    if (Test-Path $wcautilLib) {
        Write-Success "wcautil.lib 库文件已安装"
    } else {
        Write-Failure "wcautil.lib 库文件缺失: $wcautilLib"
    }
    
    Set-Location $BaseDir
    
    # 步骤 5: 配置环境变量
    Write-Step "步骤 5: 配置环境变量"
    
    $env:NUGET_PACKAGES = "$BaseDir\installer\packages"
    Write-Info "NUGET_PACKAGES = $env:NUGET_PACKAGES"
    Write-Success "环境变量已配置"
    
    # 步骤 6: 恢复 NuGet 包
    Write-Step "步骤 6: 恢复 NuGet 包"
    
    Write-Info "执行 dotnet restore..."
    dotnet restore
    
    if ($LASTEXITCODE -eq 0) {
        Write-Success "NuGet 包恢复完成"
    } else {
        Write-Failure "NuGet 包恢复失败，但继续构建"
    }
    
    # 步骤 7: 清理构建进程（构建前）
    Stop-BuildProcesses
    
    # 步骤 8: 开始构建
    Write-Step "步骤 8: 开始构建 PowerToys 安装程序"
    
    $BuildScript = "$BaseDir\tools\build\build-installer.ps1"
    
    if (-not (Test-Path $BuildScript)) {
        throw "构建脚本不存在: $BuildScript"
    }
    
    Write-Info "执行构建脚本..."
    Write-Info "构建日志位置: installer\build.release.x64.*.log"
    Write-Host ""
    
    # 使用 'n' 自动回答文件锁定提示
    "n" | pwsh $BuildScript
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Step "构建成功完成！"
        Write-Success "安装程序应该在: installer\ 目录中"
        
        # 查找生成的安装程序
        $installers = Get-ChildItem -Path "$BaseDir\installer" -Filter "*.exe" -Recurse | 
            Where-Object { $_.Name -like "*PowerToys*" } |
            Select-Object -First 5
        
        if ($installers) {
            Write-Host "`n生成的安装程序:" -ForegroundColor Cyan
            $installers | ForEach-Object {
                Write-Success $_.FullName
            }
        }
        
    } else {
        throw "构建失败，退出代码: $LASTEXITCODE"
    }
    
} catch {
    Write-Host ""
    Write-Failure "构建过程中发生错误"
    Write-Host "错误信息: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    
    Write-Host "`n日志文件位置:" -ForegroundColor Yellow
    Write-Host "  - 完整日志: installer\build.release.x64.all.log" -ForegroundColor Yellow
    Write-Host "  - 错误日志: installer\build.release.x64.errors.log" -ForegroundColor Yellow
    Write-Host "  - 警告日志: installer\build.release.x64.warnings.log" -ForegroundColor Yellow
    
    exit 1
}

Write-Host @"

╔════════════════════════════════════════════════════════════╗
║                  构建流程全部完成！                         ║
╚════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Green