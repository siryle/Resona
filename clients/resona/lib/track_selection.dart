import 'api.dart';

enum TrackSearchField {
  all('全部'),
  title('歌曲'),
  album('专辑'),
  artist('歌手');

  final String label;
  const TrackSearchField(this.label);
}

class TrackSelection {
  final selectedIDs = <String>{};
  String query = '';
  TrackSearchField searchField = TrackSearchField.all;
  bool favoritesOnly = false, downloadsOnly = false;

  bool get hasFilters =>
      searchField != TrackSearchField.all || favoritesOnly || downloadsOnly;
  bool get active => query.trim().isNotEmpty || hasFilters;

  List<Track> filtered(List<Track> tracks, Set<String> downloadedIDs) {
    final term = query.trim().toLowerCase();
    return tracks.where((track) {
      if (favoritesOnly && !track.favorite ||
          downloadsOnly && !downloadedIDs.contains(track.id)) {
        return false;
      }
      final albumArtist = track.json['album_artist'] as String? ?? '';
      final text = switch (searchField) {
        TrackSearchField.all =>
          '${track.title} ${track.album} ${track.artist} $albumArtist',
        TrackSearchField.title => track.title,
        TrackSearchField.album => track.album,
        TrackSearchField.artist => '${track.artist} $albumArtist',
      };
      return text.toLowerCase().contains(term);
    }).toList();
  }

  bool allSelected(List<Track> tracks) =>
      tracks.isNotEmpty &&
      tracks.every((track) => selectedIDs.contains(track.id));

  void toggle(String id) {
    if (!selectedIDs.add(id)) selectedIDs.remove(id);
  }

  void toggleAll(List<Track> tracks) {
    final ids = tracks.map((track) => track.id);
    if (allSelected(tracks)) {
      selectedIDs.removeAll(ids);
    } else {
      selectedIDs.addAll(ids);
    }
  }

  List<Track> selected(List<Track> tracks) =>
      tracks.where((track) => selectedIDs.contains(track.id)).toList();
}
