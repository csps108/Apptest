import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:crop_your_image/crop_your_image.dart';

void main() {
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
enum FlowStep { preview, cropType, algorithm }

// 裁切類型
enum CropType { none, rectangle, circle }

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  bool isSidebarExpanded = true;
  final ImagePicker _picker = ImagePicker();
  final CropController _cropController = CropController();

  // 圖片
  Uint8List? _imageData; // 目前顯示（可能是裁切後）
  Uint8List? _originalImageData; // 原始照片

  // 流程狀態
  FlowStep _step = FlowStep.preview;
  CropType? _cropType; // 使用者選擇的裁切類型
  bool _isCropping = false; // 正在裁切畫面中
  bool _cropDone = false; // 裁切是否已完成（或選擇不裁切）
  String? _selectedAlgorithm; // 步驟 2 選擇的演算法

  // 演算法清單（可自行替換成你的實際演算法）
  final List<Map<String, dynamic>> _algorithms = [
    {'name': '灰階化', 'desc': '將影像轉為灰階', 'icon': Icons.filter_b_and_w},
    {'name': '二值化', 'desc': '依門檻值轉為黑白', 'icon': Icons.contrast},
    {'name': '邊緣偵測 (Canny)', 'desc': '找出影像邊緣輪廓', 'icon': Icons.border_style},
    {'name': '高斯模糊', 'desc': '降低雜訊、平滑影像', 'icon': Icons.blur_on},
  ];

  // ==================== 拍照 / 重置 ====================
  Future<void> _takePhoto() async {
    try {
      final XFile? photo = await _picker.pickImage(source: ImageSource.camera);
      if (photo != null) {
        final bytes = await photo.readAsBytes();
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
    _selectedAlgorithm = null;
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
    switch (_step) {
      case FlowStep.preview:
        return true;
      case FlowStep.cropType:
        return _cropType != null && _cropDone && !_isCropping;
      case FlowStep.algorithm:
        return _selectedAlgorithm != null;
    }
  }

  void _goNext() {
    if (!_canGoNext) return;
    setState(() {
      switch (_step) {
        case FlowStep.preview:
          _step = FlowStep.cropType;
          break;
        case FlowStep.cropType:
          _step = FlowStep.algorithm;
          break;
        case FlowStep.algorithm:
          _submit();
          break;
      }
    });
  }

  void _goBack() {
    setState(() {
      switch (_step) {
        case FlowStep.preview:
          break;
        case FlowStep.cropType:
          // 回到檢視照片：還原原圖、清除裁切選擇
          _imageData = _originalImageData;
          _cropType = null;
          _cropDone = false;
          _isCropping = false;
          _step = FlowStep.preview;
          break;
        case FlowStep.algorithm:
          // 回到裁切步驟：保留已裁切的圖與選擇
          _step = FlowStep.cropType;
          break;
      }
    });
  }

  void _submit() {
    debugPrint('送出：裁切=$_cropType, 演算法=$_selectedAlgorithm');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已送出：$_selectedAlgorithm')),
    );
  }

  // ==================== 裁切類型選擇 ====================
  void _selectCropType(CropType type) {
    setState(() {
      _cropType = type;
      _imageData = _originalImageData; // 每次重選都從原圖開始
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

  // ==================== UI 元件 ====================
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
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Colors.white,
      child: Row(
        children: [
          if (_step == FlowStep.preview)
            TextButton.icon(
              onPressed: _clearPhoto,
              icon: const Icon(Icons.close, color: Colors.redAccent),
              label: const Text('取消重拍',
                  style: TextStyle(color: Colors.redAccent, fontSize: 16)),
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
          if (_step == FlowStep.preview) const SizedBox(width: 100),
        ],
      ),
    );
  }

  Widget _buildBottomNav() {
    final bool isLast = _step == FlowStep.algorithm;
    final bool isFirst = _step == FlowStep.preview;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 6,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 上一步（檢視照片階段不顯示）
          isFirst
              ? const SizedBox(width: 100)
              : OutlinedButton.icon(
                  onPressed: _goBack,
                  icon: const Icon(Icons.arrow_back_ios, size: 16),
                  label: const Text('上一步'),
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                  ),
                ),
          // 下一步 / 確認 / 送出
          ElevatedButton(
            onPressed: _canGoNext ? _goNext : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              disabledBackgroundColor: Colors.grey.shade300,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
            ),
            child: Text(
              isFirst ? '確認' : (isLast ? '送出' : '下一步'),
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }

  // 一般圖片顯示（圓形裁切後用 ClipOval 顯示）
  Widget _buildImageView() {
    final bool showCircle = _cropType == CropType.circle && _cropDone;
    final image = Image.memory(_imageData!, fit: BoxFit.contain);
    return Center(child: showCircle ? ClipOval(child: image) : image);
  }

  // 裁切畫面
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

  Widget _buildOptionCard({
    required IconData icon,
    required String title,
    required String desc,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: selected ? 3 : 0,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? Colors.blue : Colors.grey.shade300,
          width: selected ? 2 : 1,
        ),
      ),
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon, color: selected ? Colors.blue : Colors.grey, size: 30),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(desc),
        trailing: selected
            ? const Icon(Icons.check_circle, color: Colors.blue)
            : const Icon(Icons.radio_button_unchecked, color: Colors.grey),
      ),
    );
  }

  // 步驟 1：裁切類型
  Widget _buildCropTypeStep() {
    if (_isCropping) return _buildCropper();

    return Column(
      children: [
        Expanded(child: _buildImageView()),
        const SizedBox(height: 8),
        _buildOptionCard(
          icon: Icons.crop_square,
          title: '矩形裁切',
          desc: '自由調整矩形範圍',
          selected: _cropType == CropType.rectangle,
          onTap: () => _selectCropType(CropType.rectangle),
        ),
        _buildOptionCard(
          icon: Icons.lens_outlined,
          title: '圓形裁切',
          desc: '以 1:1 圓形範圍裁切',
          selected: _cropType == CropType.circle,
          onTap: () => _selectCropType(CropType.circle),
        ),
        _buildOptionCard(
          icon: Icons.image_outlined,
          title: '不裁切',
          desc: '直接使用原始照片',
          selected: _cropType == CropType.none,
          onTap: () => _selectCropType(CropType.none),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  // 步驟 2：演算法
  Widget _buildAlgorithmStep() {
    return Column(
      children: [
        SizedBox(height: 180, child: _buildImageView()),
        const Divider(),
        Expanded(
          child: ListView(
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

  Widget _buildContent() {
    if (_imageData == null) {
      return const Center(
        child: Text('主畫面內容',
            style: TextStyle(fontSize: 24, color: Colors.grey)),
      );
    }
    switch (_step) {
      case FlowStep.preview:
        return _buildImageView();
      case FlowStep.cropType:
        return _buildCropTypeStep();
      case FlowStep.algorithm:
        return _buildAlgorithmStep();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // ==================== 左側縮放欄位 ====================
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: isSidebarExpanded ? 200 : 70,
            color: Colors.grey.shade200,
            child: Column(
              children: [
                const SizedBox(height: 40),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const NeverScrollableScrollPhysics(),
                  child: SizedBox(
                    width: isSidebarExpanded ? 200 : 70,
                    child: Column(
                      children: [
                        const CircleAvatar(
                          radius: 20,
                          backgroundColor: Colors.blue,
                          child: Icon(Icons.person, color: Colors.white),
                        ),
                        if (isSidebarExpanded) ...[
                          const SizedBox(height: 12),
                          const Text('User',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          const Text('Dept',
                              style:
                                  TextStyle(fontSize: 14, color: Colors.grey)),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Divider(height: 1),
                const SizedBox(height: 10),
                IconButton(
                  icon: const Icon(Icons.menu),
                  onPressed: () =>
                      setState(() => isSidebarExpanded = !isSidebarExpanded),
                ),
                const SizedBox(height: 20),
                Icon(Icons.home, color: Colors.grey.shade600),
              ],
            ),
          ),

          // ==================== 中間主內容區塊 ====================
          Expanded(
            child: Column(
              children: [
                // 頂部
                if (_imageData == null)
                  Padding(
                    padding: const EdgeInsets.all(16.0),
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
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 20),
                      ),
                    ),
                  )
                else
                  _buildHeader(),

                // 中間內容
                Expanded(child: _buildContent()),

                // 底部 上一步 / 下一步（裁切中不顯示）
                if (_imageData != null && !_isCropping) _buildBottomNav(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}