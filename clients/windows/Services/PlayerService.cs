using Windows.Media.Core;
using Windows.Media.Playback;
using Resona.Windows.Models;

namespace Resona.Windows.Services;

/// <summary>
/// Thin wrapper around the Windows Media Player that feeds audio through the
/// loopback relay so bearer credentials never reach a CDN redirect.
/// </summary>
public sealed class PlayerService : IAsyncDisposable
{
    private readonly ApiClient _api;
    private PlaybackRelay? _relay;
    private MediaPlayer? _player;
    private Track? _current;

    public PlayerService(ApiClient api)
    {
        _api = api;
    }

    public event EventHandler? MediaEnded;

    public Track? Current => _current;
    public bool IsPlaying => _player?.CurrentState == MediaPlayerState.Playing;

    public TimeSpan Position
    {
        get => _player?.PlaybackSession.Position ?? TimeSpan.Zero;
        set
        {
            if (_player is not null)
            {
                _player.PlaybackSession.Position = value;
            }
        }
    }

    public TimeSpan Duration =>
        _player?.PlaybackSession.NaturalDuration ?? TimeSpan.Zero;

    public double Volume
    {
        get => _player?.Volume ?? 1.0;
        set
        {
            if (_player is not null)
            {
                _player.Volume = value;
            }
        }
    }

    public void Configure(Uri origin, string token)
    {
        _api.Configure(origin, token);
        var previous = _relay;
        _relay = new PlaybackRelay();
        _relay.Start(origin, token);
        if (previous is not null)
        {
            _ = previous.DisposeAsync();
        }
    }

    public void Play(Track track)
    {
        if (_relay?.Origin is null)
        {
            throw new InvalidOperationException("尚未连接服务器。");
        }

        _current = track;
        var player = GetPlayer();
        player.Source = MediaSource.CreateFromUri(_relay.StreamUri(track.Id));
        player.Play();
    }

    public void Toggle()
    {
        if (_player is null || _current is null)
        {
            return;
        }

        if (_player.CurrentState == MediaPlayerState.Playing)
        {
            _player.Pause();
        }
        else
        {
            _player.Play();
        }
    }

    public void Reset()
    {
        if (_player is not null)
        {
            _player.Pause();
        }

        _current = null;
    }

    public async ValueTask DisposeAsync()
    {
        if (_player is not null)
        {
            _player.Dispose();
            _player = null;
        }

        _current = null;
        if (_relay is not null)
        {
            await _relay.DisposeAsync().ConfigureAwait(false);
            _relay = null;
        }
    }

    private MediaPlayer GetPlayer()
    {
        if (_player is not null)
        {
            return _player;
        }

        var player = new MediaPlayer();
        player.MediaEnded += OnMediaEnded;
        _player = player;
        return player;
    }

    private void OnMediaEnded(MediaPlayer sender, object args)
    {
        MediaEnded?.Invoke(this, EventArgs.Empty);
    }
}
