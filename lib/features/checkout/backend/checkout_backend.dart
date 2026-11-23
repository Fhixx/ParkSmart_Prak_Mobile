import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/services/session_service.dart';
import '../../home/backend/home_backend.dart';
import '../../profile/backend/profile_backend.dart';
import '../../profile/backend/payment_methods_backend.dart';


class CheckoutBackend extends ChangeNotifier {
  CheckoutBackend._();
  static final CheckoutBackend instance = CheckoutBackend._();

  SupabaseClient get _client => Supabase.instance.client;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _userId;
  void setUserId(String id) {
    _userId = id;
  }

  String? _holdBookingId;
  String? get holdBookingId => _holdBookingId;

  DateTime? _holdCreatedAt;
  DateTime? get holdCreatedAt => _holdCreatedAt;

  bool get isSlotHeld => _holdBookingId != null && _holdBookingId!.isNotEmpty;

  String? _lastPaymentError;
  String? get lastPaymentError => _lastPaymentError;

  void clear() {
    _userId = null;
    _selectedVehicle = null;
    _userVehicles = [];
    _walletBalance = 0;
    _locationName = '-';
    _locationId = null;
    _slotId = null;
    _slotCode = '-';
    _floorName = '-';
    _holdBookingId = null;
    _holdCreatedAt = null;
    _lastPaymentError = null;
    notifyListeners();
  }

  String get userId {
    if (_userId != null && _userId!.isNotEmpty) return _userId!;
    if (SessionService.instance.userId != null && SessionService.instance.userId!.isNotEmpty) {
      return SessionService.instance.userId!;
    }
    final pid = ProfileBackend.instance.userId;
    if (pid.isNotEmpty) return pid;
    if (HomeBackend.instance.userId.isNotEmpty) {
      return HomeBackend.instance.userId;
    }
    return '';
  }

 
  Future<String> resolveUserId() async {
    final cur = userId;
    if (cur.isNotEmpty) return cur;

    final prefs = await SharedPreferences.getInstance();
    final prefUid = prefs.getString('user_profile_id') ?? prefs.getString('ps_session_user_id');
    if (prefUid != null && prefUid.isNotEmpty) {
      _userId = prefUid;
      return prefUid;
    }

    final authUser = _client.auth.currentUser;
    if (authUser != null) {
      try {
        final row = await _client.from('users').select('id').eq('auth_user_id', authUser.id).maybeSingle();
        if (row != null && row['id'] != null) {
          _userId = row['id'].toString();
          return _userId!;
        }
      } catch (_) {}
    }

    final email = SessionService.instance.identifier ?? ProfileBackend.instance.email;
    if (email.isNotEmpty) {
      try {
        final row = await _client.from('users').select('id').eq('email', email).maybeSingle();
        if (row != null && row['id'] != null) {
          _userId = row['id'].toString();
          return _userId!;
        }
      } catch (_) {}
    }

    return '';
  }

  Map<String, dynamic>? _selectedVehicle;
  Map<String, dynamic>? get selectedVehicle => _selectedVehicle;

  List<Map<String, dynamic>> _userVehicles = [];
  List<Map<String, dynamic>> get userVehicles => _userVehicles;

  double _walletBalance = 0;
  double get walletBalance => _walletBalance;


  String _locationName = '-';
  String get locationName => _locationName;

  String? _locationId;
  String? get locationId => _locationId;

  String? _slotId;
  String? get slotId => _slotId;

  String _slotCode = '-';
  String get slotCode => _slotCode;

  String _floorName = '-';
  String get floorName => _floorName;

  String _slotType = 'Slot Reguler';
  String get slotType => _slotType;

  DateTime? _scheduledStartTime;
  DateTime? get scheduledStartTime => _scheduledStartTime;

  DateTime? _scheduledEndTime;
  DateTime? get scheduledEndTime => _scheduledEndTime;

  int _durationHours = 1;
  int get durationHours => _durationHours;

