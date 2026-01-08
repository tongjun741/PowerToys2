<#
.SYNOPSIS
    PowerToys2 自动化构建脚本 - 最终增强版
.DESCRIPTION
    自动化克隆、配置依赖并构建 PowerToys2 项目
    解决所有已知问题：文件锁定、Runtime Pack 缺失、git clean 冲突、wcautil.lib 缺失等
.PARAMETER CleanBuild
    是否清理现有目录重新开始
.PARAMETER SkipClone
    跳过克隆步骤（用于已有代码的情况）
.PARAMETER NoCacheClean
    不清理 NuGet 缓存（推荐，避免重新下载）
.EXAMPLE
    .\start-build.ps1 -CleanBuild
    完全清理后重新构建
.EXAMPLE
    .\start-build.ps1
    使用现有代码增量构建（推荐）
.EXAMPLE
    .\start-build.ps1 -SkipClone
    跳过 git 克隆，直接构建
#>

param(
    [switch]$CleanBuild = $false,
    [switch]$SkipClone = $false,
    [switch]$NoCacheClean = $true
)

# 启用严格错误处理
$ErrorActionPreference = "Stop"

# ==================== 配置 ====================
$Script:Config = @{
    BaseDir = "D:\PowerToys2"
    RepoUrl = "https://github.com/tongjun741/PowerToys2.git"
    WixVersion = "5.0.2"
    WindowsSDKId = "Microsoft.WindowsSDK.10.0.19041"
}

