import 'dart:async';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Focus Wave',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F0F14),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C5CE7),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const FocusWaveHomePage(),
    );
  }
}

class FocusWaveHomePage extends StatefulWidget {
  const FocusWaveHomePage({super.key});

  @override
  State<FocusWaveHomePage> createState() => _FocusWaveHomePageState();
}

class _FocusWaveHomePageState extends State<FocusWaveHomePage> {
  // --- 音楽再生・環境音管理 ---
  final AudioPlayer _bgmPlayer = AudioPlayer();
  final AudioPlayer _alarmPlayer = AudioPlayer();
  
  String? _currentBgm;
  bool _isPlayingBgm = false;
  double _bgmVolume = 0.5;

  // --- アラーム管理 ---
  TimeOfDay _selectedAlarmTime = const TimeOfDay(hour: 7, minute: 0);
  bool _isAlarmEnabled = false;
  bool _hasTriggeredAlarmToday = false;
  bool _isAlarmRinging = false;
  
  Timer? _alarmCheckTimer;
  // ボトムシート内のStatefulBuilderの更新用セッター
  StateSetter? _currentSheetLiveSetter;

  // 環境音リスト
  final List<Map<String, dynamic>> _soundTracks = [
    {'id': 'rain', 'name': '恵みの雨', 'icon': Icons.thunderstorm_rounded, 'path': 'audio/rain.mp3'},
    {'id': 'fire', 'name': '焚き火のゆらぎ', 'icon': Icons.local_fire_department_rounded, 'path': 'audio/fire.mp3'},
    {'id': 'cafe', 'name': 'カフェの雑踏', 'icon': Icons.coffee_rounded, 'path': 'audio/cafe.mp3'},
    {'id': 'wave', 'name': 'ディープウェーブ', 'icon': Icons.waves_rounded, 'path': 'audio/wave.mp3'},
  ];

  @override
  void initState() {
    super.initState();
    // ループ再生の設定
    _bgmPlayer.setReleaseMode(ReleaseMode.loop);
    _alarmPlayer.setReleaseMode(ReleaseMode.loop);
    
    // 1秒ごとに現在時刻をチェックするタイマーを開始
    _alarmCheckTimer = Timer.periodic(const Duration(seconds: 1), (_) => _checkAlarm());
    
  }

  @override
  void dispose() {
    _alarmCheckTimer?.cancel();
    _bgmPlayer.dispose();
    _alarmPlayer.dispose();
    super.dispose();
  }

  // --- アラーム時刻の判定ロジック ---
  void _checkAlarm() {
    if (!_isAlarmEnabled || _isAlarmRinging) return;

    final now = DateTime.now();
    if (now.hour == _selectedAlarmTime.hour && now.minute == _selectedAlarmTime.minute) {
      if (!_hasTriggeredAlarmToday) {
        _triggerAlarm();
      }
    } else {
      // 指定時刻を過ぎたらトリガーフラグをリセット（次の日のために）
      if (_hasTriggeredAlarmToday) {
        setState(() {
          _hasTriggeredAlarmToday = false;
        });
        _updateSheetIfOpen();
      }
    }
  }