  // ============================================================================
  // [UBAH TARIF, BIAYA LAYANAN, DISKON]
  // Rumus harga: subtotal = durasi(jam) x tarif/jam ; total = subtotal - diskon (+ biaya layanan jika dipakai).
  // - Tarif default: `_hourlyRate = 5000` (dipakai kalau data lokasi belum mengisi tarif; tarif asli dari
  //   tabel parking_locations lewat setBookingDetails(hourlyRate: ...)).
  // - Biaya layanan: ubah `serviceFee => 0` jadi mis. 2000, LALU tambahkan ke `totalPayment`
  //   (sekarang totalPayment hanya subtotal - discountAmount, jadi serviceFee belum ikut dihitung!).
  // - Diskon: ubah `discountAmount` mis. `subtotal * 0.1` untuk diskon 10%.
  // Total ini yang dikirim ke bookings.total_price dan dipotong dari wallet di markBookingAsPaid.
  // ============================================================================
  double _hourlyRate = 5000;
  double get hourlyRate => _hourlyRate;

  double get subtotal => _durationHours * _hourlyRate;
  double get serviceFee => 0; // Tanpa biaya layanan
  double get discountAmount => 0;
  double get totalPayment => subtotal - discountAmount;

  void setBookingDetails({
    String? locationId,
    String? locationName,
    String? slotId,
    String? slotCode,
    String? floorName,
    String? slotType,
    int? durationHours,
    double? hourlyRate,
    DateTime? startTime,
    DateTime? endTime,
  }) {
    if (locationId != null) _locationId = locationId;
    if (locationName != null) _locationName = locationName;
    if (slotId != null) _slotId = slotId;
    if (slotCode != null) _slotCode = slotCode;
    if (floorName != null) _floorName = floorName;
    if (slotType != null) _slotType = slotType;
    if (durationHours != null) _durationHours = durationHours;
    if (hourlyRate != null) _hourlyRate = hourlyRate;
    if (startTime != null) _scheduledStartTime = startTime;
    if (endTime != null) _scheduledEndTime = endTime;
    notifyListeners();
  }

  
  Future<void> fetchCheckoutData() async {
    _isLoading = true;
    notifyListeners();

    try {
      final uid = await resolveUserId();
      if (uid.isEmpty) return;


      final userRes = await _client
          .from('users')
          .select('id, full_name, wallet_balance, points')
          .eq('id', uid)
          .maybeSingle();

      if (userRes != null) {
        _walletBalance = (userRes['wallet_balance'] as num?)?.toDouble() ?? 0.0;
      }

   
      final vehiclesRes = await _client
          .from('vehicles')
          .select('id, brand, model, color, plate_number, vehicle_type, is_default')
          .eq('user_id', uid)
          .order('is_default', ascending: false);

      _userVehicles = List<Map<String, dynamic>>.from(vehiclesRes);
      if (_userVehicles.isNotEmpty) {
        _selectedVehicle = _userVehicles.first;
      } else {
        _selectedVehicle = null;
      }
    } catch (e) {
      debugPrint('[CheckoutBackend] fetchCheckoutData error: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void selectVehicle(Map<String, dynamic> vehicle) {
    _selectedVehicle = vehicle;
    _updateRateForVehicle(vehicle);
    notifyListeners();
  }

  Future<void> _updateRateForVehicle(Map<String, dynamic>? vehicle) async {
    if (_locationId == null || _locationId!.isEmpty) return;
    try {
      final loc = await _client
          .from('parking_locations')
          .select('hourly_rate_mobil, hourly_rate_motor, hourly_rate_ev')
          .eq('id', _locationId!)
          .maybeSingle();
      if (loc != null) {
        final vType = vehicle?['vehicle_type']?.toString().toLowerCase();
        final isEvSlot = _slotType.toLowerCase().contains('ev');
        final isMotorSlot = _slotType.toLowerCase().contains('motor');

        if (isEvSlot || vType == 'ev') {
          _hourlyRate = (loc['hourly_rate_ev'] as num?)?.toDouble() ?? _hourlyRate;
        } else if (isMotorSlot || vType == 'motor') {
          _hourlyRate = (loc['hourly_rate_motor'] as num?)?.toDouble() ?? _hourlyRate;
        } else {
          _hourlyRate = (loc['hourly_rate_mobil'] as num?)?.toDouble() ?? _hourlyRate;
        }
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> confirmAndCreateBooking() async {
    _isLoading = true;
    notifyListeners();

    try {
      final random = Random();
      final bookingCode = 'BK-${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}-${random.nextInt(900) + 100}';

      final now = DateTime.now();
      final startTime = _scheduledStartTime ?? now;
      final endTime = _scheduledEndTime ?? startTime.add(Duration(hours: _durationHours));

  
      String? actualLocId = _locationId;
      if (actualLocId == null || actualLocId.isEmpty) {
        final loc = await _client
            .from('parking_locations')
            .select('id, name')
            .order('rating', ascending: false)
            .limit(1)
            .maybeSingle();
        actualLocId = loc?['id'] as String?;
        if (loc != null && _locationName == '-') {
          _locationName = loc['name']?.toString() ?? 'ParkSmart';
        }
      }

      if (actualLocId == null) {
        throw Exception('Lokasi parkir tidak ditemukan di database.');
      }


      String? actualSlotId = _slotId;
      if ((actualSlotId == null || actualSlotId.isEmpty) && _slotCode != '-' && _slotCode.isNotEmpty) {
        final slotRes = await _client
            .from('parking_slots')
            .select('id')
            .eq('location_id', actualLocId)
            .eq('slot_code', _slotCode)
            .maybeSingle();
        actualSlotId = slotRes?['id'] as String?;
      }

      if (actualSlotId != null) {
        final hasConflict = await checkSlotConflict(
          slotId: actualSlotId,
          startTime: startTime,
          endTime: endTime,
        );
        if (hasConflict) {
          throw Exception('Slot ini sudah dibooking oleh pengguna lain pada rentang jam tersebut.');
        }
      }

      final actualUid = await resolveUserId();
      if (actualUid.isEmpty) {
        throw Exception('Sesi pengguna tidak valid. Silakan login kembali.');
      }

      final veh = _selectedVehicle;
      final vehicleDesc = veh != null
          ? ('${veh['brand'] ?? ''} ${veh['model'] ?? ''}'.trim().isNotEmpty
              ? '${veh['brand'] ?? ''} ${veh['model'] ?? ''}'.trim()
              : 'Toyota Land Cruiser')
          : 'Toyota Land Cruiser';
      final plateNumber = veh != null ? (veh['plate_number'] ?? 'B 1945 RI') : 'B 1945 RI';
      
      if (_holdBookingId != null && _holdBookingId!.isNotEmpty) {
        final updated = await _client
            .from('bookings')
            .update({
              'duration_hours': _durationHours,
              'total_price': totalPayment,
              'start_time': startTime.toUtc().toIso8601String(),
              'end_time': endTime.toUtc().toIso8601String(),
              'vehicle_id': _selectedVehicle?['id'],
              'plate_number': plateNumber,
              'vehicle_desc': vehicleDesc,
              if (actualLocId.isNotEmpty) 'location_id': actualLocId,
              if (actualSlotId != null && actualSlotId.isNotEmpty) 'slot_id': actualSlotId,
            })
            .eq('id', _holdBookingId!)
            .select('id, booking_code, total_price, duration_hours, start_time, end_time, location_id, slot_id, created_at, plate_number, vehicle_desc')
            .maybeSingle();

        if (updated != null) {
          if (_holdCreatedAt == null && updated['created_at'] != null) {
            _holdCreatedAt = DateTime.tryParse(updated['created_at'].toString())?.toLocal();
          }
          return updated;
        }
      }

      
      final bookingInsert = await _client.from('bookings').insert({
        'booking_code': bookingCode,
        'user_id': actualUid,
        'location_id': actualLocId,
        'slot_id': actualSlotId,
        'vehicle_id': _selectedVehicle?['id'],
        'plate_number': plateNumber,
        'vehicle_desc': vehicleDesc,
        'booking_type': 'reservation',
        'start_time': startTime.toUtc().toIso8601String(),
        'end_time': endTime.toUtc().toIso8601String(),
        'duration_hours': _durationHours,
        'total_price': totalPayment,
        'payment_status': 'unpaid',
        'booking_status': 'upcoming',
        'qr_code_hash': 'PARKSMART-$bookingCode',
      }).select('id, booking_code, total_price, start_time, end_time, location_id, slot_id, created_at, plate_number, vehicle_desc').maybeSingle();

      if (bookingInsert != null) {
        _holdBookingId = bookingInsert['id']?.toString();
        _holdCreatedAt = DateTime.tryParse(bookingInsert['created_at'].toString())?.toLocal() ?? DateTime.now();
      }

   
      if (actualSlotId != null) {
        await _client.from('parking_slots').update({
          'status': 'reserved',
        }).eq('id', actualSlotId);
      }

      return bookingInsert ?? {
        'id': 'mock-booking-${DateTime.now().millisecondsSinceEpoch}',
        'booking_code': bookingCode,
        'total_price': totalPayment,
        'start_time': startTime.toUtc().toIso8601String(),
        'end_time': endTime.toUtc().toIso8601String(),
        'created_at': DateTime.now().toIso8601String(),
      };
    } catch (e) {
      debugPrint('[CheckoutBackend] confirmAndCreateBooking error: $e');
      return null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> createHoldBooking() async {
    try {
      final now = DateTime.now();
      final startTime = _scheduledStartTime ?? now;
      final endTime = _scheduledEndTime ?? startTime.add(Duration(hours: _durationHours));

     
      String? actualLocId = _locationId;
      if (actualLocId == null || actualLocId.isEmpty) {
        final loc = await _client
            .from('parking_locations')
            .select('id, name')
            .order('rating', ascending: false)
            .limit(1)
            .maybeSingle();
        actualLocId = loc?['id'] as String?;
        if (loc != null && _locationName == '-') {
          _locationName = loc['name']?.toString() ?? 'ParkSmart';
        }
      }

      if (actualLocId == null) return false;


      String? actualSlotId = _slotId;
      if ((actualSlotId == null || actualSlotId.isEmpty) && _slotCode != '-' && _slotCode.isNotEmpty) {
        final slotRes = await _client
            .from('parking_slots')
            .select('id')
            .eq('location_id', actualLocId)
            .eq('slot_code', _slotCode)
            .maybeSingle();
        actualSlotId = slotRes?['id'] as String?;
      }


      if (actualSlotId != null) {
        final hasConflict = await checkSlotConflict(
          slotId: actualSlotId,
          startTime: startTime,
          endTime: endTime,
        );
        if (hasConflict) return false;
      }

      final actualUid = await resolveUserId();
      if (actualUid.isEmpty) return false;

      final random = Random();
      final bookingCode = 'BK-${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}-${random.nextInt(900) + 100}';

      final veh = _selectedVehicle;
      final vehicleDesc = veh != null
          ? ('${veh['brand'] ?? ''} ${veh['model'] ?? ''}'.trim().isNotEmpty
              ? '${veh['brand'] ?? ''} ${veh['model'] ?? ''}'.trim()
              : 'Toyota Land Cruiser')
          : 'Toyota Land Cruiser';
      final plateNumber = veh != null ? (veh['plate_number'] ?? 'B 1945 RI') : 'B 1945 RI';


      final result = await _client.from('bookings').insert({
        'booking_code': bookingCode,
        'user_id': actualUid,
        'location_id': actualLocId,
        'slot_id': actualSlotId,
        'vehicle_id': _selectedVehicle?['id'],
        'plate_number': plateNumber,
        'vehicle_desc': vehicleDesc,
        'booking_type': 'reservation',
        'start_time': startTime.toUtc().toIso8601String(),
        'end_time': endTime.toUtc().toIso8601String(),
        'duration_hours': _durationHours,
        'total_price': totalPayment,
        'payment_status': 'unpaid',
        'booking_status': 'upcoming',
        'qr_code_hash': 'PARKSMART-$bookingCode',
      }).select('id, created_at').maybeSingle();

      if (result != null) {
        _holdBookingId = result['id']?.toString();
        _holdCreatedAt = DateTime.tryParse(result['created_at'].toString())?.toLocal() ?? DateTime.now();

       
        if (actualSlotId != null) {
          await _client.from('parking_slots').update({
            'status': 'reserved',
          }).eq('id', actualSlotId);
        }
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[CheckoutBackend] createHoldBooking error: $e');
      return false;
    }
  }


  Future<void> cancelHoldBooking({String? bookingId}) async {
    final targetId = bookingId ?? _holdBookingId;
    if (targetId == null || targetId.isEmpty) return;

    try {
      final b = await _client
          .from('bookings')
          .select('slot_id, payment_status')
          .eq('id', targetId)
          .maybeSingle();

      if (b != null && (b['payment_status'] == 'unpaid' || b['payment_status'] == 'pending')) {
        await _client.from('bookings').update({
          'booking_status': 'cancelled',
          'cancel_reason': 'Batas waktu pembayaran 2 menit 59 detik telah habis atau dibatalkan pengguna',
        }).eq('id', targetId);

        final sId = b['slot_id']?.toString() ?? _slotId;
        if (sId != null && sId.isNotEmpty) {
          await _client.from('parking_slots').update({
            'status': 'available',
            'current_plate_number': null,
            'occupied_since': null,
          }).eq('id', sId);
        }
      }

      if (targetId == _holdBookingId) {
        _holdBookingId = null;
        _holdCreatedAt = null;
      }


      try {
        await _client.rpc('auto_process_expired_bookings_and_sessions');
      } catch (_) {}

      notifyListeners();
    } catch (e) {
      debugPrint('[CheckoutBackend] cancelHoldBooking error: $e');
    }
  }

 
  Future<bool> loadFromExistingBooking(String bookingId) async {
    try {
      var b = await _client
          .from('bookings')
          .select('id, created_at, booking_code, start_time, end_time, duration_hours, total_price, location_id, slot_id, vehicle_id, plate_number, vehicle_desc, payment_status')
          .eq('id', bookingId)
          .maybeSingle();

      if (b == null) {
      
        final s = await _client
            .from('parking_sessions')
            .select('booking_id')
            .eq('id', bookingId)
            .maybeSingle();
        if (s != null && s['booking_id'] != null) {
          b = await _client
              .from('bookings')
              .select('id, created_at, booking_code, start_time, end_time, duration_hours, total_price, location_id, slot_id, vehicle_id, plate_number, vehicle_desc, payment_status')
              .eq('id', s['booking_id'].toString())
              .maybeSingle();
        }
      }

      if (b == null) return false;

      _holdBookingId = b['id']?.toString();
      _holdCreatedAt = DateTime.tryParse(b['created_at'].toString())?.toLocal() ?? DateTime.now();
      _scheduledStartTime = DateTime.tryParse(b['start_time'].toString())?.toLocal();
      _scheduledEndTime = DateTime.tryParse(b['end_time'].toString())?.toLocal();
      _durationHours = (b['duration_hours'] as num?)?.toInt() ?? 1;
      final tPrice = (b['total_price'] as num?)?.toDouble() ?? 5000.0;
      _hourlyRate = _durationHours > 0 ? (tPrice / _durationHours) : 5000.0;

      if (b['location_id'] != null) {
        _locationId = b['location_id'].toString();
        final loc = await _client
            .from('parking_locations')
            .select('id, name')
            .eq('id', _locationId!)
            .maybeSingle();
        if (loc != null) {
          _locationName = loc['name']?.toString() ?? _locationName;
        }
      }

      if (b['slot_id'] != null) {
        _slotId = b['slot_id'].toString();
        final slot = await _client
            .from('parking_slots')
            .select('slot_code, floor_name, slot_type')
            .eq('id', _slotId!)
            .maybeSingle();
        if (slot != null) {
          _slotCode = slot['slot_code']?.toString() ?? _slotCode;
          _floorName = slot['floor_name']?.toString() ?? _floorName;
          _slotType = slot['slot_type']?.toString() ?? _slotType;
        }
      }

      final pNum = b['plate_number']?.toString();
      final vDesc = b['vehicle_desc']?.toString();
      _selectedVehicle = {
        'id': b['vehicle_id'],
        'plate_number': pNum ?? 'B 1945 RI',
        'brand': vDesc ?? 'Kendaraan',
        'model': '',
      };

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[CheckoutBackend] loadFromExistingBooking error: $e');
      return false;
    }
  }

  Future<bool> checkSlotConflict({
    String? slotId,
    String? slotCode,
    String? locationId,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    try {

      try {
        await _client.rpc('auto_process_expired_bookings_and_sessions');
      } catch (_) {}

      String? targetSlotId = slotId ?? _slotId;
      if (targetSlotId == null || targetSlotId.isEmpty) {
        final locId = locationId ?? _locationId;
        final sCode = slotCode ?? _slotCode;
        if (locId != null && sCode.isNotEmpty && sCode != '-') {
          final sRes = await _client
              .from('parking_slots')
              .select('id')
              .eq('location_id', locId)
              .eq('slot_code', sCode)
              .maybeSingle();
          targetSlotId = sRes?['id'] as String?;
        }
      }
      if (targetSlotId == null) return false;

      final now = DateTime.now();
      final bookings = await _client
          .from('bookings')
          .select('id, start_time, end_time, booking_status, payment_status, created_at')
          .eq('slot_id', targetSlotId)
          .not('booking_status', 'in', '(cancelled,completed,expired)');

      for (final b in bookings) {
        final bId = b['id']?.toString();
  
        if (_holdBookingId != null && bId == _holdBookingId) {
          continue;
        }


        final payStatus = (b['payment_status'] ?? '').toString().toLowerCase();
        if (payStatus == 'unpaid') {
          final cat = DateTime.tryParse(b['created_at']?.toString() ?? '')?.toLocal();
          if (cat != null && now.difference(cat).inSeconds > 179) {
            continue;
          }
        }

        final bStart = DateTime.parse(b['start_time'].toString()).toLocal();
        final bEnd = DateTime.parse(b['end_time'].toString()).toLocal();


        if (bEnd.isBefore(now) || bEnd.isAtSameMomentAs(now)) {
          continue;
        }

   
        if (startTime.isBefore(bEnd) && endTime.isAfter(bStart)) {
          return true;
        }
      }
      return false;
    } catch (e) {
      debugPrint('[CheckoutBackend] checkSlotConflict error: $e');
      return false;
    }
  }

 
  Future<List<AvailableTimeWindow>> getAvailableTimeSlotsToday({
    String? slotId,
    String? slotCode,
    String? locationId,
  }) async {
    try {
      try {
        await _client.rpc('auto_process_expired_bookings_and_sessions');
      } catch (_) {}

      String? targetSlotId = slotId ?? _slotId;
      if (targetSlotId == null || targetSlotId.isEmpty) {
        final locId = locationId ?? _locationId;
        final sCode = slotCode ?? _slotCode;
        if (locId != null && sCode.isNotEmpty && sCode != '-') {
          final sRes = await _client
              .from('parking_slots')
              .select('id')
              .eq('location_id', locId)
              .eq('slot_code', sCode)
              .maybeSingle();
          targetSlotId = sRes?['id'] as String?;
        }
      }
      if (targetSlotId == null) return [];

      final now = DateTime.now();
      final windowStart = now;
      final windowEnd = DateTime(now.year, now.month, now.day, 23, 59);

      if (windowStart.isAfter(windowEnd)) return [];

      final bookings = await _client
          .from('bookings')
          .select('id, start_time, end_time, booking_status, payment_status, created_at')
          .eq('slot_id', targetSlotId)
          .not('booking_status', 'in', '(cancelled,completed,expired)');

      List<Map<String, DateTime>> bookedIntervals = [];
      for (final b in bookings) {
        final bId = b['id']?.toString();

        if (_holdBookingId != null && bId == _holdBookingId) {
          continue;
        }


        final payStatus = (b['payment_status'] ?? '').toString().toLowerCase();
        if (payStatus == 'unpaid') {
          final cat = DateTime.tryParse(b['created_at']?.toString() ?? '')?.toLocal();
          if (cat != null && now.difference(cat).inSeconds > 179) {
            continue;
          }
        }

        final bStart = DateTime.parse(b['start_time'].toString()).toLocal();
        final bEnd = DateTime.parse(b['end_time'].toString()).toLocal();

        if (bEnd.isBefore(windowStart) || bStart.isAfter(windowEnd)) continue;

        final clampedStart = bStart.isBefore(windowStart) ? windowStart : bStart;
        final clampedEnd = bEnd.isAfter(windowEnd) ? windowEnd : bEnd;

        if (clampedEnd.isAfter(clampedStart)) {
          bookedIntervals.add({'start': clampedStart, 'end': clampedEnd});
        }
      }

      bookedIntervals.sort((a, b) => a['start']!.compareTo(b['start']!));

  
      List<Map<String, DateTime>> merged = [];
      for (final interval in bookedIntervals) {
        if (merged.isEmpty) {
          merged.add(Map.from(interval));
        } else {
          final last = merged.last;
          if (interval['start']!.isBefore(last['end']!) ||
              interval['start']!.isAtSameMomentAs(last['end']!)) {
            if (interval['end']!.isAfter(last['end']!)) {
              last['end'] = interval['end']!;
            }
          } else {
            merged.add(Map.from(interval));
          }
        }
      }

   
      List<AvailableTimeWindow> windows = [];
      DateTime ptr = windowStart;

      for (final booked in merged) {
        if (booked['start']!.isAfter(ptr)) {
          final diff = booked['start']!.difference(ptr).inMinutes;
          if (diff >= 15) {
            windows.add(_createWindow(ptr, booked['start']!));
          }
        }
        if (booked['end']!.isAfter(ptr)) {
          ptr = booked['end']!;
        }
      }

      if (windowEnd.isAfter(ptr)) {
        final diff = windowEnd.difference(ptr).inMinutes;
        if (diff >= 15) {
          windows.add(_createWindow(ptr, windowEnd));
        }
      }

      return windows;
    } catch (e) {
      debugPrint('[CheckoutBackend] getAvailableTimeSlotsToday error: $e');
      return [];
    }
  }

  AvailableTimeWindow _createWindow(DateTime start, DateTime end) {
    final startStr = '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}';
    final endStr = '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
    final diffMinutes = end.difference(start).inMinutes;
    final hours = diffMinutes ~/ 60;
    final mins = diffMinutes % 60;
    String durText = '';
    if (hours > 0 && mins > 0) {
      durText = '$hours jam $mins mnt';
    } else if (hours > 0) {
      durText = '$hours jam';
    } else {
      durText = '$mins mnt';
    }
    return AvailableTimeWindow(
      start: start,
      end: end,
      label: '$startStr - $endStr WIB',
      durationLabel: durText,
    );
  }

  Future<bool> markBookingAsPaid(String bookingId) async {
    try {
      _lastPaymentError = null;
      final bRes = await _client
          .from('bookings')
          .select('id, total_price, user_id, booking_code, location_id, slot_id, booking_status, payment_status, created_at, parking_locations(name), parking_slots(slot_code)')
          .eq('id', bookingId)
          .maybeSingle();
      if (bRes == null) {
        _lastPaymentError = 'Data booking tidak ditemukan.';
        return false;
      }

      final bStatus = (bRes['booking_status'] ?? '').toString().toLowerCase();
      if (bStatus == 'cancelled' || bStatus == 'expired') {
        _lastPaymentError = 'Batas waktu pembayaran 2 menit 59 detik telah habis atau booking telah dibatalkan.';
        return false;
      }

      final payStatus = (bRes['payment_status'] ?? '').toString().toLowerCase();
      if (payStatus == 'unpaid') {
        final cat = DateTime.tryParse(bRes['created_at']?.toString() ?? '')?.toLocal();
        if (cat != null && DateTime.now().difference(cat).inSeconds > 179) {
          _lastPaymentError = 'Batas waktu pembayaran 2 menit 59 detik telah habis. Slot telah dilepas.';
          await cancelHoldBooking(bookingId: bookingId);
          return false;
        }
      }

      final now = DateTime.now();
      final startTime = _scheduledStartTime ?? now;
      final endTime = _scheduledEndTime ?? startTime.add(Duration(hours: _durationHours));
      final price = totalPayment > 0 ? totalPayment : ((bRes['total_price'] as num?)?.toDouble() ?? 5000.0);
      final actualUserId = (bRes['user_id'] != null && bRes['user_id'].toString().isNotEmpty)
          ? bRes['user_id'].toString()
          : (await resolveUserId());
      final bCode = bRes['booking_code']?.toString() ?? '';
      final locName = bRes['parking_locations']?['name']?.toString() ?? _locationName;
      final sCode = bRes['parking_slots']?['slot_code']?.toString() ?? _slotCode;


      final selectedMethod = PaymentMethodsBackend.instance.selectedMethod;
      final isParkSmart = selectedMethod == 'parksmart_pay' || selectedMethod == 'wallet';

      if (isParkSmart) {
        
        final userRes = await _client
            .from('users')
            .select('wallet_balance, total_parking_count, total_spent')
            .eq('id', actualUserId)
            .maybeSingle();
        final currentBal = (userRes?['wallet_balance'] as num?)?.toDouble() ?? 0.0;
        
        _walletBalance = currentBal;

        if (currentBal < price) {
          debugPrint('[CheckoutBackend] markBookingAsPaid ditolak: Saldo tidak mencukupi (Saldo: $currentBal, Dibutuhkan: $price)');
          _lastPaymentError = 'insufficient_balance';
          return false;
        }

        final newBalance = currentBal - price;
        final currentCount = (userRes?['total_parking_count'] as num?)?.toInt() ?? 0;
        final currentTotalSpent = (userRes?['total_spent'] as num?)?.toDouble() ?? 0.0;

       
        await _client.from('users').update({
          'wallet_balance': newBalance,
          'total_parking_count': currentCount + 1,
          'total_spent': currentTotalSpent + price,
        }).eq('id', actualUserId);

        _walletBalance = newBalance;
        ProfileBackend.instance.setLoggedInUser(
          id: actualUserId,
          fullName: ProfileBackend.instance.name,
          email: ProfileBackend.instance.email,
          phone: ProfileBackend.instance.phone,
          walletBalance: newBalance.toInt(),
        );
      } else {

        final userRes = await _client
            .from('users')
            .select('total_parking_count, total_spent')
            .eq('id', actualUserId)
            .maybeSingle();
        final currentCount = (userRes?['total_parking_count'] as num?)?.toInt() ?? 0;
        final currentTotalSpent = (userRes?['total_spent'] as num?)?.toDouble() ?? 0.0;
        // Update parking count dan total_spent untuk membership tier (tanpa potong wallet)
        await _client.from('users').update({
          'total_parking_count': currentCount + 1,
          'total_spent': currentTotalSpent + price,
        }).eq('id', actualUserId);
      }

    
      await _client.from('bookings').update({
        'payment_status': 'paid',
        'booking_status': 'upcoming',
        'duration_hours': _durationHours,
        'total_price': price,
        'start_time': startTime.toUtc().toIso8601String(),
        'end_time': endTime.toUtc().toIso8601String(),
      }).eq('id', bookingId);


      final trxCode = 'TRX-${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}';
      await _client.from('payments').insert({
        'transaction_code': trxCode,
        'user_id': actualUserId,
        'booking_id': bookingId,
        'transaction_type': 'parking_payment',
        'payment_method': isParkSmart ? 'wallet' : selectedMethod,
        'amount': price,
        'description': 'Reservasi Parkir $locName Slot $sCode ($bCode)',
        'status': 'success',
        'completed_at': DateTime.now().toIso8601String(),
      });

  
      if (bRes['slot_id'] != null) {
        await _client.from('parking_slots').update({
          'status': 'reserved',
        }).eq('id', bRes['slot_id']);
      }

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[CheckoutBackend] markBookingAsPaid error: $e');
      return false;
    }
  }
}

class AvailableTimeWindow {
  final DateTime start;
  final DateTime end;
  final String label;
  final String durationLabel;

  const AvailableTimeWindow({
    required this.start,
    required this.end,
    required this.label,
    required this.durationLabel,
  });
}

