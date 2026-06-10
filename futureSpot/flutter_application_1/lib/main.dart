import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  
  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spot Saver PWA',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        primaryColor: const Color(0xFF2563EB),
        fontFamily: 'Noto Sans JP',
      ),
      home: const MainNavigationScreen(),
    );
  }
}

// --- CONSTANTS & TAG UTILS ---
class TagConfig {
  final String label;
  final IconData icon;
  const TagConfig(this.label, this.icon);
}

const List<TagConfig> kCategoryTags = [
  TagConfig('カフェ', Icons.local_cafe_outlined),
  TagConfig('レストラン', Icons.restaurant_outlined),
  TagConfig('バー', Icons.local_bar_outlined),
  TagConfig('仕事向け', Icons.laptop_mac_outlined),
  TagConfig('デート', Icons.favorite_border_outlined),
  TagConfig('リラックス', Icons.eco_outlined),
  TagConfig('スイーツ', Icons.cake_outlined),
  TagConfig('ブランチ', Icons.wb_sunny_outlined),
  TagConfig('特別な日', Icons.auto_awesome_outlined),
];

// --- MODELS ---
class Spot {
  final String id;
  final String name;
  final String url;
  final double latitude;
  final double longitude;
  final List<String> tags;
  final String memo;
  final bool isPinned; // 📌 ピン留めフラグを追加

  Spot({
    required this.id,
    required this.name,
    required this.url,
    required this.latitude,
    required this.longitude,
    required this.tags,
    required this.memo,
    required this.isPinned, // 📌 必須引数に追加
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'url': url,
    'latitude': latitude,
    'longitude': longitude,
    'tags': tags,
    'memo': memo,
    'isPinned': isPinned, // 📌 マップ変換に追加
  };

  factory Spot.fromMap(Map<String, dynamic> map) {
    var parsedTags = map['tags'];
    List<String> safeTags = [];
    if (parsedTags != null && parsedTags is List) {
      safeTags = parsedTags.map((e) => e.toString()).toList();
    }

    return Spot(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      url: map['url'] ?? '',
      latitude: (map['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (map['longitude'] as num?)?.toDouble() ?? 0.0,
      tags: safeTags,
      memo: map['memo'] ?? '',
      isPinned: map['isPinned'] ?? false, // 📌 過去データはデフォルトでfalse
    );
  }
}


class SpotWithDistance {
  final Spot spot;
  final double? distanceInMeters;
  SpotWithDistance({required this.spot, this.distanceInMeters});
}

// --- PROVIDERS ---
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) => throw UnimplementedError());
final currentPositionProvider = StateProvider<Position?>((ref) => null);
final selectedTagProvider = StateProvider<String?>((ref) => null);
final searchQueryProvider = StateProvider<String>((ref) => '');
final selectedMapSpotProvider = StateProvider<SpotWithDistance?>((ref) => null);

final spotListProvider = StateNotifierProvider<SpotListNotifier, List<Spot>>((ref) {
  return SpotListNotifier(ref.watch(sharedPreferencesProvider));
});

class SpotListNotifier extends StateNotifier<List<Spot>> {
  final SharedPreferences _prefs;
  static const _storageKey = 'saved_spots';

  SpotListNotifier(this._prefs) : super([]) {
    _loadSpots();
  }

  void _loadSpots() {
    final jsonString = _prefs.getString(_storageKey);
    if (jsonString != null) {
      final List<dynamic> decoded = jsonDecode(jsonString);
      state = decoded.map((item) => Spot.fromMap(item)).toList();
    }
  }

  Future<void> addSpot(Spot spot) async {
    state = [...state, spot];
    await _saveToStorage();
  }

  Future<void> deleteSpot(String id) async {
    state = state.where((spot) => spot.id != id).toList();
    await _saveToStorage();
  }

  Future<void> updateSpot(Spot updatedSpot) async {
    state = state.map((spot) => spot.id == updatedSpot.id ? updatedSpot : spot).toList();
    await _saveToStorage();
  }

