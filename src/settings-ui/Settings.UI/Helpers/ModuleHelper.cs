// Copyright (c) Microsoft Corporation
// The Microsoft Corporation licenses this file to you under the MIT license.
// See the LICENSE file in the project root for more information.

using global::PowerToys.GPOWrapper;
using ManagedCommon;
using Microsoft.PowerToys.Settings.UI.Library;
using Microsoft.PowerToys.Settings.UI.Views;

namespace Microsoft.PowerToys.Settings.UI.Helpers
{
    internal sealed class ModuleHelper
    {
        public static string GetModuleLabelResourceName(ModuleType moduleType)
        {
            return $"{moduleType}/ModuleTitle";
        }

        public static string GetModuleTypeFluentIconName(ModuleType moduleType)
        {
            return $"ms-appx:///Assets/Settings/Icons/{moduleType}.png";
        }

        public static bool GetIsModuleEnabled(Library.GeneralSettings generalSettingsConfig, ModuleType moduleType)
        {
            switch (moduleType)
            {
                case ModuleType.KeyboardManager: return generalSettingsConfig.Enabled.KeyboardManager;
                default: return false;
            }
        }

        internal static void SetIsModuleEnabled(GeneralSettings generalSettingsConfig, ModuleType moduleType, bool isEnabled)
        {
            switch (moduleType)
            {
                case ModuleType.KeyboardManager: generalSettingsConfig.Enabled.KeyboardManager = isEnabled; break;
            }
        }

        public static GpoRuleConfigured GetModuleGpoConfiguration(ModuleType moduleType)
        {
            switch (moduleType)
            {
                case ModuleType.KeyboardManager: return GPOWrapper.GetConfiguredKeyboardManagerEnabledValue();
                default: return GpoRuleConfigured.Unavailable;
            }
        }

        public static System.Type GetModulePageType(ModuleType moduleType)
        {
            return moduleType switch
            {
                ModuleType.KeyboardManager => typeof(KeyboardManagerPage),
                _ => typeof(GeneralPage),
            };
        }
    }
}
