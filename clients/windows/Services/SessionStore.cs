using System.Text.Json;
using Resona.Windows.Models;

namespace Resona.Windows.Services;

public static class SessionStore
{
    private const string Target = "ResonaSession";

    public static void Save(Session session)
    {
        CredentialManager.Write(Target, JsonSerializer.Serialize(session));
    }

    public static Session? Load()
    {
        var value = CredentialManager.Read(Target);
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        try
        {
            var session = JsonSerializer.Deserialize<Session>(value);
            return session is not null &&
                   !string.IsNullOrWhiteSpace(session.Server) &&
                   !string.IsNullOrWhiteSpace(session.Token)
                ? session
                : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static void Delete() => CredentialManager.Delete(Target);
}
