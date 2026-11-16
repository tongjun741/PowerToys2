// Copyright (c) Microsoft Corporation
// The Microsoft Corporation licenses this file to you under the MIT license.
// See the LICENSE file in the project root for more information.

using System.Diagnostics;
using System.IO;

namespace Common.UI
{
    public static class SettingsDeepLink
    {
        public enum SettingsWindow
        {
            Dashboard = 0,
            Overview,
            KBM,
        }

        private static string SettingsWindowNameToString(SettingsWindow value)
        {
            switch (value)
            {
                case SettingsWindow.Dashboard:
                    return "Dashboard";
                case SettingsWindow.Overview:
                    return "Overview";
                case SettingsWindow.KBM:
                    return "KBM";
                default:
                    {
                        return string.Empty;
                    }
            }
        }

        public static void OpenSettings(SettingsWindow window, bool mainExecutableIsOnTheParentFolder)
        {
            try
            {
                var directoryPath = System.AppContext.BaseDirectory;
                if (mainExecutableIsOnTheParentFolder)
                {
                    // Need to go into parent folder for PowerToys.exe. Likely a WinUI3 App SDK application.
                    directoryPath = Path.Combine(directoryPath, "..");
                    directoryPath = Path.Combine(directoryPath, "PowerToys.exe");
                }
                else
                {
                    // PowerToys.exe is in the same path as the application.
                    directoryPath = Path.Combine(directoryPath, "PowerToys.exe");
                }

                Process.Start(new ProcessStartInfo(directoryPath) { Arguments = "--open-settings=" + SettingsWindowNameToString(window) });
            }
            catch
            {
                // TODO(stefan): Log exception once unified logging is implemented
            }
        }
    }
}
