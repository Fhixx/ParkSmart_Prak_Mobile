import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:latlong2/latlong.dart';
import '../../../core/services/session_service.dart';
import '../../../core/services/currency_service.dart';
import '../../home/backend/home_backend.dart';
import '../../profile/backend/profile_backend.dart';

/// Backend khusus untuk FavoriteScreen (lib/features/favorite/favorite_screen.dart)
///
/// PENYIMPANAN LOKAL (Local Storage) menggunakan Hive — mengacu pada Modul 6.
/// Data favorit disimpan di memori internal perangkat (Box 'favorites'),
/// sehingga tetap ada saat aplikasi ditutup dan bisa dibuka tanpa internet.
///
/// Struktur data di dalam Box:
///   key   : '<userId>::<locationId>'   (favorit dipisah per akun, seperti sebelumnya)
///   value : Map berisi salinan (snapshot) data lokasi parkir saat difavoritkan
///
/// Operasi CRUD:
///   Create -> toggleFavorite()   (box.put)
///   Read   -> fetchFavorites()   (box.keys / box.get)
///   Delete -> removeFavorite()   (box.delete)
class FavoriteBackend extends ChangeNotifier {
  FavoriteBackend._();
  static final FavoriteBackend instance = FavoriteBackend._();

  /// Nama Box Hive (dibuka di main.dart)
  static const String boxName = 'favorites';

  static const String _defaultImage =
      'https://images.unsplash.com/photo-1506521781263-d8422e82f27a?w=600&auto=format&fit=crop&q=80';

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  Set<String> _favoriteLocationIds = {};
  Set<String> get favoriteLocationIds => _favoriteLocationIds;

  List<Map<String, dynamic>> _favorites = [];
  List<Map<String, dynamic>> get favorites => _favorites;

  /// Membuka Box Hive (jika belum terbuka). Box normalnya sudah dibuka di main.dart.
  Future<Box<dynamic>> _openBox() async {
    if (Hive.isBoxOpen(boxName)) return Hive.box(boxName);
    return Hive.openBox(boxName);
  }

  /// User ID aktif (dibaca dari memori, tanpa internet).
  /// Jika belum ada yang login, dipakai 'guest' agar fitur tetap berjalan.
  String _resolveUserId() {
    final profileId = ProfileBackend.instance.userId;
    if (profileId.isNotEmpty) return profileId;

    final sessionId = SessionService.instance.userId;
    if (sessionId != null && sessionId.isNotEmpty) return sessionId;

    final homeId = HomeBackend.instance.userId;
    if (homeId.isNotEmpty) return homeId;

    return 'guest';
  }

  String _key(String userId, String locationId) => '$userId::$locationId';

  /// Cek apakah suatu tempat parkir merupakan favorit user yang sedang aktif.
  /// Membaca langsung dari Box (sinkron & cepat), jadi selalu akurat walau akun berganti.
  bool isFavorite(String? locationId) {
    if (locationId == null || locationId.isEmpty) return false;
    if (!Hive.isBoxOpen(boxName)) return _favoriteLocationIds.contains(locationId);
    return Hive.box(boxName).containsKey(_key(_resolveUserId(), locationId));
  }

  /// READ: memuat daftar parkir favorit milik user aktif dari penyimpanan lokal.
  Future<void> fetchFavorites() async {
    _isLoading = true;
    try {
      final box = await _openBox();
      final uid = _resolveUserId();

      final rows = <Map<String, dynamic>>[];
      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw is! Map) continue;
        final row = Map<String, dynamic>.from(raw);
        if (row['user_id']?.toString() != uid) continue;
        rows.add(row);
      }

      // Favorit terbaru tampil paling atas
      rows.sort((a, b) {
        final ta = (a['saved_at'] as num?)?.toInt() ?? 0;
        final tb = (b['saved_at'] as num?)?.toInt() ?? 0;
        return tb.compareTo(ta);
      });

