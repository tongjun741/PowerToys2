#include "pch.h"
#include "resource.h"
#include "RcResource.h"
#include <spdlog/sinks/base_sink.h>
#include <filesystem>
#include <string_view>

#include "../../src/common/logger/logger.h"
#include "../../src/common/utils/gpo.h"
#include "../../src/common/utils/MsiUtils.h"
#include "../../src/common/version/version.h"
#include "../../src/common/utils/package.h"

#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Management.Deployment.h>
#include <winrt/Windows.Security.Credentials.h>

#include <wtsapi32.h>
#include <processthreadsapi.h>
#include <UserEnv.h>
#include <winnt.h>

using namespace std;

HINSTANCE DLL_HANDLE = nullptr;

HRESULT getInstallFolder(MSIHANDLE hInstall, std::wstring &installationDir)
{
    DWORD len = 0;
    wchar_t _[1];
    MsiGetPropertyW(hInstall, L"CustomActionData", _, &len);
    len += 1;
    installationDir.resize(len);
    HRESULT hr = MsiGetPropertyW(hInstall, L"CustomActionData", installationDir.data(), &len);
    if (installationDir.length())
    {
        installationDir.resize(installationDir.length() - 1);
    }
    ExitOnFailure(hr, "Failed to get INSTALLFOLDER property.");
LExit:
    return hr;
}

BOOL IsLocalSystem()
{
    HANDLE hToken;
    UCHAR bTokenUser[sizeof(TOKEN_USER) + 8 + 4 * SID_MAX_SUB_AUTHORITIES];
    PTOKEN_USER pTokenUser = (PTOKEN_USER)bTokenUser;
    ULONG cbTokenUser;
    SID_IDENTIFIER_AUTHORITY siaNT = SECURITY_NT_AUTHORITY;
    PSID pSystemSid;
    BOOL bSystem;

    // open process token
    if (!OpenProcessToken(GetCurrentProcess(),
                          TOKEN_QUERY,
                          &hToken))
        return FALSE;

    // retrieve user SID
    if (!GetTokenInformation(hToken, TokenUser, pTokenUser,
                             sizeof(bTokenUser), &cbTokenUser))
    {
        CloseHandle(hToken);
        return FALSE;
    }

    CloseHandle(hToken);

    // allocate LocalSystem well-known SID
    if (!AllocateAndInitializeSid(&siaNT, 1, SECURITY_LOCAL_SYSTEM_RID,
                                  0, 0, 0, 0, 0, 0, 0, &pSystemSid))
        return FALSE;

    // compare the user SID from the token with the LocalSystem SID
    bSystem = EqualSid(pTokenUser->User.Sid, pSystemSid);

    FreeSid(pSystemSid);

    return bSystem;
}

BOOL ImpersonateLoggedInUserAndDoSomething(std::function<bool(HANDLE userToken)> action)
{
    HRESULT hr = S_OK;
    HANDLE hUserToken = NULL;
    DWORD dwSessionId;
    ProcessIdToSessionId(GetCurrentProcessId(), &dwSessionId);
    auto rv = WTSQueryUserToken(dwSessionId, &hUserToken);

    if (rv == 0)
    {
        hr = E_ABORT;
        ExitOnFailure(hr, "Failed to query user token");
    }

    HANDLE hUserTokenDup;
    if (DuplicateTokenEx(hUserToken, TOKEN_ALL_ACCESS, NULL, SECURITY_IMPERSONATION_LEVEL::SecurityImpersonation, TOKEN_TYPE::TokenPrimary, &hUserTokenDup) == 0)
    {
        CloseHandle(hUserToken);
        CloseHandle(hUserTokenDup);
        hr = E_ABORT;
        ExitOnFailure(hr, "Failed to duplicate user token");
    }

    if (ImpersonateLoggedOnUser(hUserTokenDup))
    {
        if (!action(hUserTokenDup))
        {
            hr = E_ABORT;
            ExitOnFailure(hr, "Failed to execute action");
        }

        RevertToSelf();
        CloseHandle(hUserToken);
        CloseHandle(hUserTokenDup);
    }
    else
    {
        hr = E_ABORT;
        ExitOnFailure(hr, "Failed to duplicate user token");
    }

LExit:
    return SUCCEEDED(hr);
}

