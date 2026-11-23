import 'package:flutter/material.dart';
import '../features/home/home_screen.dart';
import '../features/history/history_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/favorite/favorite_screen.dart';

enum DockTab { home, history, favorite, profile }

class BottomDockNavigation extends StatelessWidget {
  final DockTab activeTab;
  
  const BottomDockNavigation({super.key, required this.activeTab});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 68,
      constraints: const BoxConstraints(maxWidth: 360),
      decoration: BoxDecoration(
        // ─── [USER] WARNA LATAR BILAH DOCK NAVIGASI BAWAH ───
        color: const Color(0xFF1C1D1F), // <-- Ubah warna Latar Belakang Dock Navigasi Melayang (Hitam Charcoal)
        borderRadius: BorderRadius.circular(32),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1C1D1F).withValues(alpha: 0.2),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildIcon(context, Icons.home, DockTab.home, () {
            if (activeTab != DockTab.home) {
              Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const HomeScreen()), (route) => false);
            }
          }),
          _buildIcon(context, Icons.receipt_long_outlined, DockTab.history, () {
            if (activeTab != DockTab.history) {
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HistoryScreen()));
            }
          }),
          // ============================================================================
          // [PANDUAN ASLAB - UBAH DOCK NAVIGASI BAWAH]
          // Urutan tab ditulis berurutan di Row: Home, Riwayat, Favorit (tengah), Profil.
          // - Ganti ikon: ubah `Icons.favorite` / `Icons.favorite_border` di _buildIcon tab Favorit. Daftar ikon: api.flutter.dev -> Icons.
          // - Tukar halaman tujuan: ubah halaman di `MaterialPageRoute(builder: (_) => const FavoriteScreen())`
          //   dan tambahkan import-nya di bagian atas file.
          // - Menambah tab baru: tambah nilai di `enum DockTab`, tambahkan _buildIcon baru di Row,
          //   lalu kirim `activeTab: DockTab.xxx` dari layar tujuan agar ikon aktif menyala.
          // Dock dipakai oleh home_screen, history_screen, favorite_screen, dan profile_screen (cek parameter activeTab di masing-masing).
          // ============================================================================
          // Center: Favorit (rounded-2xl)
          _buildIcon(context, activeTab == DockTab.favorite ? Icons.favorite : Icons.favorite_border, DockTab.favorite, () {
            if (activeTab != DockTab.favorite) {
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const FavoriteScreen()));
            }
          }),
          _buildIcon(context, Icons.person_outline, DockTab.profile, () {
            if (activeTab != DockTab.profile) {
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const ProfileScreen()));
            }
          }),
        ],
      ),
    );
  }

  Widget _buildIcon(BuildContext context, IconData icon, DockTab tab, VoidCallback onTap) {
    final isActive = activeTab == tab;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48, height: 48,
        decoration: BoxDecoration(
          // ─── [USER] WARNA TAB AKTIF DI DOCK NAVIGASI ───
          color: isActive ? const Color(0xFFD67B5A) : Colors.transparent, // <-- Ubah warna Lingkaran Tab Aktif (Terracotta Oranye)
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(
          icon,
          size: 22,
          color: isActive ? Colors.white : Colors.white.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}