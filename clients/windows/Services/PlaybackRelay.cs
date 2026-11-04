using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace Resona.Windows.Services;

/// <summary>
/// Loopback HTTP relay used by the native decoder. It keeps the Resona bearer
/// token on the configured server origin only: redirects to trusted CDN hosts
/// are followed without forwarding the Authorization header.
/// </summary>
public sealed class PlaybackRelay : IAsyncDisposable
{
    private static readonly string[] TrustedCdnSuffixes =
        ["115.com", "115cdn.com", "115cdn.net", "anxia.com"];

    private readonly HttpClient _http = new(new HttpClientHandler
    {
        AllowAutoRedirect = false,
        AutomaticDecompression = DecompressionMethods.None,
        UseProxy = false,
    });
    private readonly string _secret = WebUtility.UrlEncode(
        Convert.ToBase64String(RandomNumberGenerator.GetBytes(18)));
    private readonly CancellationTokenSource _shutdown = new();
    private readonly List<TcpClient> _clients = [];
    private readonly object _clientsLock = new();

    private TcpListener? _listener;
    private Task? _loop;

    public Uri? Origin { get; private set; }
    public int Port { get; private set; }

    public Uri StreamUri(string trackId)
    {
        return new Uri(
            $"http://127.0.0.1:{Port}/{_secret}/api/v1/tracks/{Uri.EscapeDataString(trackId)}/stream");
    }

    public void Start(Uri origin, string token)
    {
        ArgumentNullException.ThrowIfNull(origin);
        if (_listener is not null)
        {
            return;
        }

        Origin = origin;
        _http.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", token);
        _listener = new TcpListener(IPAddress.Loopback, 0);
        _listener.Start();
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        _loop = Task.Run(() => LoopAsync(_listener, _shutdown.Token));
    }

    public async ValueTask DisposeAsync()
    {
        _shutdown.Cancel();
        _listener?.Stop();
        TcpClient[] clients;
        lock (_clientsLock)
        {
            clients = _clients.ToArray();
            _clients.Clear();
        }

        foreach (var client in clients)
        {
            try
            {
                client.Dispose();
            }
            catch
            {
                // Best effort cleanup.
            }
        }

        if (_loop is not null)
        {
            try
            {
                await _loop.ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is OperationCanceledException or ObjectDisposedException or SocketException)
            {
            }
        }

        _http.Dispose();
        _shutdown.Dispose();
    }

    private async Task LoopAsync(TcpListener listener, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await listener.AcceptTcpClientAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is OperationCanceledException or ObjectDisposedException or SocketException)
            {
                break;
            }

            lock (_clientsLock)
            {
                _clients.Add(client);
            }

