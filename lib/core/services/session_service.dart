import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'parking_notification_service.dart';
import '../../features/auth/login_screen.dart';
import '../../features/profile/backend/profile_backend.dart';
import '../../features/profile/backend/payment_methods_backend.dart';
import '../../features/profile/backend/vehicle_backend.dart';
import '../../features/checkout/backend/checkout_backend.dart';
import '../../features/home/backend/home_backend.dart';
import '../../features/history/backend/history_backend.dart';
import '../../features/history/backend/verified_parking_sessions_backend.dart';
import '../../features/notification/backend/notification_backend.dart';
import '../../main.dart' show navigatorKey;

class SessionService with WidgetsBindingObserver {
  static final SessionService instance = SessionService._internal();
  factory SessionService() => instance;
  SessionService._internal();

  // ============================================================================
  // [UBAH BATAS SESI LOGIN]
  // Diminta: "ganti auto-logout jadi 1 menit" / "jadi 2 jam".
  // Ubah: nilai di `sessionTimeout` di bawah (Duration(minutes: 30) -> Duration(minutes: 1)).
  // Untuk demo cepat: Duration(seconds: 20). Pengecekan berjalan tiap 10 detik (_inactivityCheckTimer),
  // jadi logout bisa terlambat sampai 10 detik. Teks log 'Inactivity timeout ... 30 menit' di bawah hanya
  // pesan debug, tidak memengaruhi perilaku. Hot restart (bukan hot reload) agar const terbaca ulang.
  // ============================================================================
  /// Durasi batas waktu sesi tidak aktif / latar belakang: 30 Menit
  static const Duration sessionTimeout = Duration(minutes: 30);


  static const String _kIsLoggedIn = 'ps_session_is_logged_in';
  static const String _kUserType = 'ps_session_user_type';
  static const String _kIdentifier = 'ps_session_identifier';
  static const String _kUserId = 'ps_session_user_id';
  static const String _kUserName = 'ps_session_user_name';
  static const String _kAdminRole = 'ps_session_admin_role';
  static const String _kLastActiveTime = 'ps_session_last_active_time';
  static const String _kBackgroundTime = 'ps_session_background_time';


  bool _isLoggedIn = false;
  String? _userType; // 'user' | 'admin'
  String? _identifier;
  String? _userId;
  String? _userName;
  String? _adminRole;
  DateTime? _lastActiveTime;
  DateTime? _backgroundTime;
  DateTime? _lastDiskWriteTime;

  bool _sessionExpiredOnStartup = false;
  bool get sessionExpiredOnStartup => _sessionExpiredOnStartup;

  Timer? _inactivityCheckTimer;
  Timer? _backgroundTimeoutTimer;

  bool get isLoggedIn => _isLoggedIn;
  String? get userType => _userType;
  bool get isAdmin => _isLoggedIn && _userType == 'admin';
  String? get identifier => _identifier;
  String? get userId => _userId;
  String? get userName => _userName;
  String? get adminRole => _adminRole;

  /// Sisa waktu sesi aktif sebelum logout otomatis
  Duration get remainingTime {
    if (!_isLoggedIn || _lastActiveTime == null) return Duration.zero;
    final elapsed = DateTime.now().difference(_lastActiveTime!);
    final remaining = sessionTimeout - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Format sisa waktu menit:detik (contoh: 29:45)
  String get formattedRemainingTime {
    final rem = remainingTime;
    final minutes = rem.inMinutes;
    final seconds = rem.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

 
  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);

    try {
      final prefs = await SharedPreferences.getInstance();
      _isLoggedIn = prefs.getBool(_kIsLoggedIn) ?? false;
      _userType = prefs.getString(_kUserType);
      _identifier = prefs.getString(_kIdentifier);
      _userId = prefs.getString(_kUserId);
      _userName = prefs.getString(_kUserName);
      _adminRole = prefs.getString(_kAdminRole);

      final lastActiveMs = prefs.getInt(_kLastActiveTime);
      final backgroundMs = prefs.getInt(_kBackgroundTime);

      if (_isLoggedIn) {
        final referenceMs = backgroundMs ?? lastActiveMs;
        if (referenceMs != null && referenceMs > 0) {
          final referenceTime = DateTime.fromMillisecondsSinceEpoch(referenceMs);
          final elapsed = DateTime.now().difference(referenceTime);

          if (elapsed >= sessionTimeout) {
    
            debugPrint('[SessionService] Sesi kedaluwarsa saat cold start: $elapsed > 30 menit. Auto logout.');
            await clearSession();
            _sessionExpiredOnStartup = true;
          } else {
         
            _lastActiveTime = DateTime.now();
            await _persistLastActiveTime(_lastActiveTime!);
            _startInactivityCheckTimer();
            if (_userType == 'user') {
              ParkingNotificationService().startRealtimeUrgentListener();
            } else if (_userType == 'admin') {
              ParkingNotificationService().stopRealtimeUrgentListener();
              ParkingNotificationService().cancelUrgentNotification();
              ParkingNotificationService.stopBackgroundMonitor();
            }
            debugPrint('[SessionService] Sesi dipulihkan. Sisa waktu: $formattedRemainingTime');
          }
        } else {
          _lastActiveTime = DateTime.now();
          _startInactivityCheckTimer();
          if (_userType == 'user') {
            ParkingNotificationService().startRealtimeUrgentListener();
          } else if (_userType == 'admin') {
            ParkingNotificationService().stopRealtimeUrgentListener();
            ParkingNotificationService().cancelUrgentNotification();
            ParkingNotificationService.stopBackgroundMonitor();
          }
        }
      }
    } catch (e) {
      debugPrint('[SessionService] Error init: $e');
    }
  }