static std::filesystem::path GetUserPowerShellModulesPath()
{
    PWSTR myDocumentsBlockPtr;

    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Documents, 0, NULL, &myDocumentsBlockPtr)))
    {
        const std::wstring myDocuments{myDocumentsBlockPtr};
        CoTaskMemFree(myDocumentsBlockPtr);
        return std::filesystem::path(myDocuments) / "PowerShell" / "Modules";
    }
    else
    {
        CoTaskMemFree(myDocumentsBlockPtr);
        return {};
    }
}

UINT __stdcall LaunchPowerToysCA(MSIHANDLE hInstall)
{
    HRESULT hr = S_OK;
    UINT er = ERROR_SUCCESS;
    std::wstring installationFolder, path, args;
    std::wstring commandLine;

    hr = WcaInitialize(hInstall, "LaunchPowerToys");
    ExitOnFailure(hr, "Failed to initialize");
    hr = getInstallFolder(hInstall, installationFolder);
    ExitOnFailure(hr, "Failed to get installFolder.");

    path = installationFolder;
    path += L"\\PowerToys.exe";

    args = L"--dont-elevate";

    commandLine = L"\"" + path + L"\" ";
    commandLine += args;

    BOOL isSystemUser = IsLocalSystem();

    if (isSystemUser)
    {

        auto action = [&commandLine](HANDLE userToken)
        {
            STARTUPINFO startupInfo = { 0 };
            startupInfo.cb = sizeof(STARTUPINFO);
            startupInfo.wShowWindow = SW_SHOWNORMAL;
            PROCESS_INFORMATION processInformation;

            PVOID lpEnvironment = NULL;
            CreateEnvironmentBlock(&lpEnvironment, userToken, FALSE);

            CreateProcessAsUser(
                userToken,
                NULL,
                commandLine.data(),
                NULL,
                NULL,
                FALSE,
                CREATE_DEFAULT_ERROR_MODE | CREATE_UNICODE_ENVIRONMENT,
                lpEnvironment,
                NULL,
                &startupInfo,
                &processInformation);

            if (!CloseHandle(processInformation.hProcess))
            {
                return false;
            }
            if (!CloseHandle(processInformation.hThread))
            {
                return false;
            }

            return true;
        };

        if (!ImpersonateLoggedInUserAndDoSomething(action))
        {
            hr = E_ABORT;
            ExitOnFailure(hr, "ImpersonateLoggedInUserAndDoSomething failed");
        }
    }
    else
    {
        STARTUPINFO startupInfo = { 0 };
        startupInfo.cb = sizeof(STARTUPINFO);
        startupInfo.wShowWindow = SW_SHOWNORMAL;

        PROCESS_INFORMATION processInformation;

        // Start the resizer
        CreateProcess(
            NULL,
            commandLine.data(),
            NULL,
            NULL,
            TRUE,
            0,
            NULL,
            NULL,
            &startupInfo,
            &processInformation);

        if (!CloseHandle(processInformation.hProcess))
        {
            hr = E_ABORT;
            ExitOnFailure(hr, "Failed to close process handle");
        }
        if (!CloseHandle(processInformation.hThread))
        {
            hr = E_ABORT;
            ExitOnFailure(hr, "Failed to close thread handle");
        }
    }

LExit:
    er = SUCCEEDED(hr) ? ERROR_SUCCESS : ERROR_INSTALL_FAILURE;
    return WcaFinalize(er);
}

UINT __stdcall CheckGPOCA(MSIHANDLE hInstall)
{
    HRESULT hr = S_OK;

    hr = WcaInitialize(hInstall, "CheckGPOCA");
    ExitOnFailure(hr, "Failed to initialize");

    LPWSTR currentScope = nullptr;
    hr = WcaGetProperty(L"InstallScope", &currentScope);

    if (std::wstring{currentScope} == L"perUser")
    {
        if (powertoys_gpo::getDisablePerUserInstallationValue() == powertoys_gpo::gpo_rule_configured_enabled)
        {
            PMSIHANDLE hRecord = MsiCreateRecord(0);
            MsiRecordSetString(hRecord, 0, TEXT("The system administrator has disabled per-user installation."));
            MsiProcessMessage(hInstall, static_cast<INSTALLMESSAGE>(INSTALLMESSAGE_ERROR + MB_OK), hRecord);
            hr = E_ABORT;
        }
    }

LExit:
    UINT er = SUCCEEDED(hr) ? ERROR_SUCCESS : ERROR_INSTALL_FAILURE;
    return WcaFinalize(er);
}

