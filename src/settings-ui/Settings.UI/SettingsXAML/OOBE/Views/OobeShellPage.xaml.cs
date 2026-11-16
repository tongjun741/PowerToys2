// Copyright (c) Microsoft Corporation
// The Microsoft Corporation licenses this file to you under the MIT license.
// See the LICENSE file in the project root for more information.

using System;
using System.Collections.ObjectModel;

using ManagedCommon;
using Microsoft.PowerToys.Settings.UI.OOBE.Enums;
using Microsoft.PowerToys.Settings.UI.OOBE.ViewModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using WinRT.Interop;

namespace Microsoft.PowerToys.Settings.UI.OOBE.Views
{
    public sealed partial class OobeShellPage : UserControl
    {
        public static Action<Type> OpenMainWindowCallback { get; set; }

        public static void SetOpenMainWindowCallback(Action<Type> implementation)
        {
            OpenMainWindowCallback = implementation;
        }

        /// <summary>
        /// Gets view model.
        /// </summary>
        public OobeShellViewModel ViewModel { get; } = new OobeShellViewModel();

        /// <summary>
        /// Gets or sets a shell handler to be used to update contents of the shell dynamically from page within the frame.
        /// </summary>
        public static OobeShellPage OobeShellHandler { get; set; }

        public ObservableCollection<OobePowerToysModule> Modules { get; }

        public OobeShellPage()
        {
            InitializeComponent();

            SetTitleBar();
            DataContext = ViewModel;
            OobeShellHandler = this;
            Modules = new ObservableCollection<OobePowerToysModule>();

            Modules.Insert((int)PowerToysModules.Overview, new OobePowerToysModule()
            {
                ModuleName = "Overview",
                IsNew = false,
            });
            Modules.Insert((int)PowerToysModules.KBM, new OobePowerToysModule()
            {
                ModuleName = "KBM",
                IsNew = false,
            });
            Modules.Insert((int)PowerToysModules.WhatsNew, new OobePowerToysModule()
            {
                ModuleName = "WhatsNew",
                IsNew = false,
            });
        }

        public void OnClosing()
        {
            Microsoft.UI.Xaml.Controls.NavigationViewItem selectedItem = this.navigationView.SelectedItem as Microsoft.UI.Xaml.Controls.NavigationViewItem;
            if (selectedItem != null)
            {
                Modules[(int)(PowerToysModules)Enum.Parse(typeof(PowerToysModules), (string)selectedItem.Tag, true)].LogClosingModuleEvent();
            }
        }

        public void NavigateToModule(PowerToysModules selectedModule)
        {
            if (selectedModule == PowerToysModules.WhatsNew)
            {
                navigationView.SelectedItem = navigationView.FooterMenuItems[0];
            }
            else
            {
                navigationView.SelectedItem = navigationView.MenuItems[(int)selectedModule];
            }
        }

        private void NavigationView_SelectionChanged(Microsoft.UI.Xaml.Controls.NavigationView sender, Microsoft.UI.Xaml.Controls.NavigationViewSelectionChangedEventArgs args)
        {
            Microsoft.UI.Xaml.Controls.NavigationViewItem selectedItem = args.SelectedItem as Microsoft.UI.Xaml.Controls.NavigationViewItem;

            if (selectedItem != null)
            {
                switch (selectedItem.Tag)
                {
                    case "Overview": NavigationFrame.Navigate(typeof(OobeOverview)); break;
                    case "WhatsNew": NavigationFrame.Navigate(typeof(OobeWhatsNew)); break;
                    case "KBM": NavigationFrame.Navigate(typeof(OobeKBM)); break;
                }
            }
        }

        private void SetTitleBar()
        {
            var u = App.GetOobeWindow();
            if (u != null)
            {
                // A custom title bar is required for full window theme and Mica support.
                // https://docs.microsoft.com/windows/apps/develop/title-bar?tabs=winui3#full-customization
                u.ExtendsContentIntoTitleBar = true;
                WindowHelpers.ForceTopBorder1PixelInsetOnWindows10(WindowNative.GetWindowHandle(u));
                u.SetTitleBar(AppTitleBar);
            }
        }

        private void ShellPage_Loaded(object sender, RoutedEventArgs e)
        {
            SetTitleBar();
        }

        private void NavigationView_DisplayModeChanged(NavigationView sender, NavigationViewDisplayModeChangedEventArgs args)
        {
            if (args.DisplayMode == NavigationViewDisplayMode.Compact || args.DisplayMode == NavigationViewDisplayMode.Minimal)
            {
                PaneToggleBtn.Visibility = Visibility.Visible;
                AppTitleBar.Margin = new Thickness(48, 0, 0, 0);
                AppTitleBarText.Margin = new Thickness(12, 0, 0, 0);
            }
            else
            {
                PaneToggleBtn.Visibility = Visibility.Collapsed;
                AppTitleBar.Margin = new Thickness(16, 0, 0, 0);
                AppTitleBarText.Margin = new Thickness(16, 0, 0, 0);
            }
        }

        private void PaneToggleBtn_Click(object sender, RoutedEventArgs e)
        {
            navigationView.IsPaneOpen = !navigationView.IsPaneOpen;
        }
    }
}
