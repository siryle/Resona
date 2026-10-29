import 'package:flutter_test/flutter_test.dart';
import 'package:resona_client/api.dart';
import 'package:resona_client/track_selection.dart';

void main() {
  final tracks = [
    Track({
      'id': 'one',
      'title': 'First Song',
      'artist': 'Solo Artist',
      'album_artist': 'Ensemble',
      'album': 'Live Album',
      'favorite': true,
    }),
    Track({
      'id': 'two',
      'title': 'Second Song',
      'artist': 'Another Artist',
      'album': 'Studio Album',
    }),
  ];

  test('search scopes, favorites and downloads intersect', () {
    final selection = TrackSelection()..query = '  ENSEMBLE  ';
    expect(selection.filtered(tracks, {}).single.id, 'one');
    selection.searchField = TrackSearchField.title;
    expect(selection.filtered(tracks, {}), isEmpty);
    selection
      ..searchField = TrackSearchField.artist
      ..favoritesOnly = true
      ..downloadsOnly = true;
    expect(selection.filtered(tracks, {'two'}), isEmpty);
    expect(selection.filtered(tracks, {'one'}).single.id, 'one');
    selection
      ..query = 'studio'
      ..searchField = TrackSearchField.album
      ..favoritesOnly = false;
    expect(selection.filtered(tracks, {'two'}).single.id, 'two');
  });

  test(
    'select all only toggles current results and keeps hidden selections',
    () {
      final selection = TrackSelection();
      expect(selection.allSelected([]), isFalse);
      selection.toggle('one');
      selection.query = 'Second';
      final visible = selection.filtered(tracks, {});
      selection.toggleAll(visible);
      expect(selection.allSelected(visible), isTrue);
      expect(selection.selected(tracks).map((t) => t.id), ['one', 'two']);
      selection.toggleAll(visible);
      expect(selection.selected(tracks).single.id, 'one');
      selection.toggle('one');
      expect(selection.selected(tracks), isEmpty);
    },
  );
}
