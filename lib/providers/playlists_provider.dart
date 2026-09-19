import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../config/yandex_config.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../services/yandex_s3_client.dart';

/// Плейлисты текущего пользователя.
///
/// Раньше метаданные лежали в SharedPreferences, а обложки — файлами в
/// каталоге приложения на диске. Теперь и то, и другое живёт в Yandex
/// Object Storage под ключами, привязанными к e-mail пользователя:
/// `library/playlists/<email>.json` для метаданных и
/// `covers/playlists/<email>/<id>-<ts>.jpg` для обложек. `Playlist.coverPath`
/// хранит именно такой ключ объекта в хранилище (не путь на диске) —
/// картинка загружается через RemoteCoverImage (см. widgets/remote_cover_image.dart).
///
/// Как и раньше:
/// - вся коллекция плейлистов читается/пишется одним JSON-блобом;
/// - запись метаданных дебаунсится;
/// - все мутации обновляют UI сразу (оптимистично), не дожидаясь сети.
class PlaylistsProvider extends ChangeNotifier {
  PlaylistsProvider({YandexS3Client? client}) : _client = client ?? YandexS3Client();
  final YandexS3Client _client;

  // Map сохраняет порядок вставки → плейлисты естественно идут в порядке
  // создания; O(1) доступ/обновление/удаление по id.
  final Map<String, Playlist> _playlists = <String, Playlist>{};
  bool _loaded = false;
  Timer? _saveDebounce;
  String? _email;
  int _loadToken = 0;
  String? _error;

  bool get isLoaded => _loaded;
  String? get error => _error;

  List<Playlist> get playlists =>
      _playlists.values.toList(growable: false).reversed.toList(growable: false);

  int get count => _playlists.length;

  Playlist? byId(String id) => _playlists[id];

  String _metaKeyFor(String email) =>
      '${YandexConfig.playlistsPrefix}${YandexConfig.sanitizeEmail(email)}.json';

  String _coverKeyFor(String email, String playlistId) =>
      '${YandexConfig.playlistCoversPrefix}${YandexConfig.sanitizeEmail(email)}/'
      '$playlistId-${DateTime.now().microsecondsSinceEpoch}.jpg';

  /// См. FavoritesProvider.setUser — та же идея, вызывается при
  /// входе/выходе/смене пользователя.
  Future<void> setUser(String? email) async {
    if (_email == email) return;
    _email = email;
    _playlists.clear();
    _saveDebounce?.cancel();
    _loaded = email == null;
    _error = null;
    notifyListeners();
    if (email == null) return;

    final token = ++_loadToken;
    try {
      final raw = await _client.getObject(_metaKeyFor(email));
      if (token != _loadToken) return;
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        for (final item in decoded) {
          final playlist = Playlist.fromJson(item as Map<String, dynamic>);
          if (playlist.id.isNotEmpty) _playlists[playlist.id] = playlist;
        }
      }
    } catch (e) {
      if (token != _loadToken) return;
      _error = 'Не удалось загрузить плейлисты: $e';
    } finally {
      if (token == _loadToken) {
        _loaded = true;
        notifyListeners();
      }
    }
  }

  /// Создаёt новый плейлист. [coverBytes], если передан, загружается в
  /// хранилище асинхронно — создание плейлиста в UI не ждёт сеть.
  Future<Playlist> create({required String name, Uint8List? coverBytes}) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    var playlist = Playlist(id: id, name: name.trim(), tracks: const {});
    _playlists[id] = playlist;
    notifyListeners();
    _scheduleSave();

    if (coverBytes != null) {
      await _uploadCover(id, coverBytes);
    }
    return playlist;
  }

  Future<void> rename(String playlistId, String newName) async {
    final playlist = _playlists[playlistId];
    if (playlist == null) return;
    _playlists[playlistId] = playlist.copyWith(name: newName.trim());
    notifyListeners();
    _scheduleSave();
  }

  Future<void> updateCover(String playlistId, Uint8List coverBytes) async {
    await _uploadCover(playlistId, coverBytes);
  }

  Future<void> _uploadCover(String playlistId, Uint8List bytes) async {
    final email = _email;
    if (email == null) return; // гость — обложки хранить негде
    final playlist = _playlists[playlistId];
    if (playlist == null) return;
    final key = _coverKeyFor(email, playlistId);
    try {
      await _client.putBytes(key, bytes, 'image/jpeg');
    } catch (e) {
      _error = 'Не удалось загрузить обложку: $e';
      notifyListeners();
      return;
    }
    if (!_playlists.containsKey(playlistId)) return; // плейлист удалили, пока грузили
    _playlists[playlistId] = _playlists[playlistId]!.copyWith(coverPath: key);
    notifyListeners();
    _scheduleSave();
  }

  void addTrack(String playlistId, Track track) {
    final playlist = _playlists[playlistId];
    if (playlist == null || playlist.tracks.containsKey(track.id)) return;
    final tracks = Map<String, Track>.of(playlist.tracks)..[track.id] = track;
    _playlists[playlistId] = playlist.copyWith(tracks: tracks);
    notifyListeners();
    _scheduleSave();
  }

  void removeTrack(String playlistId, String trackId) {
    final playlist = _playlists[playlistId];
    if (playlist == null || !playlist.tracks.containsKey(trackId)) return;
    final tracks = Map<String, Track>.of(playlist.tracks)..remove(trackId);
    _playlists[playlistId] = playlist.copyWith(tracks: tracks);
    notifyListeners();
    _scheduleSave();
  }

  bool containsTrack(String playlistId, String trackId) =>
      _playlists[playlistId]?.tracks.containsKey(trackId) ?? false;

  Future<void> delete(String playlistId) async {
    final playlist = _playlists.remove(playlistId);
    if (playlist == null) return;
    notifyListeners();
    _scheduleSave();
    // Старую обложку с диска хранилища не обязательно ждать — плейлиста
    // уже нет ни в UI, ни в метаданных, которые сейчас улетят на сохранение.
  }

  void _scheduleSave() {
    final email = _email;
    if (email == null) return;
    _saveDebounce?.cancel();
    final snapshot = _playlists.values.map((p) => p.toJson()).toList(growable: false);
    final token = _loadToken;
    _saveDebounce = Timer(const Duration(milliseconds: 300), () async {
      if (token != _loadToken) return;
      try {
        await _client.putObject(_metaKeyFor(email), jsonEncode(snapshot));
        if (token == _loadToken) _error = null;
      } catch (e) {
        if (token == _loadToken) {
          _error = 'Не удалось сохранить плейлисты: $e';
          notifyListeners();
        }
      }
    });
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    super.dispose();
  }
}
