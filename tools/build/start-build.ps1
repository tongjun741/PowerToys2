# Enable strict error handling
$ErrorActionPreference = "Stop"

# Define base directory
$BaseDir = "D:\PowerToys2"

try {
    # Clone repository
    Write-Host "Cloning PowerToys2 repository..." -ForegroundColor Cyan
    Set-Location "D:\"
    
    if (Test-Path $BaseDir) {
        Write-Host "Directory already exists. Removing..." -ForegroundColor Yellow
        Remove-Item $BaseDir -Recurse -Force
    }
    
    git clone https://github.com/tongjun741/PowerToys2.git
    Set-Location $BaseDir
    
    Write-Host "Updating submodules..." -ForegroundColor Cyan
    git submodule update --init --recursive
    
    # Install WiX Toolset
    Write-Host "Installing WiX Toolset 5.0.2..." -ForegroundColor Cyan
    dotnet tool install --global wix --version 5.0.2 --no-cache
    
    # Install Windows SDK
    Write-Host "Installing Windows SDK..." -ForegroundColor Cyan
    winget install --id Microsoft.WindowsSDK.10.0.19041 --silent --accept-package-agreements --accept-source-agreements
    
    # Install WiX Heat via NuGet
    Write-Host "Installing WiX Heat tool..." -ForegroundColor Cyan
    $PackagesDir = "$BaseDir\packages"
    New-Item -ItemType Directory -Path $PackagesDir -Force | Out-Null
    nuget install wixtoolset.heat -Version 5.0.2 -OutputDirectory $PackagesDir
    
    # Add Heat to PATH
    $HeatPath = "$PackagesDir\wixtoolset.heat.5.0.2\tools\net472\x64"
    
    if (Test-Path $HeatPath) {
        $env:PATH += ";$HeatPath"
        Write-Host "Added Heat to PATH: $HeatPath" -ForegroundColor Green
    } else {
        Write-Warning "Heat path not found: $HeatPath"
        # Alternative path (user profile)
        $AltHeatPath = "$env:USERPROFILE\.nuget\packages\wixtoolset.heat\5.0.2\tools\net472\x64"
        if (Test-Path $AltHeatPath) {
            $env:PATH += ";$AltHeatPath"
            Write-Host "Using alternative Heat path: $AltHeatPath" -ForegroundColor Green
        }
    }
    
    # Verify Heat installation
    Write-Host "`nVerifying Heat installation..." -ForegroundColor Cyan
    $heatResult = heat.exe -? 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Heat is accessible" -ForegroundColor Green
    } else {
        Write-Warning "Heat verification failed"
    }
    
    # Set NuGet packages directory
    $env:NUGET_PACKAGES = "$BaseDir\installer\packages"
    Write-Host "NuGet packages directory: $env:NUGET_PACKAGES" -ForegroundColor Cyan
    
    # Restore dependencies
    Write-Host "`nRestoring NuGet packages..." -ForegroundColor Cyan
    dotnet restore
    
    # Build installer
    Write-Host "`nBuilding PowerToys installer..." -ForegroundColor Cyan
    $BuildScript = "$BaseDir\tools\build\build-installer.ps1"
    
    if (Test-Path $BuildScript) {
        pwsh $BuildScript
        Write-Host "`n✓ Build completed successfully!" -ForegroundColor Green
    } else {
        Write-Error "Build script not found: $BuildScript"
    }
    
} catch {
    Write-Host "`n✗ Error occurred: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}