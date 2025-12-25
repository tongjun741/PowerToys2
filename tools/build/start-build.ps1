d:
git clone https://github.com/tongjun741/PowerToys2.git
cd PowerToys2
git submodule update --init --recursive
 
dotnet tool install --global wix --version 5.0.2
winget install --id Microsoft.WindowsSDK.10.0.19041 --silent --accept-package-agreements --accept-source-agreements
  
# choco install wixtoolset -y
nuget install wixtoolset.heat -Version 5.0.2 -OutputDirectory D:\PowerToys2\packages
  
# 方式1：直接追加到当前会话的PATH
$env:PATH += ";C:\Users\runneradmin\.nuget\packages\wixtoolset.heat\5.0.2\tools\net472\x64"

# 验证：执行heat.exe -? 看是否能输出帮助（无"找不到文件"错误即成功）
heat.exe -?
# 恢复 NuGet 包
dotnet restore
pwsh D:\PowerToys2\tools\build\build-installer.ps1