      _favorites = rows.map(_toDisplayMap).toList();
      _favoriteLocationIds = rows.map((r) => r['location_id'].toString()).toSet();
    } catch (e) {
      debugPrint('[FavoriteBackend] fetchFavorites error: $e');
      _favorites = [];
      _favoriteLocationIds = {};
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// CREATE / DELETE: toggle status favorit.
  /// Tambah jika belum ada, hapus jika sudah ada.
  ///
  /// [location] adalah data lokasi parkir (baris `parking_locations`) yang akan
  /// disalin ke penyimpanan lokal, supaya favorit bisa tampil tanpa internet.
  ///
  /// Mengembalikan `true` jika sekarang jadi favorit, `false` jika dihapus.
  Future<bool> toggleFavorite(String locationId, {Map<String, dynamic>? location}) async {
    try {
      final box = await _openBox();
      final uid = _resolveUserId();
      final key = _key(uid, locationId);

      if (box.containsKey(key)) {
        await box.delete(key);
        _favoriteLocationIds.remove(locationId);
        _favorites.removeWhere((item) => item['id']?.toString() == locationId);
        notifyListeners();
        return false;
      }

      final record = _buildRecord(uid, locationId, location);
      await box.put(key, record);

      _favoriteLocationIds.add(locationId);
      _favorites.removeWhere((item) => item['id']?.toString() == locationId);
      _favorites.insert(0, _toDisplayMap(record));
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[FavoriteBackend] toggleFavorite error: $e');
      return false;
    }
  }

  /// DELETE: menghapus lokasi dari daftar favorit.
  Future<void> removeFavorite(String locationId) async {
    try {
      final box = await _openBox();
      await box.delete(_key(_resolveUserId(), locationId));
      _favoriteLocationIds.remove(locationId);
      _favorites.removeWhere((item) => item['id']?.toString() == locationId);
      notifyListeners();
    } catch (e) {
      debugPrint('[FavoriteBackend] removeFavorite error: $e');
    }
  }

  /// Membuat data yang disimpan ke Box (hanya tipe dasar: String, num, bool, List).
  /// LatLng tidak disimpan langsung, melainkan sebagai latitude & longitude.
  Map<String, dynamic> _buildRecord(String userId, String locationId, Map<String, dynamic>? location) {
    final src = location ?? const <String, dynamic>{};

    final record = <String, dynamic>{
      'user_id': userId,
      'location_id': locationId,
      'saved_at': DateTime.now().millisecondsSinceEpoch,
      'code': src['code']?.toString(),
      'name': src['name']?.toString(),
      'type': src['type']?.toString(),
      'city': src['city']?.toString(),
      'address': src['address']?.toString(),
      'latitude': (src['latitude'] as num?)?.toDouble(),
      'longitude': (src['longitude'] as num?)?.toDouble(),
      'total_capacity': (src['total_capacity'] as num?)?.toInt(),
      'hourly_rate_mobil': (src['hourly_rate_mobil'] as num?)?.toInt(),
      'hourly_rate_motor': (src['hourly_rate_motor'] as num?)?.toInt(),
      'hourly_rate_ev': (src['hourly_rate_ev'] as num?)?.toInt(),
      'rating': (src['rating'] as num?)?.toDouble(),
      'review_count': (src['review_count'] as num?)?.toInt(),
      'status': src['status']?.toString(),
      'image_url': src['image_url']?.toString(),
      'facilities': (src['facilities'] as List?)?.map((e) => e.toString()).toList() ?? <String>[],
    };

    record.removeWhere((key, value) => value == null);
    return record;
  }

  /// Mengubah data dari Box menjadi format yang dipakai FavoriteScreen.
  Map<String, dynamic> _toDisplayMap(Map<String, dynamic> row) {
    final lat = (row['latitude'] as num?)?.toDouble() ?? -6.1788;
    final lng = (row['longitude'] as num?)?.toDouble() ?? 106.7916;
    final rateMobil = (row['hourly_rate_mobil'] as num?)?.toInt() ?? 5000;
    final rateEv = (row['hourly_rate_ev'] as num?)?.toInt() ?? 7500;
    final rateMotor = (row['hourly_rate_motor'] as num?)?.toInt() ?? 2000;
    final capacity = (row['total_capacity'] as num?)?.toInt() ?? 40;
    final facilities = (row['facilities'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
    final bool isEv = facilities.any((f) => f.toLowerCase().contains('ev'));
    final activeRate = isEv ? rateEv : rateMobil;

    return {
      'id': row['location_id'],
      'name': row['name'] ?? 'Spot Parkir',
      'type': row['type'] ?? 'Parkiran Mall',
      'point': LatLng(lat, lng),
      'slots': capacity,
      'isEv': isEv,
      'distance': '500m',
      'price': '${CurrencyService.instance.format(activeRate)} / jam',
      'rating': (row['rating'] as num?)?.toDouble() ?? 4.7,
      'reviews': '${row['review_count'] ?? 1000}',
      'hours': row['status'] == 'open' ? 'Buka 24 Jam' : 'Tutup Sementara',
      'hourly_rate_mobil': rateMobil,
      'hourly_rate_motor': rateMotor,
      'hourly_rate_ev': rateEv,
      'hourly_rate_active': activeRate,
      'photos': [
        (row['image_url'] ?? _defaultImage).toString(),
      ],
    };
  }
}
