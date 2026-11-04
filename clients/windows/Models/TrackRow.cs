namespace Resona.Windows.Models;

public sealed class TrackRow
{
    public TrackRow(int index, Track track)
    {
        Index = index;
        Track = track;
    }

    public int Index { get; }

    public string IndexText => Index.ToString("00");

    public Track Track { get; }
}