// We've deprecated Video Conference Mute. This Custom Action cleans up any stray registry entry for the driver dll.
const wchar_t *DSC_CONFIGURE_PSD1_NAME = L"Microsoft.PowerToys.Configure.psd1";
const wchar_t *DSC_CONFIGURE_PSM1_NAME = L"Microsoft.PowerToys.Configure.psm1";

UINT __stdcall InstallPackageIdentityMSIXCA(MSIHANDLE hInstall)
{
    HRESULT hr = S_OK;
    UINT er = ERROR_SUCCESS;
    LPWSTR customActionData = nullptr;
    std::wstring installFolderPath;
    std::wstring installScope;
    std::wstring msixPath;
    std::wstring data;
    size_t delimiterPos;
    bool isMachineLevel = false;
    
    hr = WcaInitialize(hInstall, "InstallPackageIdentityMSIXCA");
    ExitOnFailure(hr, "Failed to initialize");

    hr = WcaGetProperty(L"CustomActionData", &customActionData);
    ExitOnFailure(hr, "Failed to get CustomActionData property");
    
    // Parse CustomActionData: "[INSTALLFOLDER];[InstallScope]"
    data = customActionData;
    delimiterPos = data.find(L';');
    installFolderPath = data.substr(0, delimiterPos);
    installScope = data.substr(delimiterPos + 1);
    
    // Check if this is a machine-level installation
    if (installScope == L"perMachine")
    {
        isMachineLevel = true;
    }
    
    Logger::info(L"Installing PackageIdentity MSIX - perUser: {}", !isMachineLevel);

    // Construct path to PackageIdentity MSIX
    msixPath = installFolderPath;
    msixPath += L"PowerToysSparse.msix";

    if (std::filesystem::exists(msixPath))
    {
        using namespace winrt::Windows::Management::Deployment;
        using namespace winrt::Windows::Foundation;

        try
        {
            
            std::wstring externalLocation = installFolderPath; // External content location (PowerToys install folder)
            Uri externalUri{ externalLocation };               // External location URI for sparse package content
            Uri packageUri{ msixPath };                        // The MSIX file URI
            
            PackageManager packageManager;
            
            if (isMachineLevel)
            {
                // Machine-level installation
                
                StagePackageOptions stageOptions;
                stageOptions.ExternalLocationUri(externalUri);
                
                auto stageResult = packageManager.StagePackageByUriAsync(packageUri, stageOptions).get();
                
                uint32_t stageErrorCode = static_cast<uint32_t>(stageResult.ExtendedErrorCode());
                if (stageErrorCode == 0)
                {
                    std::wstring packageFamilyName = L"Microsoft.PowerToys.SparseApp_8wekyb3d8bbwe";
                    
                    try
                    {
                        auto provisionResult = packageManager.ProvisionPackageForAllUsersAsync(packageFamilyName).get();
                        uint32_t provisionErrorCode = static_cast<uint32_t>(provisionResult.ExtendedErrorCode());
                        
                        if (provisionErrorCode != 0)
                        {
                            Logger::error(L"Machine-level provisioning failed: 0x{:08X}", provisionErrorCode);
                        }
                    }
                    catch (const winrt::hresult_error& ex)
                    {
                        Logger::error(L"Provisioning exception: HRESULT 0x{:08X}", static_cast<uint32_t>(ex.code()));
                    }
                }
                else
                {
                    Logger::error(L"Package staging failed: 0x{:08X}", stageErrorCode);
                }
            }
            else
            {
                AddPackageOptions addOptions;
                addOptions.ExternalLocationUri(externalUri);
                
                auto addResult = packageManager.AddPackageByUriAsync(packageUri, addOptions).get();
                
                if (!addResult.IsRegistered())
                {
                    uint32_t errorCode = static_cast<uint32_t>(addResult.ExtendedErrorCode());
                    Logger::error(L"Per-user installation failed: 0x{:08X}", errorCode);
                }
            }
        }
        catch (const std::exception& ex)
        {
            Logger::error(L"PackageIdentity MSIX installation failed - Exception: {}", 
                         winrt::to_hstring(ex.what()).c_str());
        }
    }
    else
    {
        Logger::error(L"PackageIdentity MSIX not found: " + msixPath);
    }

LExit:
    ReleaseStr(customActionData);
    er = SUCCEEDED(hr) ? ERROR_SUCCESS : ERROR_INSTALL_FAILURE;
    return WcaFinalize(er);
}