  bool consumeSessionExpiredOnStartup() {
    final expired = _sessionExpiredOnStartup;
    _sessionExpiredOnStartup = false;
    return expired;
  }

 
  Future<void> startSession({
    required String userType,
    required String identifier,
    required String userName,
    String? userId,
    String? adminRole,
  }) async {
    _isLoggedIn = true;
    _userType = userType;
    _identifier = identifier;
    _userId = userId;
    _userName = userName;
    _adminRole = adminRole;
    _lastActiveTime = DateTime.now();
    _backgroundTime = null;
    _sessionExpiredOnStartup = false;

    _backgroundTimeoutTimer?.cancel();
    _backgroundTimeoutTimer = null;
    _startInactivityCheckTimer();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kIsLoggedIn, true);
      await prefs.setString(_kUserType, userType);
      await prefs.setString(_kIdentifier, identifier);
      if (userId != null && userId.isNotEmpty) {
        await prefs.setString(_kUserId, userId);
      } else {
        await prefs.remove(_kUserId);
      }
      await prefs.setString(_kUserName, userName);
      if (adminRole != null) {
        await prefs.setString(_kAdminRole, adminRole);
      } else {
        await prefs.remove(_kAdminRole);
      }
      await prefs.setInt(_kLastActiveTime, _lastActiveTime!.millisecondsSinceEpoch);
      await prefs.remove(_kBackgroundTime);
    } catch (e) {
      debugPrint('[SessionService] Error startSession: $e');
    }

    if (userType == 'user') {
      ParkingNotificationService().startRealtimeUrgentListener();
    } else if (userType == 'admin') {
      ParkingNotificationService().stopRealtimeUrgentListener();
      ParkingNotificationService().cancelUrgentNotification();
      ParkingNotificationService.stopBackgroundMonitor();
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('ps_session_user_id');
        await prefs.setBool('ps_parking_session_active', false);
        await prefs.remove('ps_parking_expected_checkout');
        await prefs.setBool('ps_parking_notif_dismissed', true);
        await prefs.remove('ps_last_shown_urgent_notif_id');
      } catch (_) {}
    }

    debugPrint('[SessionService] Sesi $userType dimulai untuk $userName ($identifier, uid: $userId). Batas waktu: 30 menit.');
  }


  void recordUserActivity() {
    if (!_isLoggedIn) return;

    final now = DateTime.now();
    _lastActiveTime = now;

    
    if (_lastDiskWriteTime == null || now.difference(_lastDiskWriteTime!).inSeconds >= 15) {
      _lastDiskWriteTime = now;
      _persistLastActiveTime(now);
    }
  }

  Future<void> _persistLastActiveTime(DateTime time) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kLastActiveTime, time.millisecondsSinceEpoch);
    } catch (_) {}
  }


  void _startInactivityCheckTimer() {
    _inactivityCheckTimer?.cancel();
    _inactivityCheckTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_isLoggedIn || _lastActiveTime == null) return;

      final elapsed = DateTime.now().difference(_lastActiveTime!);
      if (elapsed >= sessionTimeout) {
        debugPrint('[SessionService] Inactivity timeout tercapai (30 menit tanpa interaksi). Auto logout.');
        logoutDueToTimeout();
      }
    });
  }


  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_isLoggedIn) return;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      
      _onAppBackgrounded();
    } else if (state == AppLifecycleState.resumed) {
   
      _onAppResumed();
    }
  }


  void _onAppBackgrounded() {
    final now = DateTime.now();
    _backgroundTime = now;

    SharedPreferences.getInstance().then((prefs) {
      prefs.setInt(_kBackgroundTime, now.millisecondsSinceEpoch);
    });


    _backgroundTimeoutTimer?.cancel();
    _backgroundTimeoutTimer = Timer(sessionTimeout, () {
      debugPrint('[SessionService] Background 30 menit timer habis di background. Menandai sesi expired.');
      clearSession();
    });

    debugPrint('[SessionService] Aplikasi masuk latar belakang. Waktu mulai hitung 30 menit: $now');
  }


  void _onAppResumed() {
    _backgroundTimeoutTimer?.cancel();
    _backgroundTimeoutTimer = null;

    if (!_isLoggedIn) return;

    final now = DateTime.now();
    final referenceTime = _backgroundTime ?? _lastActiveTime ?? now;
    final elapsed = now.difference(referenceTime);

    debugPrint('[SessionService] Aplikasi kembali ke layar. Waktu di latar belakang: ${elapsed.inMinutes} menit ${elapsed.inSeconds % 60} detik');

    if (elapsed >= sessionTimeout) {
      debugPrint('[SessionService] Waktu di latar belakang melebihi 30 menit! Auto logout dipicu.');
      logoutDueToTimeout();
    } else {

      _lastActiveTime = now;
      _backgroundTime = null;
      _persistLastActiveTime(now);
      SharedPreferences.getInstance().then((prefs) => prefs.remove(_kBackgroundTime));
    }
  }


  Future<void> logoutDueToTimeout() async {
    if (!_isLoggedIn) return;

    debugPrint('[SessionService] Menjalankan logout otomatis karena sesi habis...');
    await clearSession();


    try {
      ProfileBackend.instance.setLoggedInUser(
        id: '',
        fullName: '',
        email: '',
        phone: '',
        memberTier: 'BRONZE',
        walletBalance: 0,
      );
    } catch (_) {}


    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {}


    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('current_admin_name');
      await prefs.remove('current_admin_email');
      await prefs.remove('current_admin_role');
    } catch (_) {}


    try {
      final nav = navigatorKey.currentState;
      if (nav != null) {
        nav.pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => const LoginScreen(sessionExpired: true),
          ),
          (route) => false,
        );
      }
    } catch (e) {
      debugPrint('[SessionService] Error redirecting to LoginScreen: $e');
    }
  }


  Future<void> clearSession() async {
    ParkingNotificationService().stopRealtimeUrgentListener();
    ParkingNotificationService().cancelUrgentNotification();
    ParkingNotificationService.stopBackgroundMonitor();

    _isLoggedIn = false;
    _userType = null;
    _identifier = null;
    _userId = null;
    _userName = null;
    _adminRole = null;
    _lastActiveTime = null;
    _backgroundTime = null;

    _inactivityCheckTimer?.cancel();
    _inactivityCheckTimer = null;
    _backgroundTimeoutTimer?.cancel();
    _backgroundTimeoutTimer = null;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kIsLoggedIn, false);
      await prefs.remove(_kUserType);
      await prefs.remove(_kIdentifier);
      await prefs.remove(_kUserId);
      await prefs.remove(_kUserName);
      await prefs.remove(_kAdminRole);
      await prefs.remove(_kLastActiveTime);
      await prefs.remove(_kBackgroundTime);
      await prefs.remove('user_profile_id');
      await prefs.remove('user_profile_name');
      await prefs.remove('user_profile_email');
      await prefs.remove('user_profile_phone');
    } catch (e) {
      debugPrint('[SessionService] Error clearSession: $e');
    }

  
    try {
      ProfileBackend.instance.clearProfile();
    } catch (_) {}
    try {
      PaymentMethodsBackend.instance.clear();
    } catch (_) {}
    try {
      CheckoutBackend.instance.clear();
    } catch (_) {}
    try {
      HomeBackend.instance.clear();
    } catch (_) {}
    try {
      HistoryBackend.instance.clear();
    } catch (_) {}
    try {
      VerifiedParkingSessionsBackend.instance.clear();
    } catch (_) {}
    try {
      VehicleBackend.instance.clearVehicles();
    } catch (_) {}
    try {
      NotificationBackend.instance.clear();
    } catch (_) {}
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _inactivityCheckTimer?.cancel();
    _backgroundTimeoutTimer?.cancel();
  }
}
