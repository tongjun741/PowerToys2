// Copyright (c) Microsoft Corporation
// The Microsoft Corporation licenses this file to you under the MIT license.
// See the LICENSE file in the project root for more information.

using System;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;

using Microsoft.PowerToys.Settings.Telemetry;
using Microsoft.PowerToys.Telemetry;

namespace Microsoft.PowerToys.Settings.UI.Library
{
    public class EnabledModules
    {
        private Action notifyEnabledChangedAction;

        // Default values for enabled modules should match their expected "enabled by default" values.
        // Otherwise, a run of DSC on clean settings will not match the expected default result.
        public EnabledModules()
        {
        }

        private bool keyboardManager; // defaulting to off

        [JsonPropertyName("Keyboard Manager")]
        public bool KeyboardManager
        {
            get => keyboardManager;
            set
            {
                if (keyboardManager != value)
                {
                    LogTelemetryEvent(value);
                    keyboardManager = value;
                }
            }
        }

        private void NotifyChange()
        {
            notifyEnabledChangedAction?.Invoke();
        }

        public string ToJsonString()
        {
            return JsonSerializer.Serialize(this);
        }

        private static void LogTelemetryEvent(bool value, [CallerMemberName] string moduleName = null)
        {
            var dataEvent = new SettingsEnabledEvent()
            {
                Value = value,
                Name = moduleName,
            };
            PowerToysTelemetry.Log.WriteEvent(dataEvent);
        }

        internal void AddEnabledModuleChangeNotification(Action callBack)
        {
            notifyEnabledChangedAction = callBack;
        }
    }
}