UINT __stdcall UninstallPackageIdentityMSIXCA(MSIHANDLE hInstall)
{
    HRESULT hr = S_OK;
    UINT er = ERROR_SUCCESS;
    using namespace winrt::Windows::Management::Deployment; 
    using namespace winrt::Windows::Foundation;
    
    LPWSTR installScope = nullptr;
    bool isMachineLevel = false;
    
    PackageManager pm;

    hr = WcaInitialize(hInstall, "UninstallPackageIdentityMSIXCA");
    ExitOnFailure(hr, "Failed to initialize");
    
    // Check if this was a machine-level installation
    hr = WcaGetProperty(L"InstallScope", &installScope);
    if (SUCCEEDED(hr) && installScope && wcscmp(installScope, L"perMachine") == 0)
    {
        isMachineLevel = true;
    }
    
    Logger::info(L"Uninstalling PackageIdentity MSIX - perUser: {}", !isMachineLevel);

    try
    {
        std::wstring packageFamilyName = L"Microsoft.PowerToys.SparseApp_8wekyb3d8bbwe";
        
        if (isMachineLevel)
        {
            // Machine-level uninstallation: deprovision + remove for all users
            
            // First deprovision the package
            try
            {
                auto deprovisionResult = pm.DeprovisionPackageForAllUsersAsync(packageFamilyName).get();
                if (deprovisionResult.IsRegistered())
                {
                    Logger::warn(L"Machine-level deprovisioning completed with warnings");
                }
            }
            catch (const winrt::hresult_error& ex)
            {
                Logger::warn(L"Machine-level deprovisioning failed: HRESULT 0x{:08X}", static_cast<uint32_t>(ex.code()));
            }
            
            // Then remove packages for all users
            auto packages = pm.FindPackagesForUserWithPackageTypes({}, packageFamilyName, PackageTypes::Main);
            for (const auto& package : packages)
            {
                try
                {
                    auto machineResult = pm.RemovePackageAsync(package.Id().FullName(), RemovalOptions::RemoveForAllUsers).get();
                    if (machineResult.IsRegistered())
                    {
                        uint32_t errorCode = static_cast<uint32_t>(machineResult.ExtendedErrorCode());
                        Logger::error(L"Machine-level removal failed: 0x{:08X} - {}", errorCode, machineResult.ErrorText());
                    }
                }
                catch (const winrt::hresult_error& ex)
                {
                    Logger::error(L"Machine-level removal exception: HRESULT 0x{:08X}", static_cast<uint32_t>(ex.code()));
                }
            }
        }
        else
        {
            // Per-user uninstallation: standard removal
            
            auto packages = pm.FindPackagesForUserWithPackageTypes({}, packageFamilyName, PackageTypes::Main);
            for (const auto& package : packages)
            {
                auto userResult = pm.RemovePackageAsync(package.Id().FullName()).get();
                if (userResult.IsRegistered())
                {
                    uint32_t errorCode = static_cast<uint32_t>(userResult.ExtendedErrorCode());
                    Logger::error(L"Per-user removal failed: 0x{:08X} - {}", errorCode, userResult.ErrorText());
                }
            }
        }
    }
    catch (const std::exception& ex)
    {
        std::string errorMsg = "Failed to uninstall PackageIdentity MSIX: " + std::string(ex.what());
        Logger::error(errorMsg);
        // Don't fail the entire uninstallation if PackageIdentity fails
        Logger::warn(L"Continuing uninstallation despite PackageIdentity MSIX error");
    }

LExit:
    ReleaseStr(installScope);
    er = SUCCEEDED(hr) ? ERROR_SUCCESS : ERROR_INSTALL_FAILURE;
    return WcaFinalize(er);
}

