using System.Windows;
using CampusEntry.Core;

namespace CampusEntry;

/// <summary>设置对话框（桌面惯例：模态窗口 + 标准控件，不是手机抽屉）。</summary>
public partial class SettingsWindow : Window
{
    private readonly EntryHost host;
    private readonly Action onChanged;

    internal SettingsWindow(EntryHost host, Action onChanged, Window owner)
    {
        this.host = host;
        this.onChanged = onChanged;
        Owner = owner;
        InitializeComponent();
        Refresh();
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        DesktopWindowFrame.Apply(this);
    }

    private void Refresh()
    {
        SavedLine.Text = host.SavedUsername == null
                ? "已保存：未保存"
                : $"已保存：{Mask(host.SavedUsername)}";
        SaveAccountBox.IsChecked = host.SaveAccount;
        HideNoticesBox.IsChecked = host.HideNotices;
        ClearAccountButton.IsEnabled = host.SavedUsername != null;
        return;

        static string Mask(string username) =>
                username.Length <= 4 ? "****" : username[..4] + "****";
    }

    private void OnSaveAccountToggled(object sender, RoutedEventArgs e)
    {
        var on = SaveAccountBox.IsChecked == true;
        host.ChangeSaveAccount(on);
        onChanged();
        Refresh();
    }

    private void OnHideNoticesToggled(object sender, RoutedEventArgs e)
    {
        host.ChangeHideNotices(HideNoticesBox.IsChecked == true);
        onChanged();
    }

    private void OnClearSession(object sender, RoutedEventArgs e)
    {
        host.ClearSession();
        Close();
    }

    private void OnClearAccount(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(this, "删除加密保存在本机的账号密码？删除后下次要重新手动登录。",
                "清除账号", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK)
        {
            return;
        }
        host.ClearAccount();
        onChanged();
        Refresh();
    }

    private void OnSwitchAccount(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(this, "清掉登录状态与本机账号，重新走一遍首次登录？",
                "改用其他账号", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK)
        {
            return;
        }
        host.SwitchAccount();
        Close();
    }

    private void OnClose(object sender, RoutedEventArgs e) => Close();
}
