// Copyright (c) Microsoft Corporation
// The Microsoft Corporation licenses this file to you under the MIT license.
// See the LICENSE file in the project root for more information.

using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;
using Microsoft.PowerToys.Settings.UI.Helpers;
using Microsoft.PowerToys.Settings.UI.Library;

namespace Microsoft.PowerToys.Settings.UI.SerializationContext;

[JsonSerializable(typeof(ActionMessage))]
[JsonSerializable(typeof(Dictionary<string, List<string>>))]
[JsonSerializable(typeof(IList<PowerToysReleaseInfo>))]
[JsonSerializable(typeof(KeyboardManagerSettings))]
[JsonSerializable(typeof(ShortcutConflictProperties))]
[JsonSerializable(typeof(WINDOWPLACEMENT))]
public sealed partial class SourceGenerationContextContext : JsonSerializerContext
{
}