// Removes all Scheduled Tasks in the PowerToys folder and deletes the folder afterwards.
// Based on the Task Scheduler Displaying Task Names and State example:
// https://learn.microsoft.com/windows/desktop/TaskSchd/displaying-task-names-and-state--c---/
UINT __stdcall DetectPrevInstallPathCA(MSIHANDLE hInstall)
{
    HRESULT hr = S_OK;
    UINT er = ERROR_SUCCESS;
    hr = WcaInitialize(hInstall, "DetectPrevInstallPathCA");
    MsiSetPropertyW(hInstall, L"PREVIOUSINSTALLFOLDER", L"");

    LPWSTR currentScope = nullptr;
    hr = WcaGetProperty(L"InstallScope", &currentScope);

    try
    {
        if (auto install_path = GetMsiPackageInstalledPath(std::wstring{currentScope} == L"perUser"))
        {
            MsiSetPropertyW(hInstall, L"PREVIOUSINSTALLFOLDER", install_path->data());
        }
    }
    catch (...)
    {
    }
    er = SUCCEEDED(hr) ? ERROR_SUCCESS : ERROR_INSTALL_FAILURE;
    return WcaFinalize(er);
}



UINT __stdcall TerminateProcessesCA(MSIHANDLE hInstall)
{
    HRESULT hr = S_OK;
    UINT er = ERROR_SUCCESS;
    hr = WcaInitialize(hInstall, "TerminateProcessesCA");

    std::vector<DWORD> processes;
    const size_t maxProcesses = 4096;
    DWORD bytes = maxProcesses * sizeof(processes[0]);
    processes.resize(maxProcesses);

    if (!EnumProcesses(processes.data(), bytes, &bytes))
    {
        return 1;
    }
    processes.resize(bytes / sizeof(processes[0]));

    std::array<std::wstring_view, 42> processesToTerminate = {
        L"PowerToys.PowerLauncher.exe",
        L"PowerToys.Settings.exe",
        L"PowerToys.AdvancedPaste.exe",
        L"PowerToys.Awake.exe",
        L"PowerToys.FancyZones.exe",
        L"PowerToys.FancyZonesEditor.exe",
        L"PowerToys.FileLocksmithUI.exe",
        L"PowerToys.MouseJumpUI.exe",
        L"PowerToys.ColorPickerUI.exe",
        L"PowerToys.AlwaysOnTop.exe",
        L"PowerToys.RegistryPreview.exe",
        L"PowerToys.Hosts.exe",
        L"PowerToys.PowerRename.exe",
        L"PowerToys.ImageResizer.exe",
        L"PowerToys.LightSwitchService.exe",
        L"PowerToys.GcodeThumbnailProvider.exe",
        L"PowerToys.BgcodeThumbnailProvider.exe",
        L"PowerToys.PdfThumbnailProvider.exe",
        L"PowerToys.MonacoPreviewHandler.exe",
        L"PowerToys.MarkdownPreviewHandler.exe",
        L"PowerToys.StlThumbnailProvider.exe",
        L"PowerToys.SvgThumbnailProvider.exe",
        L"PowerToys.GcodePreviewHandler.exe",
        L"PowerToys.BgcodePreviewHandler.exe",
        L"PowerToys.QoiPreviewHandler.exe",
        L"PowerToys.PdfPreviewHandler.exe",
        L"PowerToys.QoiThumbnailProvider.exe",
        L"PowerToys.SvgPreviewHandler.exe",
        L"PowerToys.Peek.UI.exe",
        L"PowerToys.MouseWithoutBorders.exe",
        L"PowerToys.MouseWithoutBordersHelper.exe",
        L"PowerToys.MouseWithoutBordersService.exe",
        L"PowerToys.CropAndLock.exe",
        L"PowerToys.EnvironmentVariables.exe",
        L"PowerToys.WorkspacesSnapshotTool.exe",
        L"PowerToys.WorkspacesLauncher.exe",
        L"PowerToys.WorkspacesLauncherUI.exe",
        L"PowerToys.WorkspacesEditor.exe",
        L"PowerToys.WorkspacesWindowArranger.exe",
        L"Microsoft.CmdPal.UI.exe",
        L"PowerToys.ZoomIt.exe",
        L"PowerToys.exe",
    };

    for (const auto procID : processes)
    {
        if (!procID)
        {
            continue;
        }
        wchar_t processName[MAX_PATH] = L"<unknown>";

        HANDLE hProcess{OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ | PROCESS_TERMINATE, FALSE, procID)};
        if (!hProcess)
        {
            continue;
        }
        HMODULE hMod;
        DWORD cbNeeded;

        if (!EnumProcessModules(hProcess, &hMod, sizeof(hMod), &cbNeeded))
        {
            CloseHandle(hProcess);
            continue;
        }
        GetModuleBaseNameW(hProcess, hMod, processName, sizeof(processName) / sizeof(wchar_t));

        for (const auto processToTerminate : processesToTerminate)
        {
            if (processName == processToTerminate)
            {
                const DWORD timeout = 500;
                auto windowEnumerator = [](HWND hwnd, LPARAM procIDPtr) -> BOOL
                {
                    auto targetProcID = *reinterpret_cast<const DWORD *>(procIDPtr);
                    DWORD windowProcID = 0;
                    GetWindowThreadProcessId(hwnd, &windowProcID);
                    if (windowProcID == targetProcID)
                    {
                        DWORD_PTR _{};
                        SendMessageTimeoutA(hwnd, WM_CLOSE, 0, 0, SMTO_BLOCK, timeout, &_);
                    }
                    return TRUE;
                };
                EnumWindows(windowEnumerator, reinterpret_cast<LPARAM>(&procID));
                Sleep(timeout);
                TerminateProcess(hProcess, 0);
                break;
            }
        }
        CloseHandle(hProcess);
    }

    er = SUCCEEDED(hr) ? ERROR_SUCCESS : ERROR_INSTALL_FAILURE;
    return WcaFinalize(er);
}

