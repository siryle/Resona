using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Resona.Windows.Models;
using Resona.Windows.Native;
using Resona.Windows.Services;

namespace Resona.Windows;

public sealed partial class MainWindow : Window
{
    private readonly ApiClient _api = new();
    private readonly PlayerService _player;
    private readonly TrayIcon _tray = new();
    private readonly DesktopLyricsWindow _desktopLyrics = new();
    private readonly DispatcherQueueTimer _timer;

    private CancellationTokenSource? _searchCts;
    private IReadOnlyList<LyricLine> _lyrics = [];
    private Track? _current;
    private bool _quitting;
    private bool _lyricsVisible;
    private bool _updatingSeek;

    public MainWindow()
    {
        InitializeComponent();
        _player = new PlayerService(_api);
        _player.MediaEnded += (_, _) => UpdatePlayIcon();

        _tray.OpenRequested += () => DispatcherQueue.TryEnqueue(Restore);
        _tray.ExitRequested += () => DispatcherQueue.TryEnqueue(() => { _ = QuitAsync(); });
        _tray.Start();

        _desktopLyrics.Start();
        _desktopLyrics.SetLyric("Resona · 此刻想听什么？");

        _timer = DispatcherQueue.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(250);
        _timer.Tick += OnTimerTick;
        _timer.Start();

        AppWindow.Closing += OnAppWindowClosing;
        _ = InitializeAsync();
    }

    private async Task InitializeAsync()
    {
        var session = SessionStore.Load();
        if (session is null)
        {
            ShowLogin();
            return;
        }

        await TryConnectAsync(session);
    }

    private void ShowLogin()
    {
        LoginOverlay.Visibility = Visibility.Visible;
        LoginButton.Visibility = Visibility.Collapsed;
        LogoutButton.Visibility = Visibility.Collapsed;
        LoginStatus.Text = string.Empty;
    }

    private void ShowLibrary()
    {
        LoginOverlay.Visibility = Visibility.Collapsed;
        LoginButton.Visibility = Visibility.Collapsed;
        LogoutButton.Visibility = Visibility.Visible;
    }

    private async Task TryConnectAsync(Session session)
    {
        try
        {
            var origin = session.ServerUri;
            _api.Configure(origin, session.Token);
            _player.Configure(origin, session.Token);
            await LoadTracksAsync(SearchBox.Text);
            ShowLibrary();
        }
        catch (Exception exception)
        {
            ShowLogin();
            ServerBox.Text = session.Server;
            LoginStatus.Text = DescribeError(exception);
        }
    }

    private async Task LoadTracksAsync(string search)
    {
        var result = await _api.GetTracksAsync(search: string.IsNullOrWhiteSpace(search) ? null : search, limit: 200);
        TrackList.ItemsSource = result.Items;
    }

    private void OnLoginClick(object sender, RoutedEventArgs e)
    {
        ShowLogin();
    }

    private async void OnSubmitLoginClick(object sender, RoutedEventArgs e)
    {
        if (SubmitLoginButton is null)
        {
            return;
        }

        SubmitLoginButton.IsEnabled = false;
        LoginStatus.Text = string.Empty;
        try
        {
            var origin = ServerAddress.Normalize(ServerBox.Text);
            var username = UsernameBox.Text.Trim();
            var password = PasswordBox.Password;
            if (username.Length == 0 || password.Length == 0)
            {
                throw new FormatException("请输入用户名和密码。");
            }

            var token = await _api.LoginAsync(origin, username, password);
            var session = new Session(origin.ToString(), username, token);
            SessionStore.Save(session);
            _api.Configure(origin, token);
            _player.Configure(origin, token);
            await LoadTracksAsync(SearchBox.Text);
            ShowLibrary();
        }
        catch (Exception exception)
        {
            LoginStatus.Text = DescribeError(exception);
        }
        finally
        {
            SubmitLoginButton.IsEnabled = true;
        }
    }

