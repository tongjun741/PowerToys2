[CmdletBinding()]
Param(
    [Parameter(Mandatory = $True, Position = 1)]
    [string]$platform
)

Function Generate-FileList() {
    [CmdletBinding()]
    Param(
        # Can be multiple files separated by ; as long as they're on the same directory
        [Parameter(Mandatory = $True, Position = 1)]
        [AllowEmptyString()]
        [string]$fileDepsJson,
        [Parameter(Mandatory = $True, Position = 2)]
        [string]$fileListName,
        [Parameter(Mandatory = $True, Position = 3)]
        [string]$wxsFilePath,
        # If there is no deps.json file, just pass path to files
        [Parameter(Mandatory = $False, Position = 4)]
        [string]$depsPath,
        # launcher plugins are being loaded into launcher process,
        # so there are some additional dependencies to skip
        [Parameter(Mandatory = $False, Position = 5)]
        [bool]$isLauncherPlugin
    )

    $fileWxs = Get-Content $wxsFilePath;

    $fileExclusionList = @("*.pdb", "*.lastcodeanalysissucceeded", "createdump.exe", "powertoys.exe")

    $fileInclusionList = @("*.dll", "*.exe", "*.json", "*.msix", "*.png", "*.gif", "*.ico", "*.cur", "*.svg", "index.html", "reg.js", "gitignore.js", "srt.js", "monacoSpecialLanguages.js", "customTokenThemeRules.js", "*.pri")

    $dllsToIgnore = @("System.CodeDom.dll", "WindowsBase.dll")

    if ($fileDepsJson -eq [string]::Empty) {
        $fileDepsRoot = $depsPath
    } else {
        $multipleDepsJson = $fileDepsJson.Split(";")

        foreach ( $singleDepsJson in $multipleDepsJson )
        {

            $fileDepsRoot = (Get-ChildItem $singleDepsJson).Directory.FullName
            $depsJson = Get-Content $singleDepsJson | ConvertFrom-Json

            $runtimeList = ([array]$depsJson.targets.PSObject.Properties)[-1].Value.PSObject.Properties | Where-Object {
                $_.Name -match "runtimepack.*Runtime"
            };

            $runtimeList | ForEach-Object {
                $_.Value.PSObject.Properties.Value | ForEach-Object {
                    $fileExclusionList += $_.PSObject.Properties.Name
                }
            }
        }
    }

    $fileExclusionList = $fileExclusionList | Where-Object {$_ -notin $dllsToIgnore}

    if ($isLauncherPlugin -eq $True) {
        $fileInclusionList += @("*.deps.json")
        $fileExclusionList += @("Ijwhost.dll", "PowerToys.Common.UI.dll", "PowerToys.GPOWrapper.dll", "PowerToys.GPOWrapperProjection.dll", "PowerToys.PowerLauncher.Telemetry.dll", "PowerToys.ManagedCommon.dll", "PowerToys.Settings.UI.Lib.dll", "Wox.Infrastructure.dll", "Wox.Plugin.dll")
    }

    if (-not (Test-Path $fileDepsRoot)) { Write-Warning "Path not found: $fileDepsRoot" ; $fileList = @() } else { $fileList = Get-ChildItem $fileDepsRoot -Include $fileInclusionList -Exclude $fileExclusionList -File -Name }

    $fileWxs = $fileWxs -replace "(<\?define $($fileListName)=)", "<?define $fileListName=$($fileList -join ';')"

    Set-Content -Path $wxsFilePath -Value $fileWxs
}

