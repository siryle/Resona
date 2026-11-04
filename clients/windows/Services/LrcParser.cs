using System.Text.RegularExpressions;

namespace Resona.Windows.Services;

public sealed record LyricLine(double? Seconds, string Text);

public static partial class LrcParser
{
    public static IReadOnlyList<LyricLine> Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return Array.Empty<LyricLine>();
        }

        var lines = new List<LyricLine>();
        foreach (var raw in text.Replace("\r\n", "\n").Split('\n'))
        {
            var matches = TimestampRegex().Matches(raw);
            if (matches.Count == 0)
            {
                continue;
            }

            var content = raw;
            foreach (Match match in matches)
            {
                content = content.Replace(match.Value, string.Empty);
            }

            foreach (Match match in matches)
            {
                var seconds = ParseTimestamp(match.Value);
                if (seconds is not null)
                {
                    lines.Add(new LyricLine(seconds, content.Trim()));
                }
            }
        }

        return lines
            .Where(line => line.Seconds is not null)
            .OrderBy(line => line.Seconds)
            .ToArray();
    }

    private static double? ParseTimestamp(string value)
    {
        var match = TimestampRegex().Match(value);
        if (!match.Success)
        {
            return null;
        }

        var minutes = double.Parse(match.Groups["min"].Value);
        var seconds = double.Parse(match.Groups["sec"].Value);
        var fraction = match.Groups["frac"].Success
            ? double.Parse("0." + match.Groups["frac"].Value)
            : 0;
        return minutes * 60 + seconds + fraction;
    }

    [GeneratedRegex(@"\[(?<min>\d{1,3}):(?<sec>\d{1,2})(?:[.:](?<frac>\d{1,3}))?\]")]
    private static partial Regex TimestampRegex();
}