    private async void OnLogoutClick(object sender, RoutedEventArgs e)
    {
        LogoutButton.IsEnabled = false;
        try
        {
            await _player.DisposeAsync();
            SessionStore.Delete();
            TrackList.ItemsSource = null;
            _current = null;
            _lyrics = [];
            NowPlaying.Text = "Resona · 此刻想听什么？";
            TimeLabel.Text = "0:00 / 0:00";
            UpdatePlayIcon();
            ShowLogin();
        }
        finally
        {
            LogoutButton.IsEnabled = true;
        }
    }

    private async void OnSearchChanged(object sender, TextChangedEventArgs e)
    {
        _searchCts?.Cancel();
        var cts = new CancellationTokenSource();
        _searchCts = cts;
        try
        {
            await Task.Delay(300, cts.Token);
            if (_api.Origin is null)
            {
                return;
            }

            await LoadTracksAsync(SearchBox.Text);
        }
        catch (OperationCanceledException)
        {
        }
    }

    private void OnTrackItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is Track track)
        {
            _ = PlayTrackAsync(track);
        }
    }

    private async Task PlayTrackAsync(Track track)
    {
        _current = track;
        NowPlaying.Text = $"{track.Title} · {track.Artist}";
        _desktopLyrics.SetLyric($"{track.Title} · {track.Artist}");
        UpdatePlayIcon();

        try
        {
            _player.Play(track);
        }
        catch (Exception)
        {
            NowPlaying.Text = "无法播放 · 请检查登录状态和网络";
        }

        var lyrics = await _api.GetLyricsAsync(track.Id);
        _lyrics = LrcParser.Parse(lyrics);
    }

    private void OnTimerTick(DispatcherQueueTimer sender, object args)
    {
        var duration = _player.Duration;
        var position = _player.Position;
        TimeLabel.Text = $"{FormatDuration(position)} / {FormatDuration(duration)}";

        if (!_updatingSeek && duration.TotalSeconds > 0)
        {
            _updatingSeek = true;
            SeekBar.Value = position.TotalSeconds / duration.TotalSeconds;
            _updatingSeek = false;
        }

        UpdateLyric(position.TotalSeconds);
    }

    private void UpdateLyric(double seconds)
    {
        var line = _lyrics.LastOrDefault(item => item.Seconds is not null && item.Seconds <= seconds);
        if (line is not null && !string.IsNullOrWhiteSpace(line.Text))
        {
            _desktopLyrics.SetLyric(line.Text);
        }
        else if (_current is not null)
        {
            _desktopLyrics.SetLyric($"{_current.Title} · {_current.Artist}");
        }
    }

    private void OnSeekChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (_updatingSeek || _current is null)
        {
            return;
        }

        var duration = _player.Duration;
        if (duration.TotalSeconds > 0)
        {
            _player.Position = TimeSpan.FromSeconds(SeekBar.Value * duration.TotalSeconds);
        }
    }

    private void OnPlayPauseClick(object sender, RoutedEventArgs e)
    {
        if (_current is null)
        {
            return;
        }

        _player.Toggle();
        UpdatePlayIcon();
    }

    private void OnToggleLyricsClick(object sender, RoutedEventArgs e)
    {
        _lyricsVisible = !_lyricsVisible;
        _desktopLyrics.SetVisible(_lyricsVisible);
    }

    private void UpdatePlayIcon()
    {
        if (PlayButton.Content is SymbolIcon icon)
        {
            icon.Symbol = _player.IsPlaying ? Symbol.Pause : Symbol.Play;
        }
    }

    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_quitting)
        {
            return;
        }

        args.Cancel = true;
        AppWindow.Hide();
    }

    private void Restore()
    {
        AppWindow.Show();
        Activate();
    }

    private async Task QuitAsync()
    {
        _quitting = true;
        _timer.Stop();
        _tray.Dispose();
        _desktopLyrics.Dispose();
        await _player.DisposeAsync();
        Close();
    }

    private static string FormatDuration(TimeSpan value)
    {
        var totalSeconds = Math.Max(0, (int)value.TotalSeconds);
        return $"{totalSeconds / 60}:{totalSeconds % 60:00}";
    }

    private static string DescribeError(Exception exception) => exception switch
    {
        FormatException format => format.Message,
        HttpRequestException => "连接失败，请检查服务器地址、网络和证书。",
        _ => "操作失败，请检查登录状态和网络后重试。",
    };
}