UINT __stdcall SetBundleInstallLocationCA(MSIHANDLE hInstall)
{
    HRESULT hr = S_OK;
    UINT er = ERROR_SUCCESS;
    
    // Declare all variables at the beginning to avoid goto issues
    std::wstring customActionData;
    std::wstring installationFolder;
    std::wstring bundleUpgradeCode;
    std::wstring installScope;
    bool isPerUser = false;
    size_t pos1 = std::wstring::npos;
    size_t pos2 = std::wstring::npos;
    std::vector<HKEY> keysToTry;

    hr = WcaInitialize(hInstall, "SetBundleInstallLocationCA");
    ExitOnFailure(hr, "Failed to initialize");
    
    // Parse CustomActionData: "installFolder;upgradeCode;installScope"
    hr = getInstallFolder(hInstall, customActionData);
    ExitOnFailure(hr, "Failed to get CustomActionData.");
    
    pos1 = customActionData.find(L';');
    if (pos1 == std::wstring::npos) 
    {
        hr = E_INVALIDARG;
        ExitOnFailure(hr, "Invalid CustomActionData format - missing first semicolon");
    }
    
    pos2 = customActionData.find(L';', pos1 + 1);
    if (pos2 == std::wstring::npos) 
    {
        hr = E_INVALIDARG;
        ExitOnFailure(hr, "Invalid CustomActionData format - missing second semicolon");
    }
    
    installationFolder = customActionData.substr(0, pos1);
    bundleUpgradeCode = customActionData.substr(pos1 + 1, pos2 - pos1 - 1);
    installScope = customActionData.substr(pos2 + 1);
    
    isPerUser = (installScope == L"perUser");
    
    // Use the appropriate registry based on install scope
    HKEY targetKey = isPerUser ? HKEY_CURRENT_USER : HKEY_LOCAL_MACHINE;
    const wchar_t* keyName = isPerUser ? L"HKCU" : L"HKLM";
    
    WcaLog(LOGMSG_STANDARD, "SetBundleInstallLocationCA: Searching for Bundle in %ls registry", keyName);
    
    HKEY uninstallKey;
    LONG openResult = RegOpenKeyExW(targetKey, L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall", 0, KEY_READ | KEY_ENUMERATE_SUB_KEYS, &uninstallKey);
    if (openResult != ERROR_SUCCESS)
    {
        WcaLog(LOGMSG_STANDARD, "SetBundleInstallLocationCA: Failed to open uninstall key, error: %ld", openResult);
        goto LExit;
    }
    
    DWORD index = 0;
    wchar_t subKeyName[256];
    DWORD subKeyNameSize = sizeof(subKeyName) / sizeof(wchar_t);
    
    while (RegEnumKeyExW(uninstallKey, index, subKeyName, &subKeyNameSize, nullptr, nullptr, nullptr, nullptr) == ERROR_SUCCESS)
    {
        HKEY productKey;
        if (RegOpenKeyExW(uninstallKey, subKeyName, 0, KEY_READ | KEY_WRITE, &productKey) == ERROR_SUCCESS)
        {
            wchar_t upgradeCode[256];
            DWORD upgradeCodeSize = sizeof(upgradeCode);
            DWORD valueType;
            
            if (RegQueryValueExW(productKey, L"BundleUpgradeCode", nullptr, &valueType, 
                               reinterpret_cast<LPBYTE>(upgradeCode), &upgradeCodeSize) == ERROR_SUCCESS)
            {
                // Remove brackets from registry upgradeCode for comparison (bundleUpgradeCode doesn't have brackets)
                std::wstring regUpgradeCode = upgradeCode;
                if (!regUpgradeCode.empty() && regUpgradeCode.front() == L'{' && regUpgradeCode.back() == L'}')
                {
                    regUpgradeCode = regUpgradeCode.substr(1, regUpgradeCode.length() - 2);
                }
                
                if (_wcsicmp(regUpgradeCode.c_str(), bundleUpgradeCode.c_str()) == 0)
                {
                    // Found matching Bundle, set InstallLocation
                    LONG setResult = RegSetValueExW(productKey, L"InstallLocation", 0, REG_SZ,
                                 reinterpret_cast<const BYTE*>(installationFolder.c_str()),
                                 static_cast<DWORD>((installationFolder.length() + 1) * sizeof(wchar_t)));
                    
                    if (setResult == ERROR_SUCCESS)
                    {
                        WcaLog(LOGMSG_STANDARD, "SetBundleInstallLocationCA: InstallLocation set successfully");
                    }
                    else
                    {
                        WcaLog(LOGMSG_STANDARD, "SetBundleInstallLocationCA: Failed to set InstallLocation, error: %ld", setResult);
                    }
                    
                    RegCloseKey(productKey);
                    RegCloseKey(uninstallKey);
                    goto LExit;
                }
            }
            RegCloseKey(productKey);
        }
        
        index++;
        subKeyNameSize = sizeof(subKeyName) / sizeof(wchar_t);
    }
    
    RegCloseKey(uninstallKey);
    
LExit:
    er = SUCCEEDED(hr) ? ERROR_SUCCESS : ERROR_INSTALL_FAILURE;
    return WcaFinalize(er);
}

void initSystemLogger()
{
    static std::once_flag initLoggerFlag;
    std::call_once(initLoggerFlag, []()
                   {
            WCHAR temp_path[MAX_PATH];
            auto ret = GetTempPath(MAX_PATH, temp_path);

            if (ret)
            {
                Logger::init("PowerToysMSI", std::wstring{ temp_path } + L"\\PowerToysMSIInstaller", L"");
            } });
}

// DllMain - Initialize and cleanup WiX custom action utils.
extern "C" BOOL WINAPI DllMain(__in HINSTANCE hInst, __in ULONG ulReason, __in LPVOID)
{
    switch (ulReason)
    {
    case DLL_PROCESS_ATTACH:
        WcaGlobalInitialize(hInst);
        initSystemLogger();
        DLL_HANDLE = hInst;
        break;

    case DLL_PROCESS_DETACH:
        WcaGlobalFinalize();
        break;
    }

    return TRUE;
}
