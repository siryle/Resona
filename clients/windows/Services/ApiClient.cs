using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Resona.Windows.Models;

namespace Resona.Windows.Services;

public sealed class ApiClient
{
    private readonly HttpClient _http = new();
    private Uri? _origin;

    public Uri? Origin => _origin;

    public void Configure(Uri origin, string? token)
    {
        _origin = origin;
        _http.DefaultRequestHeaders.Authorization = string.IsNullOrEmpty(token)
            ? null
            : new AuthenticationHeaderValue("Bearer", token);
    }

    public async Task<string> LoginAsync(Uri origin, string username, string password, CancellationToken cancellationToken = default)
    {
        var response = await _http.PostAsync(
            new Uri(origin, "/api/v1/auth/login"),
            new StringContent(
                JsonSerializer.Serialize(new { username, password }),
                Encoding.UTF8,
                "application/json"),
            cancellationToken).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false));
        return document.RootElement.GetProperty("token").GetString()
            ?? throw new InvalidOperationException("登录响应缺少 token。");
    }

    public async Task<PagedTracks> GetTracksAsync(
        string? library = null,
        string? search = null,
        bool? favorite = null,
        int offset = 0,
        int limit = 100,
        CancellationToken cancellationToken = default)
    {
        var query = new StringBuilder($"/api/v1/tracks?offset={offset}&limit={limit}");
        if (!string.IsNullOrEmpty(library))
        {
            query.Append($"&library={Uri.EscapeDataString(library)}");
        }
        if (!string.IsNullOrEmpty(search))
        {
            query.Append($"&search={Uri.EscapeDataString(search)}");
        }
        if (favorite is not null)
        {
            query.Append($"&favorite={(favorite.Value ? "true" : "false")}");
        }

        using var response = await _http.GetAsync(new Uri(RequireOrigin(), query.ToString()), cancellationToken).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        return await JsonSerializer.DeserializeAsync<PagedTracks>(stream, cancellationToken: cancellationToken).ConfigureAwait(false)
            ?? new PagedTracks();
    }

    public async Task<string?> GetLyricsAsync(string trackId, CancellationToken cancellationToken = default)
    {
        using var response = await _http.GetAsync(
            new Uri(RequireOrigin(), $"/api/v1/tracks/{Uri.EscapeDataString(trackId)}/lyrics"),
            cancellationToken).ConfigureAwait(false);
        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
    }

    public string TrackStreamPath(string trackId) => $"/api/v1/tracks/{Uri.EscapeDataString(trackId)}/stream";

    private Uri RequireOrigin() => _origin
        ?? throw new InvalidOperationException("尚未配置服务器地址。");
}
