import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resona_client/controller.dart';
import 'package:resona_client/main.dart';

class AvatarController extends MusicController {
  final Future<Uint8List>? image;
  AvatarController(this.image);
  String? requestedPath;
  @override
  Future<Uint8List> artistArtwork(String name, String path) {
    requestedPath = path;
    return image ?? Future.error(const SocketException('offline'));
  }
}

void main() {
  for (final available in [true, false]) {
    testWidgets(
      'artist avatar renders image or initial with available=$available',
      (tester) async {
        final bytes = available
            ? File('../../docs/brand/resona-icon.png').readAsBytesSync()
            : Uint8List(0);
        final c = AvatarController(Future.value(bytes));
        addTearDown(c.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ArtistAvatar(
                controller: c,
                name: '周杰伦',
                path: '/api/v1/artists/avatar?name=Artist',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(c.requestedPath, '/api/v1/artists/avatar?name=Artist');
        expect(find.byType(ClipOval), findsOneWidget);
        expect(find.byType(Image), available ? findsOneWidget : findsNothing);
        expect(find.text('周'), available ? findsNothing : findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('artist network errors retain the initial', (tester) async {
    final c = AvatarController(null);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ArtistAvatar(controller: c, name: '歌手', path: '/missing'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('歌'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