  Future<void> _saveToStorage() async {
    final encoded = jsonEncode(state.map((s) => s.toMap()).toList());
    await _prefs.setString(_storageKey, encoded);
  }
}

final filteredAndSortedSpotsProvider = Provider<List<SpotWithDistance>>((ref) {
  final spots = ref.watch(spotListProvider);
  final query = ref.watch(searchQueryProvider).toLowerCase();
  final selectedTag = ref.watch(selectedTagProvider);
  final currentPos = ref.watch(currentPositionProvider);

  // 1. フィルタリング処理（検索クエリ & タグ）
  final filtered = spots.where((spot) {
    final matchesQuery = spot.name.toLowerCase().contains(query) || spot.url.toLowerCase().contains(query);
    final matchesTag = selectedTag == null || spot.tags.contains(selectedTag);
    return matchesQuery && matchesTag;
  }).toList();

  // 2. 距離計算を伴うオブジェクトへの変換
  final listWithDistance = filtered.map((spot) {
    double? distance;
    if (currentPos != null) {
      distance = Geolocator.distanceBetween(
        currentPos.latitude,
        currentPos.longitude,
        spot.latitude,
        spot.longitude,
      );
    }
    return SpotWithDistance(spot: spot, distanceInMeters: distance);
  }).toList();

  // 3. 📌 並び替えロジック（ピン留め優先 -> 距離が近い順）
  listWithDistance.sort((a, b) {
    // 両方ピン留め、または両方ピン留めされていない場合は距離で比較
    if (a.spot.isPinned == b.spot.isPinned) {
      if (a.distanceInMeters == null && b.distanceInMeters == null) return 0;
      if (a.distanceInMeters == null) return 1;
      if (b.distanceInMeters == null) return -1;
      return a.distanceInMeters!.compareTo(b.distanceInMeters!);
    }
    // ピン留めされている方を最優先（上に持ってくる）
    return a.spot.isPinned ? -1 : 1;
  });

  return listWithDistance;
});

// --- NAVIGATION SCREEN ---
class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: const [
          MainListScreen(),
          MapViewScreen(),
        ],
      ),
      bottomNavigationBar: BottomAppBar(
        shape: const CircularNotchedRectangle(),
        notchMargin: 8.0,
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: 60,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              IconButton(
                icon: Icon(Icons.map_outlined, color: _currentIndex == 1 ? const Color(0xFF2563EB) : Colors.grey),
                onPressed: () => setState(() => _currentIndex = 1),
              ),
              const SizedBox(width: 40),
              IconButton(
                icon: Icon(Icons.person_outline, color: _currentIndex == 0 ? const Color(0xFF2563EB) : Colors.grey),
                onPressed: () => setState(() => _currentIndex = 0),
              ),
            ],
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddSpotScreen()));
        },
        backgroundColor: const Color(0xFF2563EB),
        elevation: 4,
        shape: const CircleBorder(),
        child: const Icon(Icons.add, color: Colors.white, size: 32),
      ),
    );
  }
}

// --- SCREEN 1: MAIN LIST SCREEN ---
class MainListScreen extends ConsumerStatefulWidget {
  const MainListScreen({super.key});

  @override
  ConsumerState<MainListScreen> createState() => _MainListScreenState();
}

class _MainListScreenState extends ConsumerState<MainListScreen> {
  // モックアップの雰囲気に合わせた各カテゴリ固有のアクセントカラー
  final Map<String, Color> _tagColors = {
    '仕事向け': const Color(0xFF3B82F6),   // 青
    'デート': const Color(0xFFEC4899),     // ピンク
    'カフェ': const Color(0xFFD97706),     // ブラウン/オレンジ
    'リラックス': const Color(0xFF10B981), // グリーン
    '特別な日': const Color(0xFF8B5CF6),   // パープル
  };

  // モックアップに合わせたダミーの綺麗なカフェ・レストラン画像（Unsplashより）
  final List<String> _mockImages = [
    'https://images.unsplash.com/photo-1554118811-1e0d58224f24?w=600&auto=format&fit=crop&q=60',
    'https://images.unsplash.com/photo-1517248135467-4c7edcad34c4?w=600&auto=format&fit=crop&q=60',
    'https://images.unsplash.com/photo-1498804103079-a6351b050096?w=600&auto=format&fit=crop&q=60',
  ];

  @override
  void initState() {
    super.initState();
    _determinePosition();
  }