  // アラーム鳴動開始
  void _triggerAlarm() async {
    setState(() {
      _isAlarmRinging = true;
      _hasTriggeredAlarmToday = true;
    });
    _updateSheetIfOpen();

    try {
      // アラーム音（alert.mp3）を大音量でループ再生
      await _alarmPlayer.setVolume(1.0);
      await _alarmPlayer.play(AssetSource('audio/alert.mp3'));
    } catch (e) {
      debugPrint('アラーム再生エラー: $e');
    }

    // ユーザーにアラームを知らせるダイアログを表示
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E24),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Row(
              children: [
                Icon(Icons.alarm_on_rounded, color: Color(0xFFFF7675)),
                SizedBox(width: 10),
                Text('設定時刻になりました', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              ],
            ),
            content: const Text('極上の目覚めのお時間です。今日も素晴らしい一日を始めましょう。', style: TextStyle(color: Colors.white70)),
            actions: [
              TextButton(
                onPressed: () {
                  _stopAlarmSound();
                  Navigator.of(context).pop();
                },
                child: const Text('アラームを停止', style: TextStyle(color: Color(0xFFFF7675), fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      );
    }
  }

  // アラーム停止処理
  void _stopAlarmSound() async {
    if (_isAlarmRinging) {
      await _alarmPlayer.stop();
      setState(() {
        _isAlarmRinging = false;
      });
      _updateSheetIfOpen();
    }
  }

  // ボトムシートが開いている場合、シート内のUIをリアルタイムに再描画させる
  void _updateSheetIfOpen() {
    if (_currentSheetLiveSetter != null) {
      try {
        _currentSheetLiveSetter!(() {});
      } catch (_) {}
    }
  }

  // --- 環境音（BGM）制御 ---
  void _toggleBgm(String path, String id) async {
    if (_currentBgm == id) {
      if (_isPlayingBgm) {
        await _bgmPlayer.pause();
        setState(() => _isPlayingBgm = false);
      } else {
        await _bgmPlayer.resume();
        setState(() => _isPlayingBgm = true);
      }
    } else {
      await _bgmPlayer.stop();
      await _bgmPlayer.setVolume(_bgmVolume);
      await _bgmPlayer.play(AssetSource(path));
      setState(() {
        _currentBgm = id;
        _isPlayingBgm = true;
      });
    }
    _updateSheetIfOpen();
  }

  void _setBgmVolume(double volume) async {
    setState(() => _bgmVolume = volume);
    await _bgmPlayer.setVolume(volume);
  }

  // --- ボトムシート表示 ---
  void _showAlarmSettingsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16161A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            top: 24,
            left: 16,
            right: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 32,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 24),
                _buildAlarmSelection(),
              ],
            ),
          ),
        );
      },
    ).whenComplete(() {
      _currentSheetLiveSetter = null;
    });
  }

  // 🟢 ご提示いただいた完璧な整合性のUIコンポーネント
  Widget _buildAlarmSelection() {
    return StatefulBuilder(
      builder: (context, setSheetState) {
        _currentSheetLiveSetter = setSheetState;

        final String hourStr = _selectedAlarmTime.hour.toString().padLeft(2, '0');
        final String minuteStr = _selectedAlarmTime.minute.toString().padLeft(2, '0');
        final String periodStr = _selectedAlarmTime.period == DayPeriod.am ? 'AM' : 'PM';

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _isAlarmEnabled ? '指定時刻にアラームが鳴ります' : 'アラームはオフです',
              style: TextStyle(
                color: _isAlarmEnabled ? const Color(0xFF2ECC71) : Colors.white60,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 24),

            GestureDetector(
              onTap: () async {
                final TimeOfDay? picked = await showTimePicker(
                  context: context,
                  initialTime: _selectedAlarmTime,
                  builder: (BuildContext context, Widget? child) {
                    return Theme(
                      data: ThemeData.dark().copyWith(
                        colorScheme: const ColorScheme.dark(
                          primary: Color(0xFF6C5CE7), 
                          onPrimary: Colors.white,
                          surface: Color(0xFF1E1E24), 
                          onSurface: Colors.white,
                        ),
                        timePickerTheme: TimePickerThemeData(
                          backgroundColor: const Color(0xFF1E1E24),
                          hourMinuteColor: Colors.white.withOpacity(0.05),
                          hourMinuteTextColor: Colors.white,
                          dayPeriodColor: Colors.white.withOpacity(0.05),
                          dayPeriodTextColor: Colors.white,
                        ),
                      ),
                      child: child!,
                    );
                  },
                );

                if (picked != null && picked != _selectedAlarmTime) {
                  setSheetState(() {
                    _selectedAlarmTime = picked;
                    _isAlarmEnabled = true;
                    _hasTriggeredAlarmToday = false;
                  });
                  setState(() {});
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.03),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: _isAlarmEnabled ? const Color(0xFF6C5CE7).withOpacity(0.3) : Colors.white10,
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Icon(
                      Icons.access_time_filled_rounded,
                      size: 20,
                      color: _isAlarmEnabled ? const Color(0xFF74B9FF) : Colors.white38,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '$hourStr:$minuteStr',
                      style: const TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      periodStr,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: _isAlarmEnabled ? const Color(0xFF74B9FF) : Colors.white38,
                      ),
                    ),
                  ],
                ),
              ),
            ), // 🟢 閉じ括弧が正しくネストを終了
            const SizedBox(height: 12),
            Text(
              '数値をタップして時刻を変更',
              style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 11),
            ),
            const SizedBox(height: 24),

            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF7675).withOpacity(0.15),
                foregroundColor: const Color(0xFFFF7675),
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              ),
              onPressed: _stopAlarmSound,
              icon: const Icon(Icons.alarm_off_rounded, size: 16),
              label: const Text('アラーム音を停止', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 24),

            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              margin: const EdgeInsets.symmetric(horizontal: 24), 
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.02),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          _isAlarmEnabled ? Icons.alarm_on_rounded : Icons.alarm_off_rounded,
                          color: _isAlarmEnabled ? const Color(0xFF2ECC71) : Colors.white30,
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'アラームを有効にする',
                            style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Switch(
                    value: _isAlarmEnabled,
                    activeColor: const Color(0xFF2ECC71),
                    activeTrackColor: const Color(0xFF2ECC71).withOpacity(0.3),
                    inactiveThumbColor: Colors.white60,
                    inactiveTrackColor: Colors.white12,
                    onChanged: (bool value) {
                      if (!value) {
                        _stopAlarmSound();
                      }
                      setSheetState(() {
                        _isAlarmEnabled = value;
                        if (value) _hasTriggeredAlarmToday = false;
                      });
                      setState(() {});
                    },
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),
            
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFF7675).withOpacity(0.08),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: const Color(0xFFFF7675).withOpacity(0.25),
                  width: 1,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.warning_amber_rounded, color: Color(0xFFFF7675), size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'PWA環境での動作に関するご注意',
                          style: TextStyle(color: Color(0xFFFF7675), fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'お使いのOS（特にiOS）の仕様により、画面をロックしたりバックグラウンドに移行すると、タイマーが一時停止しアラームが予定時刻に鳴らない場合があります。確実な動作のため、使用中は画面を点灯したまま（自動スリープオフ）にすることをおすすめします。',
                          style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 11, height: 1.4),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),
            Text(
              'スマート通知対応',
              style: TextStyle(color: Colors.white.withOpacity(0.2), fontSize: 11),
            ),
            const SizedBox(height: 20),

            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildStatusIcon(Icons.wifi, 'PWA', const Color(0xFF2ECC71)),
                const SizedBox(width: 24),
                _buildStatusIcon(Icons.person_off_rounded, 'オフライン対応', Colors.white24),
              ],
            ),
          ],
        );
      }
    );
  }

  Widget _buildStatusIcon(IconData icon, String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 11)),
      ],
    );
  }

  // --- メインダッシュボードUI ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'FOCUS WAVE',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 2),
        ),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  Icons.alarm_rounded,
                  color: _isAlarmEnabled ? const Color(0xFF6C5CE7) : Colors.white70,
                ),
                if (_isAlarmEnabled)
                  Positioned(
                    top: 2,
                    right: 2,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: Color(0xFF2ECC71),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            onPressed: _showAlarmSettingsSheet,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 10),
              Text(
                '集中サウンドを選択',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white.withOpacity(0.9),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'マインドフルネスを高める最適な環境音をループ再生します。',
                style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(0.4)),
              ),
              const SizedBox(height: 32),
              
              // 音声トラックグリッド
              Expanded(
                child: GridView.builder(
                  itemCount: _soundTracks.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                    childAspectRatio: 1.1,
                  ),
                  itemBuilder: (context, index) {
                    final track = _soundTracks[index];
                    final isCurrent = _currentBgm == track['id'];
                    final isPlayingThis = isCurrent && _isPlayingBgm;

                    return GestureDetector(
                      onTap: () => _toggleBgm(track['path'], track['id']),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOutCubic,
                        decoration: BoxDecoration(
                          color: isPlayingThis
                              ? const Color(0xFF6C5CE7).withOpacity(0.12)
                              : Colors.white.withOpacity(0.02),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: isPlayingThis
                                ? const Color(0xFF6C5CE7).withOpacity(0.6)
                                : isCurrent
                                    ? const Color(0xFF6C5CE7).withOpacity(0.2)
                                    : Colors.white.withOpacity(0.05),
                            width: 1.5,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              track['icon'],
                              size: 32,
                              color: isPlayingThis
                                  ? const Color(0xFF6C5CE7)
                                  : Colors.white60,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              track['name'],
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: isPlayingThis ? FontWeight.bold : FontWeight.w500,
                                color: isPlayingThis ? Colors.white : Colors.white70,
                              ),
                            ),
                            if (isCurrent) ...[
                              const SizedBox(height: 6),
                              Text(
                                isPlayingThis ? '再生中' : '一時停止',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: isPlayingThis ? const Color(0xFF2ECC71) : Colors.white30,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              
              // ボリュームバー制御
              if (_currentBgm != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.02),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withOpacity(0.04)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _bgmVolume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                        size: 18,
                        color: Colors.white54,
                      ),
                      Expanded(
                        child: Slider(
                          value: _bgmVolume,
                          min: 0.0,
                          max: 1.0,
                          activeColor: const Color(0xFF6C5CE7),
                          inactiveColor: Colors.white12,
                          onChanged: _setBgmVolume,
                        ),
                      ),
                      Text(
                        '${(_bgmVolume * 100).toInt()}%',
                        style: const TextStyle(fontSize: 12, color: Colors.white54, fontFamily: 'monospace'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }
}