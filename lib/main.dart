import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:crop_your_image/crop_your_image.dart';

// ==================== 影像處理（必須是頂層函式，才能丟給 compute） ====================
Uint8List? applyAlgorithm(Uint8List bytes, String algorithm) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;

  img.Image result;
  switch (algorithm) {
    case '灰階化':
      result = img.grayscale(decoded);
      break;
    case '二值化':
      result = img.luminanceThreshold(img.grayscale(decoded), threshold: 0.5);
      break;
    case '邊緣偵測 (Sobel)':
      result = img.sobel(img.grayscale(decoded));
      break;
    case '高斯模糊':
      result = img.gaussianBlur(decoded, radius: 5);
      break;
    default:
      return null;
  }
  return Uint8List.fromList(img.encodeJpg(result, quality: 90));
}

Uint8List? processInIsolate(Map<String, dynamic> args) =>
    applyAlgorithm(args['bytes'] as Uint8List, args['algo'] as String);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MainScreen(),
    );
  }
}

// 流程步驟
enum FlowStep { preview, cropType, algorithm, result }

// 裁切類型
enum CropType { none, rectangle, circle }

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  bool isSidebarExpanded = true;
  final ImagePicker _picker = ImagePicker();
  final CropController _cropController = CropController();

  // 圖片
  Uint8List? _imageData; // 目前顯示（可能是裁切後）
  Uint8List? _originalImageData; // 原始照片
  Uint8List? _resultImage; // 演算法處理結果

  // 流程狀態
  FlowStep _step = FlowStep.preview;
  CropType? _cropType;
  bool _isCropping = false;
  bool _cropDone = false;
  bool _isProcessing = false;
  String? _selectedAlgorithm;

  final List<Map<String, dynamic>> _algorithms = [
    {'name': '灰階化', 'desc': '將影像轉為灰階', 'icon': Icons.filter_b_and_w},
    {'name': '二值化', 'desc': '依門檻值轉為黑白', 'icon': Icons.contrast},
    {'name': '邊緣偵測 (Sobel)', 'desc': '找出影像邊緣輪廓', 'icon': Icons.border_style},
    {'name': '高斯模糊', 'desc': '降低雜訊、平滑影像', 'icon': Icons.blur_on},
  ];

  // ==================== 拍照 / 重置 ====================
  Future<void> _takePhoto() async {
    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 90,
      );
      if (photo != null) {
        final bytes = await photo.readAsBytes();
        if (!mounted) return;
        setState(() {
          _imageData = bytes;
          _originalImageData = bytes;
          _resetFlow();
          isSidebarExpanded = false;
        });
      }
    } catch (e) {
      debugPrint('無法開啟相機：$e');
    }
  }

  void _resetFlow() {
    _step = FlowStep.preview;
    _cropType = null;
    _isCropping = false;
    _cropDone = false;
    _isProcessing = false;
    _selectedAlgorithm = null;
    _resultImage = null;
  }

  void _clearPhoto() {
    setState(() {
      _imageData = null;
      _originalImageData = null;
      _resetFlow();
      isSidebarExpanded = true;
    });
  }

  // ==================== 上一步 / 下一步 ====================
  bool get _canGoNext {
    if (_isProcessing) return false;
    switch (_step) {
      case FlowStep.preview:
        return true;
      case FlowStep.cropType:
        return _cropType != null && _cropDone && !_isCropping;
      case FlowStep.algorithm:
        return _selectedAlgorithm != null;
      case FlowStep.result:
        return true;
    }
  }

  void _goNext() {
    if (!_canGoNext) return;
    switch (_step) {
      case FlowStep.preview:
        setState(() => _step = FlowStep.cropType);
        break;
      case FlowStep.cropType:
        setState(() => _step = FlowStep.algorithm);
        break;
      case FlowStep.algorithm:
        _runAlgorithm();
        break;
      case FlowStep.result:
        _clearPhoto(); // 完成，回到主畫面
        break;
    }
  }

  void _goBack() {
    if (_isProcessing) return;
    setState(() {
      switch (_step) {
        case FlowStep.preview:
          break;
        case FlowStep.cropType:
          _imageData = _originalImageData;
          _cropType = null;
          _cropDone = false;
          _isCropping = false;
          _step = FlowStep.preview;
          break;
        case FlowStep.algorithm:
          _step = FlowStep.cropType;
          break;
        case FlowStep.result:
          _resultImage = null;
          _step = FlowStep.algorithm;
          break;
      }
    });
  }

  Future<void> _runAlgorithm() async {
    if (_imageData == null || _selectedAlgorithm == null) return;

    setState(() => _isProcessing = true);

    Uint8List? result;
    try {
      result = await compute(processInIsolate, {
        'bytes': _imageData!,
        'algo': _selectedAlgorithm!,
      });
    } catch (e) {
      debugPrint('處理失敗：$e');
    }

    if (!mounted) return;

    if (result == null) {
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('影像處理失敗，請重試')),
      );
      return;
    }

    setState(() {
      _isProcessing = false;
      _resultImage = result;
      _step = FlowStep.result;
    });
  }

  // ==================== 裁切 ====================
  void _selectCropType(CropType type) {
    setState(() {
      _cropType = type;
      _imageData = _originalImageData;
      if (type == CropType.none) {
        _cropDone = true;
        _isCropping = false;
      } else {
        _cropDone = false;
        _isCropping = true;
      }
    });
  }

  void _cancelCrop() {
    setState(() {
      _isCropping = false;
      _cropType = null;
      _cropDone = false;
      _imageData = _originalImageData;
    });
  }

  // ==================== UI：側欄 ====================
  Widget _buildSidebarContent(bool expanded) {
    return Column(
      children: [
        const SizedBox(height: 40),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: SizedBox(
            width: expanded ? 200 : 70,
            child: Column(
              children: [
                const CircleAvatar(
                  radius: 20,
                  backgroundColor: Colors.blue,
                  child: Icon(Icons.person, color: Colors.white),
                ),
                if (expanded) ...[
                  const SizedBox(height: 12),
                  const Text('User',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text('Dept',
                      style: TextStyle(fontSize: 14, color: Colors.grey)),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        const Divider(height: 1),
        const SizedBox(height: 10),
      ],
    );
  }

  // 平板 / 桌面：可收合側欄
  Widget _buildSidebar() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: isSidebarExpanded ? 200 : 70,
      color: Colors.grey.shade200,
      child: Column(
        children: [
          _buildSidebarContent(isSidebarExpanded),
          IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () =>
                setState(() => isSidebarExpanded = !isSidebarExpanded),
          ),
          const SizedBox(height: 20),
          Icon(Icons.home, color: Colors.grey.shade600),
        ],
      ),
    );
  }

  // 手機：抽屜
  Widget _buildDrawer() {
    return Drawer(
      width: 220,
      child: Container(
        color: Colors.grey.shade200,
        child: Column(
          children: [
            _buildSidebarContent(true),
            ListTile(
              leading: Icon(Icons.home, color: Colors.grey.shade700),
              title: const Text('首頁'),
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== UI：標題與底部導覽 ====================
  Widget _buildHeader() {
    String title;
    String? subtitle;
    switch (_step) {
      case FlowStep.preview:
        title = '檢視照片';
        break;
      case FlowStep.cropType:
        title = '選擇裁切類型';
        subtitle = '步驟 1 / 2';
        break;
      case FlowStep.algorithm:
        title = '選擇演算法';
        subtitle = '步驟 2 / 2';
        break;
      case FlowStep.result:
        title = '處理結果';
        break;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      color: Colors.white,
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: _step == FlowStep.preview
                ? TextButton.icon(
                    onPressed: _clearPhoto,
                    icon: const Icon(Icons.close,
                        size: 18, color: Colors.redAccent),
                    label: const Text('取消重拍',
                        style:
                            TextStyle(color: Colors.redAccent, fontSize: 14)),
                  )
                : null,
          ),
          Expanded(
            child: Column(
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                if (subtitle != null)
                  Text(subtitle,
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
          const SizedBox(width: 110),
        ],
      ),
    );
  }

  Widget _buildBottomNav() {
    final bool isFirst = _step == FlowStep.preview;
    final bool isResult = _step == FlowStep.result;

    String nextLabel;
    switch (_step) {
      case FlowStep.preview:
        nextLabel = '確認';
        break;
      case FlowStep.cropType:
        nextLabel = '下一步';
        break;
      case FlowStep.algorithm:
        nextLabel = '套用';
        break;
      case FlowStep.result:
        nextLabel = '完成';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(20),
            blurRadius: 6,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          isFirst
              ? const SizedBox(width: 100)
              : OutlinedButton.icon(
                  onPressed: _isProcessing ? null : _goBack,
                  icon: const Icon(Icons.arrow_back_ios, size: 16),
                  label: const Text('上一步'),
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                  ),
                ),
          ElevatedButton(
            onPressed: _canGoNext ? _goNext : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: isResult ? Colors.green : Colors.blue,
              disabledBackgroundColor: Colors.grey.shade300,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
            ),
            child: Text(
              nextLabel,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== UI：圖片 / 裁切 ====================
  Widget _buildImageView({Uint8List? data}) {
    final bytes = data ?? _imageData!;
    final bool showCircle = _cropType == CropType.circle && _cropDone;
    final image = Image.memory(bytes, fit: BoxFit.contain);
    return Center(child: showCircle ? ClipOval(child: image) : image);
  }

  Widget _buildCropper() {
    final bool isCircle = _cropType == CropType.circle;
    return Stack(
      fit: StackFit.expand,
      children: [
        Crop(
          image: _imageData!,
          controller: _cropController,
          aspectRatio: isCircle ? 1.0 : null,
          withCircleUi: isCircle,
          onCropped: (result) {
            if (result is CropSuccess) {
              setState(() {
                _imageData = result.croppedImage;
                _isCropping = false;
                _cropDone = true;
              });
            } else {
              debugPrint('裁切發生錯誤');
              _cancelCrop();
            }
          },
        ),
        Positioned(
          right: 20,
          bottom: 20,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FloatingActionButton(
                heroTag: 'cancelCrop',
                onPressed: _cancelCrop,
                backgroundColor: Colors.redAccent,
                child: const Icon(Icons.close, color: Colors.white),
              ),
              const SizedBox(width: 16),
              FloatingActionButton(
                heroTag: 'confirmCrop',
                onPressed: () => _cropController.crop(),
                backgroundColor: Colors.green,
                child: const Icon(Icons.check, color: Colors.white),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // 演算法清單用的卡片
  Widget _buildOptionCard({
    required IconData icon,
    required String title,
    required String desc,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: selected ? 3 : 0,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? Colors.blue : Colors.grey.shade300,
          width: selected ? 2 : 1,
        ),
      ),
      child: ListTile(
        onTap: onTap,
        leading:
            Icon(icon, color: selected ? Colors.blue : Colors.grey, size: 28),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(desc),
        trailing: selected
            ? const Icon(Icons.check_circle, color: Colors.blue)
            : const Icon(Icons.radio_button_unchecked, color: Colors.grey),
      ),
    );
  }

  // 裁切類型用的橫向小按鈕（省垂直空間）
  Widget _buildCompactOption(
      IconData icon, String label, bool selected, VoidCallback onTap) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? Colors.blue : Colors.grey.shade300,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  color: selected ? Colors.blue : Colors.grey, size: 28),
              const SizedBox(height: 4),
              Text(label, style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }

  // 步驟 1：裁切類型
  Widget _buildCropTypeStep() {
    if (_isCropping) return _buildCropper();

    return Column(
      children: [
        Expanded(child: _buildImageView()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Row(
            children: [
              _buildCompactOption(Icons.crop_square, '矩形',
                  _cropType == CropType.rectangle,
                  () => _selectCropType(CropType.rectangle)),
              _buildCompactOption(Icons.lens_outlined, '圓形',
                  _cropType == CropType.circle,
                  () => _selectCropType(CropType.circle)),
              _buildCompactOption(Icons.image_outlined, '不裁切',
                  _cropType == CropType.none,
                  () => _selectCropType(CropType.none)),
            ],
          ),
        ),
      ],
    );
  }

  // 步驟 2：演算法
  Widget _buildAlgorithmStep() {
    return Column(
      children: [
        SizedBox(height: 160, child: _buildImageView()),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 6),
            children: _algorithms.map((algo) {
              return _buildOptionCard(
                icon: algo['icon'] as IconData,
                title: algo['name'] as String,
                desc: algo['desc'] as String,
                selected: _selectedAlgorithm == algo['name'],
                onTap: () =>
                    setState(() => _selectedAlgorithm = algo['name'] as String),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  // 結果頁
  Widget _buildResultStep() {
    return Column(
      children: [
        Expanded(child: _buildImageView(data: _resultImage ?? _imageData)),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            '已套用：${_selectedAlgorithm ?? ''}',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
          ),
        ),
      ],
    );
  }

  Widget _buildContent() {
    if (_imageData == null) {
      return const Center(
        child: Text('主畫面內容',
            style: TextStyle(fontSize: 24, color: Colors.grey)),
      );
    }

    Widget content;
    switch (_step) {
      case FlowStep.preview:
        content = _buildImageView();
        break;
      case FlowStep.cropType:
        content = _buildCropTypeStep();
        break;
      case FlowStep.algorithm:
        content = _buildAlgorithmStep();
        break;
      case FlowStep.result:
        content = _buildResultStep();
        break;
    }

    // 處理中的遮罩
    return Stack(
      children: [
        Positioned.fill(child: content),
        if (_isProcessing)
          Positioned.fill(
            child: Container(
              color: Colors.black38,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('處理中...',
                        style: TextStyle(color: Colors.white, fontSize: 16)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  // 主畫面頂部搜尋列
  Widget _buildSearchBar(bool isPhone) {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Row(
        children: [
          if (isPhone)
            IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
          Expanded(
            child: TextField(
              decoration: InputDecoration(
                hintText: '搜尋...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.camera_alt, color: Colors.blue),
                  onPressed: _takePhoto,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30.0),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isPhone = MediaQuery.of(context).size.width < 600;

    return Scaffold(
      key: _scaffoldKey,
      drawer: isPhone ? _buildDrawer() : null,
      body: SafeArea(
        child: Row(
          children: [
            if (!isPhone) _buildSidebar(),
            Expanded(
              child: Column(
                children: [
                  if (_imageData == null)
                    _buildSearchBar(isPhone)
                  else
                    _buildHeader(),
                  Expanded(child: _buildContent()),
                  if (_imageData != null && !_isCropping) _buildBottomNav(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}