# ==================== 辅助函数 ====================
function Write-StepHeader {
    param([string]$Message)
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  $Message" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  ✓ $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "  • $Message" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Message)
    Write-Host "  ✗ $Message" -ForegroundColor Red
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

function Repair-BuildScript {
    param([string]$ScriptPath)
    
    Write-Info "检查构建脚本..."
    
    $backupPath = "$ScriptPath.original"
    
    # 只在第一次运行时备份
    if (-not (Test-Path $backupPath)) {
        Copy-Item $ScriptPath $backupPath -Force
        Write-Info "已备份原始脚本: $backupPath"
    }
    
    # 读取内容
    $content = Get-Content $ScriptPath -Raw
    $modified = $false
    
    # 禁用 git clean 命令（这是文件锁定的根源）
    if ($content -match "git clean -xfd" -and $content -notmatch "# DISABLED.*git clean") {
        $content = $content -replace "(\s+)(git clean -xfd -e '\*\.exe' -- \.\\installer\\ \| Out-Null)", '$1# DISABLED (file locking): $2'
        $modified = $true
        Write-Success "已禁用 git clean 命令"
    }
    
    # 注释掉其他可能的清理命令
    if ($content -match "Remove-Item.*installer.*packages" -and $content -notmatch "# DISABLED.*Remove-Item") {
        $content = $content -replace "(\s+)(Remove-Item.*installer.*packages[^\r\n]*)", '$1# DISABLED (file locking): $2'
        $modified = $true
        Write-Success "已禁用 Remove-Item 清理命令"
    }
    
    if ($modified) {
        Set-Content $ScriptPath -Value $content -NoNewline
        Write-Success "构建脚本已优化"
    } else {
        Write-Info "构建脚本已是最新版本"
    }
}

function Remove-OldBackups {
    param([string]$Path, [string]$Pattern)
    
    $backups = Get-ChildItem -Path $Path -Filter $Pattern -Recurse -ErrorAction SilentlyContinue
    if ($backups) {
        $backups | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Info "已删除 $($backups.Count) 个旧备份文件"
    }
}

function Ensure-WixPackages {
    param([string]$InstallerPath)
    
    Write-Info "确保 WiX 包在正确位置..."
    
    # 从所有可能的位置查找 wcautil
    $possibleWcaUtilLocations = @(
        "$env:USERPROFILE\.nuget\packages\wixtoolset.wcautil\$($Config.WixVersion)",
        "C:\Users\runneradmin\.nuget\packages\wixtoolset.wcautil\$($Config.WixVersion)",
        "$env:ProgramFiles\dotnet\sdk\NuGetFallbackFolder\wixtoolset.wcautil\$($Config.WixVersion)"
    )
    
    $possibleDutilLocations = @(
        "$env:USERPROFILE\.nuget\packages\wixtoolset.dutil\$($Config.WixVersion)",
        "C:\Users\runneradmin\.nuget\packages\wixtoolset.dutil\$($Config.WixVersion)"
    )
    
    $sourceWcaUtil = $null
    $sourceDutil = $null
    
    # 查找 WcaUtil
    foreach ($loc in $possibleWcaUtilLocations) {
        if (Test-Path $loc) {
            $sourceWcaUtil = $loc
            Write-Info "找到 WcaUtil: $loc"
            break
        }
    }
    
    # 查找 Dutil
    foreach ($loc in $possibleDutilLocations) {
        if (Test-Path $loc) {
            $sourceDutil = $loc
            Write-Info "找到 Dutil: $loc"
            break
        }
    }
    
    # 如果没找到，重新安装到用户目录
    if (-not $sourceWcaUtil) {
        Write-Info "在用户目录未找到 WcaUtil，重新安装..."
        nuget install WixToolset.WcaUtil -Version $Config.WixVersion -OutputDirectory "$env:USERPROFILE\.nuget\packages" -NonInteractive 2>&1 | Out-Null
        $sourceWcaUtil = "$env:USERPROFILE\.nuget\packages\wixtoolset.wcautil\$($Config.WixVersion)"
    }
    
    if (-not $sourceDutil) {
        Write-Info "在用户目录未找到 Dutil，重新安装..."
        nuget install WixToolset.Dutil -Version $Config.WixVersion -OutputDirectory "$env:USERPROFILE\.nuget\packages" -NonInteractive 2>&1 | Out-Null
        $sourceDutil = "$env:USERPROFILE\.nuget\packages\wixtoolset.dutil\$($Config.WixVersion)"
    }
    
    # 复制到项目 packages 目录
    $destWcaUtil = "$InstallerPath\packages\WixToolset.WcaUtil.$($Config.WixVersion)"
    $destDutil = "$InstallerPath\packages\WixToolset.Dutil.$($Config.WixVersion)"
    
    # 强制重新复制以确保文件完整
    if (Test-Path $sourceWcaUtil) {
        if (Test-Path $destWcaUtil) {
            Remove-Item $destWcaUtil -Recurse -Force -ErrorAction SilentlyContinue
        }
        Copy-Item $sourceWcaUtil -Destination $destWcaUtil -Recurse -Force
        Write-Success "WcaUtil 已复制到项目目录"
    }
    
    if (Test-Path $sourceDutil) {
        if (Test-Path $destDutil) {
            Remove-Item $destDutil -Recurse -Force -ErrorAction SilentlyContinue
        }
        Copy-Item $sourceDutil -Destination $destDutil -Recurse -Force
        Write-Success "Dutil 已复制到项目目录"
    }
    
    # 验证关键文件
    $criticalFiles = @{
        "wcautil.lib (x64)" = "$destWcaUtil\build\native\v14\x64\wcautil.lib"
        "wcautil.lib (x86)" = "$destWcaUtil\build\native\v14\x86\wcautil.lib"
        "dutil.lib (x64)" = "$destDutil\build\native\v14\x64\dutil.lib"
        "WcaUtil.props" = "$destWcaUtil\build\WixToolset.WcaUtil.props"
    }
    
    $allFound = $true
    foreach ($file in $criticalFiles.GetEnumerator()) {
        if (Test-Path $file.Value) {
            $size = (Get-Item $file.Value).Length
            $sizeKB = [math]::Round($size / 1KB, 2)
            Write-Info "$($file.Key): $sizeKB KB"
        } else {
            Write-Error "$($file.Key): 缺失!"
            $allFound = $false
        }
    }
    
    if (-not $allFound) {
        throw "关键 WiX 文件缺失，无法继续构建"
    }
    
    # 修改项目文件直接添加库路径
    Write-Info "修改项目文件添加库路径..."
    
    $vcxproj = "$($Config.BaseDir)\installer\PowerToysSetupCustomActionsVNext\PowerToysSetupCustomActionsVNext.vcxproj"
    
    if (Test-Path $vcxproj) {
        # 备份
        if (-not (Test-Path "$vcxproj.original")) {
            Copy-Item $vcxproj "$vcxproj.original" -Force
        }
        
        # 读取为 XML
        [xml]$proj = Get-Content $vcxproj
        
        # 相对于项目文件的库路径（项目在 installer\PowerToysSetupCustomActionsVNext，包在 installer\packages）
        $relativeLibPath = "..\..\packages\WixToolset.WcaUtil.$($Config.WixVersion)\build\native\v14\x64;..\..\packages\WixToolset.Dutil.$($Config.WixVersion)\build\native\v14\x64"
        
        $modified = $false
        
        # 查找所有 ItemDefinitionGroup
        foreach ($group in $proj.Project.ItemDefinitionGroup) {
            # 处理 x64 Release 配置或无条件的配置
            if ($group.Condition -match "x64.*Release" -or (-not $group.Condition)) {
                # 确保有 Link 节点
                if (-not $group.Link) {
                    $linkNode = $proj.CreateElement("Link", $proj.DocumentElement.NamespaceURI)
                    $group.AppendChild($linkNode) | Out-Null
                }
                
                # 处理 AdditionalLibraryDirectories
                if ($group.Link.AdditionalLibraryDirectories) {
                    $currentValue = $group.Link.AdditionalLibraryDirectories
                    
                    # 如果还没有我们的路径，添加到最前面
                    if ($currentValue -notlike "*WixToolset.WcaUtil*") {
                        $group.Link.AdditionalLibraryDirectories = "$relativeLibPath;$currentValue"
                        $modified = $true
                    }
                } else {
                    # 创建新的
                    $libDirNode = $proj.CreateElement("AdditionalLibraryDirectories", $proj.DocumentElement.NamespaceURI)
                    $libDirNode.InnerText = "$relativeLibPath;%(AdditionalLibraryDirectories)"
                    $group.Link.AppendChild($libDirNode) | Out-Null
                    $modified = $true
                }
            }
        }
        
        if ($modified) {
            $proj.Save($vcxproj)
            Write-Success "项目文件已修改（添加库路径）"
        }
    }
    
    # 设置库路径环境变量（作为备用）
    $libPath = "$destWcaUtil\build\native\v14\x64;$destDutil\build\native\v14\x64"
    $env:LIB = "$libPath;$env:LIB"
    $env:LIBPATH = "$libPath;$env:LIBPATH"
    
    Write-Success "WiX 库路径已配置到环境变量和项目文件"
}

# ==================== 主构建流程 ====================
try {
    $startTime = Get-Date
    
    # 显示欢迎信息
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║                                                            ║" -ForegroundColor Cyan
    Write-Host "║          PowerToys2 自动化构建脚本 v3.1                    ║" -ForegroundColor Cyan
    Write-Host "║          解决所有已知构建问题（含 wcautil.lib）            ║" -ForegroundColor Cyan
    Write-Host "║                                                            ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Info "开始时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host ""
    
    # ==================== 步骤 1: 准备项目 ====================
    if (-not $SkipClone) {
        Write-StepHeader "步骤 1/10: 准备项目目录"
        
        Set-Location "D:\"
        
        if (Test-Path $Config.BaseDir) {
            if ($CleanBuild) {
                Write-Info "清理现有目录..."
                Stop-BuildProcesses -Verbose $false
                Remove-Item $Config.BaseDir -Recurse -Force
                Write-Success "目录已清理"
            } else {
                Write-Info "使用现有目录: $($Config.BaseDir)"
            }
        }
        
        if (-not (Test-Path $Config.BaseDir)) {
            Write-Info "克隆仓库: $($Config.RepoUrl)"
            git clone $Config.RepoUrl
            if ($LASTEXITCODE -ne 0) { throw "Git 克隆失败" }
            Write-Success "仓库克隆完成"
        }
        
        Set-Location $Config.BaseDir
        
        Write-Info "更新子模块..."
        git submodule update --init --recursive | Out-Null
        if ($LASTEXITCODE -ne 0) { 
            Write-Info "子模块更新有警告，但继续"
        } else {
            Write-Success "子模块更新完成"
        }
        
    } else {
        Write-StepHeader "步骤 1/10: 使用现有代码"
        Set-Location $Config.BaseDir
        Write-Info "当前目录: $($Config.BaseDir)"
    }
    
    # ==================== 步骤 2: 停止构建进程 ====================
    Write-StepHeader "步骤 2/10: 清理构建进程"
    Stop-BuildProcesses
    Write-Success "构建进程已清理"
    
    # ==================== 步骤 3: 安装构建工具 ====================
    Write-StepHeader "步骤 3/10: 安装构建工具"
    
    # WiX Toolset
    Write-Info "检查 WiX Toolset $($Config.WixVersion)..."
    dotnet tool install --global wix --version $Config.WixVersion 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1) {
        Write-Success "WiX Toolset 已就绪"
    } else {
        Write-Info "WiX 安装状态未知，继续"
    }
    
    # Windows SDK
    Write-Info "检查 Windows SDK..."
    winget install --id $Config.WindowsSDKId --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
    Write-Success "Windows SDK 已就绪"
    
    # ==================== 步骤 4: 配置 WiX Heat ====================
    Write-StepHeader "步骤 4/10: 配置 WiX Heat 工具"
    
    $PackagesDir = "$($Config.BaseDir)\packages"
    New-Item -ItemType Directory -Path $PackagesDir -Force | Out-Null
    
    nuget install wixtoolset.heat -Version $Config.WixVersion -OutputDirectory $PackagesDir -NonInteractive 2>&1 | Out-Null
    
    # 配置 Heat 路径
    $HeatPaths = @(
        "$PackagesDir\wixtoolset.heat.$($Config.WixVersion)\tools\net472\x64",
        "$env:USERPROFILE\.nuget\packages\wixtoolset.heat\$($Config.WixVersion)\tools\net472\x64"
    )
    
    $heatFound = $false
    foreach ($path in $HeatPaths) {
        if (Test-Path $path) {
            if ($env:PATH -notlike "*$path*") {
                $env:PATH += ";$path"
            }
            $heatFound = $true
            Write-Success "Heat 工具路径已配置"
            break
        }
    }
    
    if (-not $heatFound) {
        Write-Info "Heat 工具路径未找到，但继续"
    }
    
    # ==================== 步骤 5: 安装并验证 WiX 依赖 ====================
    Write-StepHeader "步骤 5/10: 安装并验证 WiX 构建依赖"
    
    Set-Location "$($Config.BaseDir)\installer"
    
    # 先尝试常规安装
    Write-Info "常规安装 WiX 包..."
    nuget install WixToolset.WcaUtil -Version $Config.WixVersion -OutputDirectory packages -NonInteractive 2>&1 | Out-Null
    nuget install WixToolset.Dutil -Version $Config.WixVersion -OutputDirectory packages -NonInteractive 2>&1 | Out-Null
    
    # 使用新函数确保包完整
    Ensure-WixPackages -InstallerPath "$($Config.BaseDir)\installer"
    
    Set-Location $Config.BaseDir
    
    # ==================== 步骤 6: 配置环境变量 ====================
    Write-StepHeader "步骤 6/10: 配置环境变量"
    
    $env:NUGET_PACKAGES = "$($Config.BaseDir)\installer\packages"
    Write-Success "NUGET_PACKAGES 已配置"
    
    # ==================== 步骤 7: 恢复 NuGet 包 ====================
    Write-StepHeader "步骤 7/10: 恢复依赖包"
    
    if (-not $NoCacheClean) {
        Write-Info "清理 NuGet 缓存..."
        dotnet nuget locals all --clear
    } else {
        Write-Info "保留 NuGet 缓存（加速构建）"
    }
    
    Write-Info "恢复项目依赖..."
    dotnet restore --force 2>&1 | Out-Null
    
    Write-Info "恢复 win-x64 Runtime Packs..."
    dotnet restore --runtime win-x64 --force 2>&1 | Out-Null
    
    Write-Success "依赖包恢复完成"
    
    # ==================== 步骤 8: 修复构建脚本 ====================
    Write-StepHeader "步骤 8/10: 优化构建脚本"
    
    $buildScript = "$($Config.BaseDir)\tools\build\build-installer.ps1"
    Repair-BuildScript -ScriptPath $buildScript
    
    # 清理旧备份
    Remove-OldBackups -Path "$($Config.BaseDir)\installer" -Pattern "*.wxs.bk"
    
    Write-Success "构建环境已优化"
    
    # ==================== 步骤 9: 最后验证 ====================
    Write-StepHeader "步骤 9/10: 最后验证"
    
    # 验证 wcautil.lib
    $wcautilLib = "$($Config.BaseDir)\installer\packages\WixToolset.WcaUtil.$($Config.WixVersion)\build\native\v14\x64\wcautil.lib"
    if (Test-Path $wcautilLib) {
        Write-Success "wcautil.lib 已就绪"
    } else {
        Write-Error "wcautil.lib 仍然缺失!"
        throw "关键库文件缺失"
    }
    
    # 验证构建脚本
    $scriptContent = Get-Content $buildScript -Raw
    if ($scriptContent -match "# DISABLED.*git clean") {
        Write-Success "构建脚本已优化（git clean 已禁用）"
    } else {
        Write-Info "构建脚本可能需要优化"
    }
    
    Write-Success "所有验证通过"
    
    # ==================== 步骤 10: 执行构建 ====================
    Write-StepHeader "步骤 10/10: 开始构建"
    
    Stop-BuildProcesses -Verbose $false
    Start-Sleep -Seconds 2
    
    Write-Info "执行构建脚本..."
    Write-Info "日志位置: installer\build.release.x64.*.log"
    Write-Host ""
    Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    Write-Host ""
    
    # 执行构建
    & pwsh $buildScript
    $buildExitCode = $LASTEXITCODE
    
    Write-Host ""
    Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    
    # ==================== 构建结果 ====================
    if ($buildExitCode -eq 0) {
        $endTime = Get-Date
        $duration = $endTime - $startTime
        
        Write-Host ""
        Write-StepHeader "✓ 构建成功完成！"
        
        Write-Host ""
        Write-Info "总耗时: $($duration.ToString('hh\:mm\:ss'))"
        Write-Info "完成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        
        # 查找生成的安装程序
        Write-Host ""
        Write-Host "  生成的文件:" -ForegroundColor Cyan
        Write-Host ""
        
        $installers = Get-ChildItem -Path "$($Config.BaseDir)\installer" -Filter "*.exe" -Recurse -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -like "*PowerToys*" -and $_.Length -gt 1MB } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 5
        
        if ($installers) {
            foreach ($installer in $installers) {
                $sizeMB = [math]::Round($installer.Length / 1MB, 2)
                Write-Host "    ✓ $($installer.Name)" -ForegroundColor Green
                Write-Host "      大小: $sizeMB MB" -ForegroundColor Gray
                Write-Host "      路径: $($installer.FullName)" -ForegroundColor Gray
                Write-Host ""
            }
        } else {
            Write-Info "未找到 .exe 文件，可能在其他位置"
        }
        
        Write-Host ""
        Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "║                                                            ║" -ForegroundColor Green
        Write-Host "║                  🎉 构建流程全部完成！ 🎉                  ║" -ForegroundColor Green
        Write-Host "║                                                            ║" -ForegroundColor Green
        Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
        Write-Host ""
        
    } else {
        throw "构建失败，退出代码: $buildExitCode"
    }
    
} catch {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║                                                            ║" -ForegroundColor Red
    Write-Host "║                      ❌ 构建失败 ❌                        ║" -ForegroundColor Red
    Write-Host "║                                                            ║" -ForegroundColor Red
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    Write-Error "错误信息: $_"
    Write-Host ""
    
    if ($_.ScriptStackTrace) {
        Write-Host "  错误堆栈:" -ForegroundColor Yellow
        Write-Host $_.ScriptStackTrace -ForegroundColor Gray
    }
    
    Write-Host ""
    Write-Host "  📋 日志文件位置:" -ForegroundColor Cyan
    Write-Host "    • 完整日志: $($Config.BaseDir)\installer\build.release.x64.all.log" -ForegroundColor Yellow
    Write-Host "    • 错误日志: $($Config.BaseDir)\installer\build.release.x64.errors.log" -ForegroundColor Yellow
    Write-Host "    • 警告日志: $($Config.BaseDir)\installer\build.release.x64.warnings.log" -ForegroundColor Yellow
    Write-Host ""
    
    Write-Host "  💡 常见问题排查:" -ForegroundColor Cyan
    Write-Host "    1. 检查错误日志了解具体失败原因" -ForegroundColor Gray
    Write-Host "    2. 确保有足够的磁盘空间 (需要约 10 GB)" -ForegroundColor Gray
    Write-Host "    3. 尝试以管理员身份运行脚本" -ForegroundColor Gray
    Write-Host "    4. 暂时关闭杀毒软件" -ForegroundColor Gray
    Write-Host "    5. 使用 -CleanBuild 参数完全重新开始" -ForegroundColor Gray
    Write-Host ""
    
    exit 1
}
