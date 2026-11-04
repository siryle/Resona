using System.Text.Json.Serialization;

namespace Resona.Windows.Models;

public sealed record Session(
    [property: JsonPropertyName("server")] string Server,
    [property: JsonPropertyName("username")] string Username,
    [property: JsonPropertyName("token")] string Token)
{
    public Uri ServerUri => new(Server);
}

public static class ServerAddress
{
    public static Uri Normalize(string? input)
    {
        var value = input?.Trim() ?? string.Empty;
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps) ||
            string.IsNullOrEmpty(uri.Host) ||
            !string.IsNullOrEmpty(uri.UserInfo) ||
            !string.IsNullOrEmpty(uri.Query) ||
            !string.IsNullOrEmpty(uri.Fragment))
        {
            throw new FormatException("请输入完整的 HTTP / HTTPS 服务器地址");
        }

        return uri;
    }
}