Function Generate-FileComponents() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True, Position = 1)]
        [string]$fileListName,
        [Parameter(Mandatory = $True, Position = 2)]
        [string]$wxsFilePath
    )

    $wxsFile = Get-Content $wxsFilePath;

    $wxsFile | ForEach-Object {
        if ($_ -match "(<?define $fileListName=)(.*)\?>") {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'fileList',
            Justification = 'variable is used in another scope')]

            $fileList = $matches[2] -split ';' | Where-Object { $_ -ne '' }
            return
        }
    }

    $componentId = "$($fileListName)_Component"

    $componentDefs = "`r`n"
    $componentDefs +=
    @"
            <Component Id="$($componentId)" Guid="$((New-Guid).ToString().ToUpper())">
              <RegistryKey Root="`$(var.RegistryScope)" Key="Software\Classes\powertoys\components">
                <RegistryValue Type="string" Name="$($componentId)" Value="" KeyPath="yes"/>
              </RegistryKey>`r`n
"@

    foreach ($file in $fileList) {
        $fileTmp = $file -replace "-", "_"
        $componentDefs +=
    @"
              <File Id="$($fileListName)_File_$($fileTmp)" Source="`$(var.$($fileListName)Path)\$($file)" />`r`n
"@
    }

    $componentDefs +=
    @"
            </Component>`r`n
"@

    $wxsFile = $wxsFile -replace "\s+(<!--$($fileListName)_Component_Def-->)", $componentDefs

    $componentRef =
    @"
            <ComponentRef Id="$($componentId)" />
"@

    $wxsFile = $wxsFile -replace "\s+(</ComponentGroup>)", "$componentRef`r`n    </ComponentGroup>"

    Set-Content -Path $wxsFilePath -Value $wxsFile
}

if ($platform -ceq "arm64") {
    $platform = "ARM64"
}

#BaseApplications
Generate-FileList -fileDepsJson "" -fileListName BaseApplicationsFiles -wxsFilePath $PSScriptRoot\BaseApplications.wxs -depsPath "$PSScriptRoot..\..\..\$platform\Release"
Generate-FileComponents -fileListName "BaseApplicationsFiles" -wxsFilePath $PSScriptRoot\BaseApplications.wxs

#WinUI3Applications
Generate-FileList -fileDepsJson "" -fileListName WinUI3ApplicationsFiles -wxsFilePath $PSScriptRoot\WinUI3Applications.wxs -depsPath "$PSScriptRoot..\..\..\$platform\Release\WinUI3Apps"
Generate-FileComponents -fileListName "WinUI3ApplicationsFiles" -wxsFilePath $PSScriptRoot\WinUI3Applications.wxs

#Settings
Generate-FileList -fileDepsJson "" -fileListName SettingsV2AssetsFiles -wxsFilePath $PSScriptRoot\Settings.wxs -depsPath "$PSScriptRoot..\..\..\$platform\Release\WinUI3Apps\Assets\Settings\"
Generate-FileList -fileDepsJson "" -fileListName SettingsV2AssetsModulesFiles -wxsFilePath $PSScriptRoot\Settings.wxs -depsPath "$PSScriptRoot..\..\..\$platform\Release\WinUI3Apps\Assets\Settings\Modules\"
Generate-FileList -fileDepsJson "" -fileListName SettingsV2OOBEAssetsModulesFiles -wxsFilePath $PSScriptRoot\Settings.wxs -depsPath "$PSScriptRoot..\..\..\$platform\Release\WinUI3Apps\Assets\Settings\Modules\OOBE\"
Generate-FileList -fileDepsJson "" -fileListName SettingsV2OOBEAssetsFluentIconsFiles -wxsFilePath $PSScriptRoot\Settings.wxs -depsPath "$PSScriptRoot..\..\..\$platform\Release\WinUI3Apps\Assets\Settings\Icons\"
Generate-FileComponents -fileListName "SettingsV2AssetsFiles" -wxsFilePath $PSScriptRoot\Settings.wxs
Generate-FileComponents -fileListName "SettingsV2AssetsModulesFiles" -wxsFilePath $PSScriptRoot\Settings.wxs
Generate-FileComponents -fileListName "SettingsV2OOBEAssetsModulesFiles" -wxsFilePath $PSScriptRoot\Settings.wxs
Generate-FileComponents -fileListName "SettingsV2OOBEAssetsFluentIconsFiles" -wxsFilePath $PSScriptRoot\Settings.wxs

exit 0