            _ = Task.Run(() => HandleClientAsync(client, cancellationToken), CancellationToken.None);
        }
    }

    private async Task HandleClientAsync(TcpClient client, CancellationToken cancellationToken)
    {
        try
        {
            using (client)
            {
                var stream = client.GetStream();
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeout.CancelAfter(TimeSpan.FromSeconds(15));

                var headerBlock = await ReadHeaderBlockAsync(stream, timeout.Token).ConfigureAwait(false);
                if (headerBlock is null)
                {
                    return;
                }

                var request = ParseRequest(headerBlock);
                if (request is null || Origin is null)
                {
                    await WriteStatusAsync(stream, HttpStatusCode.BadRequest, "Bad Request").ConfigureAwait(false);
                    return;
                }

                if (!request.Value.Target.StartsWith($"/{_secret}/", StringComparison.Ordinal))
                {
                    await WriteStatusAsync(stream, HttpStatusCode.NotFound, "Not Found").ConfigureAwait(false);
                    return;
                }

                var upstreamPath = request.Value.Target[(_secret.Length + 1)..];
                if (upstreamPath.Length == 0 || upstreamPath[0] != '/')
                {
                    await WriteStatusAsync(stream, HttpStatusCode.BadRequest, "Bad Request").ConfigureAwait(false);
                    return;
                }

                var target = new Uri(Origin, upstreamPath);
                using var upstream = await ForwardAsync(
                    request.Value.Method,
                    target,
                    request.Value.Range,
                    timeout.Token).ConfigureAwait(false);

                await CopyResponseAsync(
                    stream,
                    upstream,
                    request.Value.Method == "HEAD",
                    timeout.Token).ConfigureAwait(false);
            }
        }
        catch (Exception)
        {
            // The client is about to be disposed; the decoder will retry or surface the failure.
        }
        finally
        {
            lock (_clientsLock)
            {
                _clients.Remove(client);
            }
        }
    }

    private static async Task<byte[]?> ReadHeaderBlockAsync(Stream stream, CancellationToken cancellationToken)
    {
        var buffer = new byte[16 * 1024];
        var length = 0;
        while (length < buffer.Length)
        {
            var read = await stream.ReadAsync(
                buffer.AsMemory(length, 1),
                cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                return null;
            }

            length++;
            if (length >= 4 &&
                buffer[length - 4] == '\r' &&
                buffer[length - 3] == '\n' &&
                buffer[length - 2] == '\r' &&
                buffer[length - 1] == '\n')
            {
                return buffer.AsSpan(0, length).ToArray();
            }
        }

        return null;
    }

    private static (string Method, string Target, string? Range)? ParseRequest(byte[] headerBlock)
    {
        var text = Encoding.ASCII.GetString(headerBlock);
        var lines = text.Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
        if (lines.Length == 0)
        {
            return null;
        }

        var requestParts = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (requestParts.Length < 2)
        {
            return null;
        }

        var method = requestParts[0].ToUpperInvariant();
        if (method is not ("GET" or "HEAD"))
        {
            return null;
        }

        string? range = null;
        foreach (var line in lines.Skip(1))
        {
            var separator = line.IndexOf(':');
            if (separator <= 0)
            {
                continue;
            }

            var name = line[..separator].Trim();
            if (name.Equals("Range", StringComparison.OrdinalIgnoreCase))
            {
                range = line[(separator + 1)..].Trim();
            }
        }

        return (method, requestParts[1], range);
    }

    private async Task<HttpResponseMessage> ForwardAsync(
        string method,
        Uri target,
        string? range,
        CancellationToken cancellationToken)
    {
        var redirects = 0;
        var current = target;
        var sendAuthorization = true;

        while (redirects < 3)
        {
            using var request = new HttpRequestMessage(new HttpMethod(method), current);
            if (!string.IsNullOrWhiteSpace(range))
            {
                request.Headers.TryAddWithoutValidation("Range", range);
            }

            if (sendAuthorization)
            {
                request.Headers.Authorization = _http.DefaultRequestHeaders.Authorization;
            }

            var response = await _http.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);

            if (!IsRedirect(response.StatusCode))
            {
                return response;
            }

            var location = response.Headers.Location;
            response.Dispose();
            if (location is null)
            {
                throw new InvalidOperationException("Received a redirect without a Location header.");
            }

            current = new Uri(current, location);
            if (!IsTrustedPlaybackHost(current, Origin!))
            {
                throw new InvalidOperationException($"Refusing redirect to untrusted host {current.Host}.");
            }

            sendAuthorization = current.Host == Origin!.Host;
            redirects++;
        }

        throw new InvalidOperationException("Too many playback redirects.");
    }

    private static async Task CopyResponseAsync(
        Stream destination,
        HttpResponseMessage source,
        bool headOnly,
        CancellationToken cancellationToken)
    {
        var headers = new List<string>
        {
            $"HTTP/1.1 {(int)source.StatusCode} {source.ReasonPhrase}",
            "Connection: close",
        };

        var contentType = source.Content.Headers.ContentType?.ToString();
        if (!string.IsNullOrWhiteSpace(contentType))
        {
            headers.Add($"Content-Type: {contentType}");
        }

        var contentLength = source.Content.Headers.ContentLength;
        if (contentLength is not null)
        {
            headers.Add($"Content-Length: {contentLength.Value}");
        }

        var contentRange = source.Content.Headers.ContentRange?.ToString();
        if (!string.IsNullOrWhiteSpace(contentRange))
        {
            headers.Add($"Content-Range: {contentRange}");
        }

        var acceptRanges = source.Headers.AcceptRanges;
        if (acceptRanges is not null && acceptRanges.Count > 0)
        {
            headers.Add($"Accept-Ranges: {string.Join(", ", acceptRanges)}");
        }

        var headerBytes = Encoding.ASCII.GetBytes(string.Join("\r\n", headers) + "\r\n\r\n");
        await destination.WriteAsync(headerBytes, cancellationToken).ConfigureAwait(false);

        if (headOnly)
        {
            return;
        }

        await using var body = await source.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        await body.CopyToAsync(destination, cancellationToken).ConfigureAwait(false);
    }

    private static async Task WriteStatusAsync(Stream stream, HttpStatusCode status, string reason)
    {
        var text = $"HTTP/1.1 {(int)status} {reason}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";
        var bytes = Encoding.ASCII.GetBytes(text);
        await stream.WriteAsync(bytes).ConfigureAwait(false);
    }

    private static bool IsRedirect(HttpStatusCode status) =>
        status is HttpStatusCode.Moved or
            HttpStatusCode.Redirect or
            HttpStatusCode.RedirectMethod or
            HttpStatusCode.RedirectKeepVerb;

    private static bool IsTrustedPlaybackHost(Uri uri, Uri origin)
    {
        var host = uri.Host;
        if (host.Equals(origin.Host, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return TrustedCdnSuffixes.Any(suffix =>
            host.Equals(suffix, StringComparison.OrdinalIgnoreCase) ||
            host.EndsWith("." + suffix, StringComparison.OrdinalIgnoreCase));
    }
}