  Future<void> _determinePosition() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;
    final position = await Geolocator.getCurrentPosition();
    ref.read(currentPositionProvider.notifier).state = position;
  }

  void _showEditDialog(BuildContext context, Spot spot) {
    final nameController = TextEditingController(text: spot.name);
    final urlController = TextEditingController(text: spot.url);
    List<String> localSelectedTags = List.from(spot.tags);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                top: 24, left: 24, right: 24,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('スポット情報を編集', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Color(0xFF1E293B))),
                    const SizedBox(height: 16),
                    TextField(
                      controller: nameController,
                      decoration: InputDecoration(
                        labelText: '店名',
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: urlController,
                      decoration: InputDecoration(
                        labelText: 'URL',
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text('タグ変更', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF1E293B))),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: kCategoryTags.map((tagConfig) {
                        final isSelected = localSelectedTags.contains(tagConfig.label);
                        return FilterChip(
                          label: Text(tagConfig.label),
                          selected: isSelected,
                          selectedColor: const Color(0xFFEFF6FF),
                          checkmarkColor: const Color(0xFF2563EB),
                          onSelected: (selected) {
                            setModalState(() {
                              if (selected) {
                                localSelectedTags.add(tagConfig.label);
                              } else {
                                localSelectedTags.remove(tagConfig.label);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: () {
                          if (nameController.text.isEmpty) return;
                          final updated = Spot(
                            id: spot.id,
                            name: nameController.text,
                            url: urlController.text,
                            latitude: spot.latitude,
                            longitude: spot.longitude,
                            tags: localSelectedTags,
                            memo: spot.memo,
                            isPinned: spot.isPinned,
                          );
                          ref.read(spotListProvider.notifier).updateSpot(updated);
                          Navigator.pop(context);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          elevation: 0,
                        ),
                        child: const Text('変更を保存', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            );
          }
        );
      },
    );
  }

  // 🛠️ モックアップ2枚目を再現した「詳細＆メモボトムシート」
  void _showDetailBottomSheet(BuildContext context, SpotWithDistance item, String imageUrl, Color tagColor) {
    final spot = item.spot;
    final distanceStr = item.distanceInMeters != null ? '${(item.distanceInMeters!).toStringAsFixed(0)}m先' : '距離不明';
    final primaryTag = spot.tags.isNotEmpty ? spot.tags.first : 'カテゴリなし';
    
    // メモのリアルタイム編集用のコントローラー
    final memoController = TextEditingController(text: spot.memo);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom, // キーボードを避ける
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. トップイメージエリア
              Container(
                height: 200,
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                  image: DecorationImage(image: NetworkImage(imageUrl), fit: BoxFit.cover),
                ),
                child: Stack(
                  children: [
                    // グラデーションオーバーレイ
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.black.withOpacity(0.3), Colors.transparent],
                          begin: Alignment.topCenter, end: Alignment.bottomCenter,
                        ),
                      ),
                    ),
                    // ボトムシートのインジケータ（白いノブ）
                    Align(
                      alignment: Alignment.topCenter,
                      child: Container(
                        width: 40, height: 4, margin: const EdgeInsets.only(top: 12),
                        decoration: BoxDecoration(color: Colors.white.withOpacity(0.8), borderRadius: BorderRadius.circular(2)),
                      ),
                    ),
                    // 右上の閉じるボタン
                    Positioned(
                      top: 16, right: 16,
                      child: GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: const CircleAvatar(backgroundColor: Colors.black26, radius: 16, child: Icon(Icons.close, color: Colors.white, size: 18)),
                      ),
                    ),
                  ],
                ),
              ),

              // 2. コンテンツエリア
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // カテゴリタグ（ハッシュタグ形式）
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: tagColor.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                      child: Text('#$primaryTag', style: TextStyle(color: tagColor, fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 12),
                    
                    // 店名と距離
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            spot.name,
                            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1E293B), letterSpacing: -0.5),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(20)),
                          child: Row(
                            children: [
                              const Icon(Icons.location_on, size: 14, color: Color(0xFF2563EB)),
                              const SizedBox(width: 2),
                              Text(distanceStr, style: const TextStyle(color: Color(0xFF2563EB), fontSize: 13, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    
                    const SizedBox(height: 20),
                    const Divider(color: Color(0xFFF1F5F9), thickness: 1.5),
                    const SizedBox(height: 12),

                    // 🛠️ 追加：マイメモ欄（ユーザーが自由に編集して自動保存できる領域）
                    const Row(
                      children: [
                        Icon(Icons.edit_note, color: Color(0xFF64748B), size: 20),
                        SizedBox(width: 6),
                        Text('マイメモ', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: memoController,
                      maxLines: 3,
                      style: const TextStyle(fontSize: 14, color: Color(0xFF334155), height: 1.5),
                      decoration: InputDecoration(
                        hintText: 'ここにメニューの感想やWi-Fi情報などをメモできます...',
                        hintStyle: const TextStyle(color: Colors.black38, fontSize: 13),
                        filled: true, fillColor: const Color(0xFFF8FAFC),
                        contentPadding: const EdgeInsets.all(12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      ),
                      onChanged: (text) {
                        // メモが書き換えられたら即座にProvider経由で永続化保存
                        final updated = Spot(
                          id: spot.id, name: spot.name, url: spot.url,
                          latitude: spot.latitude, longitude: spot.longitude,
                          tags: spot.tags, memo: text, isPinned: spot.isPinned,
                        );
                        ref.read(spotListProvider.notifier).updateSpot(updated);
                      },
                    ),

                    const SizedBox(height: 28),

                    // 3. アクションボタン（モックアップに準拠した2つのプライマリボタン）
                    Row(
                      children: [
                        // ルート案内ボタン
                        Expanded(
                          child: SizedBox(
                            height: 50,
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final googleMapsUrl = 'https://www.google.com/maps/search/?api=1&query=${spot.latitude},${spot.longitude}';
                                final uri = Uri.parse(googleMapsUrl);
                                if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
                              },
                              icon: const Icon(Icons.directions_outlined, size: 18),
                              label: const Text('ルート案内', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF1E293B),
                                side: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // リンクを開くボタン
                        Expanded(
                          child: SizedBox(
                            height: 50,
                            child: ElevatedButton.icon(
                              onPressed: () async {
                                final uri = Uri.parse(spot.url);
                                if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
                              },
                              icon: const Icon(Icons.open_in_new, size: 18, color: Colors.white),
                              label: const Text('リンクを開く', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF2563EB),
                                elevation: 0,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final spotsWithDistance = ref.watch(filteredAndSortedSpotsProvider);
    final selectedTag = ref.watch(selectedTagProvider);

    return Scaffold(
      // --- MainListScreen 内の AppBar 修正（通知アイコン削除） ---
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        toolbarHeight: 70,
        title: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            children: [
              const Icon(Icons.search, color: Colors.black45, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  onChanged: (val) => ref.read(searchQueryProvider.notifier).state = val,
                  decoration: const InputDecoration(
                    hintText: 'スポットを検索',
                    hintStyle: TextStyle(color: Colors.black38, fontSize: 14, fontWeight: FontWeight.w500),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              // 🛠️ 通知アイコン（Icons.notifications_none）を削除しました
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          // 🛠️ モックアップ再現：丸型アイコン＋縦並びテキストの横スクロールカテゴリ
          Container(
            height: 94,
            color: Colors.white,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              itemCount: kCategoryTags.length,
              itemBuilder: (context, index) {
                final tagConfig = kCategoryTags[index];
                final isSelected = selectedTag == tagConfig.label;
                final accentColor = _tagColors[tagConfig.label] ?? const Color(0xFF64748B);

                return Padding(
                  padding: const EdgeInsets.only(right: 20),
                  child: GestureDetector(
                    onTap: () => ref.read(selectedTagProvider.notifier).state = isSelected ? null : tagConfig.label,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 丸いアイコン背景
                        Container(
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isSelected 
                                ? accentColor 
                                : accentColor.withOpacity(0.08), // 選択されていない時は極めて薄い背景
                          ),
                          child: Icon(
                            tagConfig.icon, 
                            size: 22, 
                            color: isSelected ? Colors.white : accentColor,
                          ),
                        ),
                        const SizedBox(height: 6),
                        // 下部のカテゴリテキスト
                        Text(
                          tagConfig.label,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                            color: isSelected ? accentColor : const Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          
          // メインのスポットリスト一覧
          Expanded(
            child: spotsWithDistance.isEmpty
                ? const Center(child: Text('スポットが登録されていません', style: TextStyle(color: Colors.black45, fontSize: 14)))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    itemCount: spotsWithDistance.length,
                    itemBuilder: (context, index) {
                      final item = spotsWithDistance[index];
                      final distanceStr = item.distanceInMeters != null
                          ? '${(item.distanceInMeters!).toStringAsFixed(0)}m先'
                          : '距離不明';

                      // リストごとに画像が交互に変わるようにインデックスで簡易シミュレート
                      final imageUrl = _mockImages[index % _mockImages.length];
                      final primaryTag = item.spot.tags.isNotEmpty ? item.spot.tags.first : 'カテゴリなし';
                      final tagColor = _tagColors[primaryTag] ?? const Color(0xFF2563EB);

                      return Dismissible(
                        key: Key(item.spot.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          margin: const EdgeInsets.only(bottom: 16),
                          padding: const EdgeInsets.only(right: 20),
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withOpacity(0.9),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          alignment: Alignment.centerRight,
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Text('削除します', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              SizedBox(width: 8),
                              Icon(Icons.delete_outline, color: Colors.white),
                            ],
                          ),
                        ),
                        onDismissed: (direction) {
                          ref.read(spotListProvider.notifier).deleteSpot(item.spot.id);
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShape.circle == false
                                  ? const BoxShadow()
                                  : BoxShadow(
                                      color: Colors.black.withOpacity(0.03),
                                      spreadRadius: 0,
                                      blurRadius: 14,
                                      offset: const Offset(0, 4),
                                    )
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: InkWell(
                              
                              onTap: () {
                                // 即座にブラウザに飛ばすのではなく、モックアップ仕様の詳細シートを展開
                                _showDetailBottomSheet(context, item, imageUrl, tagColor);
                              },
                              onLongPress: () => _showEditDialog(context, item.spot),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // 🛠️ モックアップ再現：本物のカフェ画像をアスペクト比を維持して埋め込み
                                  Container(
                                    height: 150,
                                    width: double.infinity,
                                    decoration: BoxDecoration(
                                      image: DecorationImage(
                                        image: NetworkImage(imageUrl),
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                    child: Stack(
                                      children: [
                                        // 画像の視認性を上げるためのうっすらとした上部グラデーション
                                        Positioned.fill(
                                          child: Container(
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                colors: [Colors.black.withOpacity(0.15), Colors.transparent],
                                                begin: Alignment.topCenter,
                                                end: Alignment.bottomCenter,
                                              ),
                                            ),
                                          ),
                                        ),
                                        // 右上の白いブックマークボタン
                                        // 📌 修正：右上のピン留めボタン
                                        Positioned(
                                          top: 12,
                                          right: 12,
                                          child: GestureDetector(
                                            onTap: () {
                                              // ピン留め状態をトグル（反転）して保存
                                              final updated = Spot(
                                                id: item.spot.id, name: item.spot.name, url: item.spot.url,
                                                latitude: item.spot.latitude, longitude: item.spot.longitude,
                                                tags: item.spot.tags, memo: item.spot.memo,
                                                isPinned: !item.spot.isPinned,
                                              );
                                              ref.read(spotListProvider.notifier).updateSpot(updated);
                                            },
                                            child: Container(
                                              width: 34,
                                              height: 34,
                                              decoration: BoxDecoration(
                                                color: item.spot.isPinned ? const Color(0xFF2563EB) : Colors.white, // ピン留め時は青背景
                                                shape: BoxShape.circle,
                                                boxShadow: [
                                                  BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 6, offset: const Offset(0, 2))
                                                ],
                                              ),
                                              child: Icon(
                                                item.spot.isPinned ? Icons.push_pin : Icons.push_pin_outlined, // ピン留め / 解除アイコン
                                                size: 18, 
                                                color: item.spot.isPinned ? Colors.white : const Color(0xFF1E293B),
                                              ),
                                            ),
                                          ),
                                        )
                                      ],
                                    ),
                                  ),
                                  // テキスト周りのスタイリング
                                  Padding(
                                    padding: const EdgeInsets.all(14),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Expanded(
                                              child: Text(
                                                item.spot.name,
                                                style: const TextStyle(
                                                  fontSize: 15, 
                                                  fontWeight: FontWeight.bold, 
                                                  color: Color(0xFF1E293B),
                                                  letterSpacing: -0.3,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Row(
                                              children: [
                                                const Icon(Icons.location_on, size: 14, color: Color(0xFF2563EB)),
                                                const SizedBox(width: 2),
                                                Text(
                                                  distanceStr, 
                                                  style: const TextStyle(
                                                    color: Color(0xFF2563EB), 
                                                    fontSize: 12, 
                                                    fontWeight: FontWeight.bold
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        // モック準拠のハッシュタグ
                                        Text(
                                          '#$primaryTag',
                                          style: TextStyle(
                                            fontSize: 12, 
                                            color: tagColor, 
                                            fontWeight: FontWeight.bold
                                          ),
                                        )
                                      ],
                                    ),
                                  )
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// --- SCREEN 2: ADD SPOT SCREEN ---
// --- SCREEN 2: ADD SPOT SCREEN ---
class AddSpotScreen extends ConsumerStatefulWidget {
  const AddSpotScreen({super.key});

  @override
  ConsumerState<AddSpotScreen> createState() => _AddSpotScreenState();
}

class _AddSpotScreenState extends ConsumerState<AddSpotScreen> {
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  final List<String> _selectedTags = [];
  
  // デフォルト位置（現在地が取れない場合のフォールバック: 東京駅）
  LatLng _selectedLocation = const LatLng(35.6812, 139.7671);
  bool _isLocationInitialized = false;

  // 各カテゴリ固有のアクセントカラー（メイン画面と同期）
  final Map<String, Color> _tagColors = {
    '仕事向け': const Color(0xFF3B82F6),   // 青
    'デート': const Color(0xFFEC4899),     // ピンク
    'カフェ': const Color(0xFFD97706),     // ブラウン
    'リラックス': const Color(0xFF10B981), // グリーン
    '特別な日': const Color(0xFF8B5CF6),   // パープル
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 起動時にすでに現在地が取得できていれば、ピンの初期位置をそこに設定する
    if (!_isLocationInitialized) {
      final currentPos = ref.watch(currentPositionProvider);
      if (currentPos != null) {
        _selectedLocation = LatLng(currentPos.latitude, currentPos.longitude);
        _isLocationInitialized = true;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Color(0xFF1E293B), size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          '新しいスポットを追加',
          style: TextStyle(color: Color(0xFF1E293B), fontWeight: FontWeight.bold, fontSize: 18),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. 店名入力フォーム
            const Text('店名・スポット名', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              style: const TextStyle(color: Color(0xFF1E293B), fontSize: 15, fontWeight: FontWeight.w500),
              decoration: InputDecoration(
                hintText: '例: カフェ・オレ・ロースタリー',
                hintStyle: const TextStyle(color: Colors.black26, fontSize: 14),
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              ),
            ),
            
            const SizedBox(height: 24),

            // 2. URL入力フォーム
            const Text('共有URL (Instagram, Googleマップ等)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
            const SizedBox(height: 8),
            TextField(
              controller: _urlController,
              style: const TextStyle(color: Color(0xFF1E293B), fontSize: 14, fontWeight: FontWeight.w400),
              decoration: InputDecoration(
                hintText: 'https://instagram.com/...',
                hintStyle: const TextStyle(color: Colors.black26, fontSize: 14),
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                prefixIcon: const Icon(Icons.link, color: Color(0xFF94A3B8), size: 20),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              ),
            ),

            const SizedBox(height: 28),

            // 3. カテゴリ選択UI（トップ画面と完全にシンクロしたモダンな丸アイコン並び）
            const Text('カテゴリを選択', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
            const SizedBox(height: 12),
            Container(
              height: 90,
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: kCategoryTags.length,
                itemBuilder: (context, index) {
                  final tagConfig = kCategoryTags[index];
                  final isSelected = _selectedTags.contains(tagConfig.label);
                  final accentColor = _tagColors[tagConfig.label] ?? const Color(0xFF64748B);

                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          if (isSelected) {
                            _selectedTags.remove(tagConfig.label);
                          } else {
                            // 今回は単一、または複数選択どちらでも対応可能
                            _selectedTags.add(tagConfig.label);
                          }
                        });
                      },
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isSelected ? accentColor : accentColor.withOpacity(0.08),
                              border: Border.all(
                                color: isSelected ? Colors.white : Colors.transparent,
                                width: 1.5,
                              ),
                            ),
                            child: Icon(
                              tagConfig.icon, 
                              size: 18, 
                              color: isSelected ? Colors.white : accentColor,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            tagConfig.label,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                              color: isSelected ? accentColor : const Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 28),

            // 4. ミニマップ位置調整エリア
            const Row(
              children: [
                Icon(Icons.pin_drop_outlined, color: Color(0xFF64748B), size: 18),
                SizedBox(width: 4),
                Text('位置の微調整（マップを動かして中心にピンを配置）', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              height: 180,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFE2E8F0), width: 1.5),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Stack(
                  children: [
                    FlutterMap(
                      options: MapOptions(
                        initialCenter: _selectedLocation,
                        initialZoom: 15.0,
                        onPositionChanged: (position, hasGesture) {
                          // ユーザーがマップをドラッグして動かしたら、その中心座標を自動でセット
                          if (hasGesture && position.center != null) {
                            _selectedLocation = position.center!;
                          }
                        },
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.example.spot_saver',
                        ),
                      ],
                    ),
                    // 地図の完全に中央に固定されるカスタムターゲットピン
                    Align(
                      alignment: Alignment.center,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 24), // ピンの針の先端が中心にくるように微調整
                        child: Icon(
                          Icons.location_on, 
                          color: const Color(0xFF2563EB), 
                          size: 38,
                          shadows: [
                            Shadow(color: Colors.black.withOpacity(0.2), blurRadius: 6, offset: const Offset(0, 3))
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 40),

            // 5. 保存実行ボタン
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: () {
                  if (_nameController.text.isEmpty || _urlController.text.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('店名とURLを入力してください'), backgroundColor: Colors.redAccent),
                    );
                    return;
                  }
                  // --- AddSpotScreen 内の ElevatedButton(onPressed: () { ... }) の該当部分 ---
                  final newSpot = Spot(
                    id: const Uuid().v4(),
                    name: _nameController.text,
                    url: _urlController.text,
                    latitude: _selectedLocation.latitude,
                    longitude: _selectedLocation.longitude,
                    tags: _selectedTags,
                    memo: '', 
                    isPinned: false, // 📌 新規追加時は一律ピン留め無しで初期化
                  );
                  ref.read(spotListProvider.notifier).addSpot(newSpot);
                  Navigator.of(context).pop();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                child: const Text(
                  'このスポットを保存する',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
// --- SCREEN 4: MAP VIEW SCREEN ---
// --- SCREEN 4: MAP VIEW SCREEN ---
class MapViewScreen extends ConsumerStatefulWidget {
  const MapViewScreen({super.key});

  @override
  ConsumerState<MapViewScreen> createState() => _MapViewScreenState();
}

class _MapViewScreenState extends ConsumerState<MapViewScreen> {
  final MapController _mapController = MapController();
  bool _hasCenteredOnInitialLoad = false;

  // 各カテゴリ固有のアクセントカラー（メイン画面と完全同期）
  final Map<String, Color> _tagColors = {
    '仕事向け': const Color(0xFF3B82F6),
    'デート': const Color(0xFFEC4899),
    'カフェ': const Color(0xFFD97706),
    'リラックス': const Color(0xFF10B981),
    '特別な日': const Color(0xFF8B5CF6),
  };

  final List<String> _mockImages = [
    'https://images.unsplash.com/photo-1554118811-1e0d58224f24?w=600&auto=format&fit=crop&q=60',
    'https://images.unsplash.com/photo-1517248135467-4c7edcad34c4?w=600&auto=format&fit=crop&q=60',
    'https://images.unsplash.com/photo-1498804103079-a6351b050096?w=600&auto=format&fit=crop&q=60',
  ];

  IconData _getCategoryIcon(List<String> tags) {
    if (tags.isEmpty) return Icons.location_on;
    final primaryTag = tags.first;
    for (final config in kCategoryTags) {
      if (config.label == primaryTag) return config.icon;
    }
    return Icons.location_on;
  }

  // 🛠️ マップ画面用にも「詳細＆メモボトムシート」の実装を完全流用
  void _showDetailBottomSheet(BuildContext context, SpotWithDistance item, String imageUrl, Color tagColor) {
    final spot = item.spot;
    final distanceStr = item.distanceInMeters != null ? '${(item.distanceInMeters!).toStringAsFixed(0)}m先' : '距離不明';
    final primaryTag = spot.tags.isNotEmpty ? spot.tags.first : 'カテゴリなし';
    final memoController = TextEditingController(text: spot.memo);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 200,
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                  image: DecorationImage(image: NetworkImage(imageUrl), fit: BoxFit.cover),
                ),
                child: Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.black.withOpacity(0.3), Colors.transparent],
                          begin: Alignment.topCenter, end: Alignment.bottomCenter,
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.topCenter,
                      child: Container(
                        width: 40, height: 4, margin: const EdgeInsets.only(top: 12),
                        decoration: BoxDecoration(color: Colors.white.withOpacity(0.8), borderRadius: BorderRadius.circular(2)),
                      ),
                    ),
                    Positioned(
                      top: 16, right: 16,
                      child: GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: const CircleAvatar(backgroundColor: Colors.black26, radius: 16, child: Icon(Icons.close, color: Colors.white, size: 18)),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: tagColor.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                      child: Text('#$primaryTag', style: TextStyle(color: tagColor, fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            spot.name,
                            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF1E293B), letterSpacing: -0.5),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(20)),
                          child: Row(
                            children: [
                              const Icon(Icons.location_on, size: 14, color: Color(0xFF2563EB)),
                              const SizedBox(width: 2),
                              Text(distanceStr, style: const TextStyle(color: Color(0xFF2563EB), fontSize: 13, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    const Divider(color: Color(0xFFF1F5F9), thickness: 1.5),
                    const SizedBox(height: 12),
                    const Row(
                      children: [
                        Icon(Icons.edit_note, color: Color(0xFF64748B), size: 20),
                        SizedBox(width: 6),
                        Text('マイメモ', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: memoController,
                      maxLines: 3,
                      style: const TextStyle(fontSize: 14, color: Color(0xFF334155), height: 1.5),
                      decoration: InputDecoration(
                        hintText: 'ここにメニューの感想やWi-Fi情報などをメモできます...',
                        hintStyle: const TextStyle(color: Colors.black38, fontSize: 13),
                        filled: true, fillColor: const Color(0xFFF8FAFC),
                        contentPadding: const EdgeInsets.all(12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      ),
                      onChanged: (text) {
                        final updated = Spot(
                          id: spot.id, name: spot.name, url: spot.url,
                          latitude: spot.latitude, longitude: spot.longitude,
                          tags: spot.tags, memo: text, isPinned: spot.isPinned,
                        );
                        ref.read(spotListProvider.notifier).updateSpot(updated);
                      },
                    ),
                    const SizedBox(height: 28),
                    Row(
                      children: [
                        // 1. ルート案内ボタン
                        Expanded(
                          child: SizedBox(
                            height: 50,
                            child: OutlinedButton.icon(
                              onPressed: () async { /* ルート案内ロジック */ },
                              icon: const Icon(Icons.directions_outlined, size: 18),
                              label: const Text('ルート案内', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF1E293B),
                                side: const BorderSide(color: Color(0xFFE2E8F0), width: 1.5),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        
                        // 2. リンクを開くボタン
                        Expanded(
                          child: SizedBox(
                            height: 50,
                            child: ElevatedButton.icon(
                              onPressed: () async { /* リンクを開くロジック */ },
                              icon: const Icon(Icons.open_in_new, size: 18, color: Colors.white),
                              label: const Text('リンクを開く', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF2563EB),
                                elevation: 0,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12), // ボタン間の隙間

                        // 📌 3. ここに提示された「ピン留めトグルボタン」を挿入します
                        StatefulBuilder(
                          builder: (context, setModalState) {
                            return GestureDetector(
                              onTap: () {
                                final updated = Spot(
                                  id: spot.id, name: spot.name, url: spot.url,
                                  latitude: spot.latitude, longitude: spot.longitude,
                                  tags: spot.tags, memo: spot.memo,
                                  isPinned: !spot.isPinned, // フラグを反転
                                );
                                ref.read(spotListProvider.notifier).updateSpot(updated);
                                Navigator.pop(context); // ボトムシートを閉じてリストを再描画
                              },
                              child: Container(
                                width: 50,
                                height: 50,
                                decoration: BoxDecoration(
                                  color: spot.isPinned ? const Color(0xFF2563EB) : const Color(0xFFF8FAFC),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: const Color(0xFFE2E8F0)),
                                ),
                                child: Icon(
                                  spot.isPinned ? Icons.push_pin : Icons.push_pin_outlined, 
                                  color: spot.isPinned ? Colors.white : Colors.black87, 
                                  size: 20,
                                ),
                              ),
                            );
                          },
                        ), // 👈 StatefulBuilder の閉じ
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final spotsWithDistance = ref.watch(filteredAndSortedSpotsProvider);
    final currentPos = ref.watch(currentPositionProvider);
    final selectedTag = ref.watch(selectedTagProvider);

    ref.listen<Position?>(currentPositionProvider, (previous, next) {
      if (next != null && !_hasCenteredOnInitialLoad) {
        _mapController.move(LatLng(next.latitude, next.longitude), 14.5);
        setState(() { _hasCenteredOnInitialLoad = true; });
      }
    });

    LatLng initialCenter = const LatLng(35.6812, 139.7671);
    if (currentPos != null) {
      initialCenter = LatLng(currentPos.latitude, currentPos.longitude);
    }

    return Scaffold(
      body: Stack(
        children: [
          // 1. 地図本体
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: initialCenter,
              initialZoom: 14.5,
              onMapReady: () {
                if (currentPos != null && !_hasCenteredOnInitialLoad) {
                  _mapController.move(LatLng(currentPos.latitude, currentPos.longitude), 14.5);
                  _hasCenteredOnInitialLoad = true;
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.spot_saver',
              ),
              MarkerLayer(
                markers: [
                  if (currentPos != null)
                    Marker(
                      point: LatLng(currentPos.latitude, currentPos.longitude),
                      width: 40, height: 40,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(width: 32, height: 32, decoration: BoxDecoration(color: const Color(0xFF2563EB).withOpacity(0.2), shape: BoxShape.circle)),
                          Container(width: 14, height: 14, decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 4, offset: const Offset(0, 2))])),
                          Container(width: 10, height: 10, decoration: const BoxDecoration(color: Color(0xFF2563EB), shape: BoxShape.circle)),
                        ],
                      ),
                    ),
                  
                  ...spotsWithDistance.asMap().entries.map((entry) {
                    final index = entry.key;
                    final item = entry.value;
                    final primaryTag = item.spot.tags.isNotEmpty ? item.spot.tags.first : 'カテゴリなし';
                    final tagColor = _tagColors[primaryTag] ?? const Color(0xFF2563EB);
                    final imageUrl = _mockImages[index % _mockImages.length];

                    return Marker(
                      point: LatLng(item.spot.latitude, item.spot.longitude),
                      width: 46, height: 46,
                      child: GestureDetector(
                        onTap: () {
                          _mapController.move(LatLng(item.spot.latitude, item.spot.longitude), 15.0);
                          // 🛠️ ピンタップ時にリスト画面と完全に共通化された詳細ボトムシートを展開
                          _showDetailBottomSheet(context, item, imageUrl, tagColor);
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFF2563EB).withOpacity(0.15), width: 1),
                            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 8, offset: const Offset(0, 3))],
                          ),
                          child: Icon(_getCategoryIcon(item.spot.tags), color: const Color(0xFF2563EB), size: 20),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ],
          ),
          
          // 🛠️ エリア検索・構造リファクタリング領域
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 16, right: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 検索バー (設定ボタン「tune」を排除)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white, borderRadius: BorderRadius.circular(30),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, 4))],
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search, color: Colors.black45, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          onChanged: (val) => ref.read(searchQueryProvider.notifier).state = val,
                          decoration: const InputDecoration(hintText: 'このエリアを検索', hintStyle: TextStyle(color: Colors.black38, fontSize: 14, fontWeight: FontWeight.w500), border: InputBorder.none),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                
                // 🛠️ マップ画面用カテゴリタブ（スポット検索画面と完全同一のステート・UI設計）
                Container(
                  height: 74,
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: kCategoryTags.length,
                    itemBuilder: (context, index) {
                      final tagConfig = kCategoryTags[index];
                      final isSelected = selectedTag == tagConfig.label;
                      final accentColor = _tagColors[tagConfig.label] ?? const Color(0xFF64748B);

                      return Padding(
                        padding: const EdgeInsets.only(right: 14),
                        child: GestureDetector(
                          onTap: () => ref.read(selectedTagProvider.notifier).state = isSelected ? null : tagConfig.label,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 44, height: 44,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isSelected ? accentColor : Colors.white.withOpacity(0.9),
                                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 6, offset: const Offset(0, 2))],
                                ),
                                child: Icon(tagConfig.icon, size: 18, color: isSelected ? Colors.white : accentColor),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                tagConfig.label,
                                style: TextStyle(
                                  fontSize: 10, fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                                  color: isSelected ? accentColor : const Color(0xFF1E293B),
                                  shadows: [Shadow(color: Colors.white.withOpacity(0.8), blurRadius: 4)],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),

          // 現在地トラッキングボタン
          Positioned(
            bottom: 20, right: 16,
            child: GestureDetector(
              onTap: () {
                if (currentPos != null) _mapController.move(LatLng(currentPos.latitude, currentPos.longitude), 15.5);
              },
              child: Container(
                width: 48, height: 48,
                decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 4))]),
                child: const Icon(Icons.navigation_outlined, color: Colors.black87, size: 22),
              ),
            ),
          ),
        ],
      ),
    );
  }
}