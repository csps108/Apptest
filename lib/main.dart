import 'dart:typed_data';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

// ==================== 背景影像處理（頂層函式） ====================
Map<String, dynamic>? applyAlgorithm(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final algorithm = args['algo'] as String;
  final rectList = args['rect'] as List<double>?;

  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;

  img.Image result = decoded.clone();
  String? overlayText;

  switch (algorithm) {
    case '量測 - 真圓度':
      final gray = img.grayscale(decoded.clone());
      
      // 1. 取得定位框範圍 (向內縮 3 像素，避開定位框暗色邊緣)
      int startX = 0, startY = 0, endX = gray.width - 1, endY = gray.height - 1;
      if (rectList != null) {
        final minX = (min(rectList[0], rectList[2]) * gray.width).toInt() + 3;
        final maxX = (max(rectList[0], rectList[2]) * gray.width).toInt() - 3;
        final minY = (min(rectList[1], rectList[3]) * gray.height).toInt() + 3;
        final maxY = (max(rectList[1], rectList[3]) * gray.height).toInt() - 3;
        
        startX = minX.clamp(0, gray.width - 1);
        endX = maxX.clamp(0, gray.width - 1);
        startY = minY.clamp(0, gray.height - 1);
        endY = maxY.clamp(0, gray.height - 1);
      }

      int roiW = endX - startX + 1;
      int roiH = endY - startY + 1;
      if (roiW <= 10 || roiH <= 10) {
        overlayText = '定位範圍過小，請重新框選';
        break;
      }

      // 2. Otsu 自動閾值演算法
      List<int> hist = List.filled(256, 0);
      for (int y = startY; y <= endY; y++) {
        for (int x = startX; x <= endX; x++) {
          hist[gray.getPixel(x, y).r.toInt()]++;
        }
      }

      int totalPixels = roiW * roiH;
      double sum = 0;
      for (int i = 0; i < 256; i++) sum += i * hist[i];

      double sumB = 0;
      int wB = 0;
      double maxVariance = 0;
      int otsuThreshold = 128;

      for (int t = 0; t < 256; t++) {
        wB += hist[t];
        if (wB == 0) continue;
        int wF = totalPixels - wB;
        if (wF == 0) break;

        sumB += t * hist[t];
        double mB = sumB / wB;
        double mF = (sum - sumB) / wF;

        double variance = wB.toDouble() * wF.toDouble() * (mB - mF) * (mB - mF);
        if (variance > maxVariance) {
          maxVariance = variance;
          otsuThreshold = t;
        }
      }

      int centerLum = gray.getPixel((startX + endX) ~/ 2, (startY + endY) ~/ 2).r.toInt();
      bool targetIsBright = centerLum >= otsuThreshold;

      List<bool> binary = List.filled(roiW * roiH, false);
      for (int y = 0; y < roiH; y++) {
        for (int x = 0; x < roiW; x++) {
          int lum = gray.getPixel(startX + x, startY + y).r.toInt();
          binary[y * roiW + x] = targetIsBright ? (lum >= otsuThreshold) : (lum < otsuThreshold);
        }
      }

      // 3. 尋找種子起點
      int seedX = roiW ~/ 2;
      int seedY = roiH ~/ 2;
      bool foundSeed = false;

      if (binary[seedY * roiW + seedX]) {
        foundSeed = true;
      } else {
        for (int r = 1; r < min(roiW, roiH) ~/ 2 && !foundSeed; r++) {
          for (int dy = -r; dy <= r && !foundSeed; dy++) {
            for (int dx = -r; dx <= r && !foundSeed; dx++) {
              int testX = seedX + dx;
              int testY = seedY + dy;
              if (testX >= 0 && testX < roiW && testY >= 0 && testY < roiH) {
                if (binary[testY * roiW + testX]) {
                  seedX = testX;
                  seedY = testY;
                  foundSeed = true;
                }
              }
            }
          }
        }
      }

      if (!foundSeed) {
        overlayText = '框選中心未找到目標物件';
        break;
      }

      // 4. 連通域分析 (BFS Flood Fill)：隔離背景
      Uint8List visited = Uint8List(roiW * roiH);
      List<int> qX = [];
      List<int> qY = [];
      qX.add(seedX);
      qY.add(seedY);
      visited[seedY * roiW + seedX] = 1;

      int head = 0;
      int area = 0;
      int sumObjX = 0;
      int sumObjY = 0;

      final dxList = [1, -1, 0, 0];
      final dyList = [0, 0, 1, -1];

      while (head < qX.length) {
        int cx = qX[head];
        int cy = qY[head];
        head++;

        area++;
        sumObjX += (startX + cx);
        sumObjY += (startY + cy);

        for (int i = 0; i < 4; i++) {
          int nx = cx + dxList[i];
          int ny = cy + dyList[i];

          if (nx >= 0 && nx < roiW && ny >= 0 && ny < roiH) {
            int nIdx = ny * roiW + nx;
            if (visited[nIdx] == 0 && binary[nIdx]) {
              visited[nIdx] = 1;
              qX.add(nx);
              qY.add(ny);
            }
          }
        }
      }

      if (area < 30) {
        overlayText = '偵測到的物體過小，請重新確認';
        break;
      }

      int realCenterX = sumObjX ~/ area;
      int realCenterY = sumObjY ~/ area;
      double maxRadius = 0;

      // 5. 提取真實輪廓邊緣並畫上黃色線
      for (int i = 0; i < qX.length; i++) {
        int lx = qX[i];
        int ly = qY[i];

        bool isContour = false;
        for (int d = 0; d < 4; d++) {
          int nx = lx + dxList[d];
          int ny = ly + dyList[d];
          if (nx < 0 || nx >= roiW || ny < 0 || ny >= roiH || visited[ny * roiW + nx] == 0) {
            isContour = true;
            break;
          }
        }

        if (isContour) {
          int gx = startX + lx;
          int gy = startY + ly;

          for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
              int px = gx + dx;
              int py = gy + dy;
              if (px >= 0 && px < result.width && py >= 0 && py < result.height) {
                result.setPixelRgb(px, py, 255, 255, 0);
              }
            }
          }

          double dist = sqrt(pow(gx - realCenterX, 2) + pow(gy - realCenterY, 2));
          if (dist > maxRadius) maxRadius = dist;
        }
      }

      // 6. 畫出綠色外接圓與紅色質心
      img.drawCircle(result, x: realCenterX, y: realCenterY, radius: maxRadius.toInt(), color: img.ColorRgb8(0, 255, 0));
      img.drawCircle(result, x: realCenterX, y: realCenterY, radius: maxRadius.toInt() - 1, color: img.ColorRgb8(0, 255, 0));
      img.fillCircle(result, x: realCenterX, y: realCenterY, radius: 4, color: img.ColorRgb8(255, 0, 0));

      // 7. 計算真圓度
      double boundingArea = pi * maxRadius * maxRadius;
      double circ = boundingArea > 0 ? (area / boundingArea) : 0;
      circ = (circ.clamp(0.0, 1.0)) * 100;

      overlayText = '真圓度：${circ.toStringAsFixed(2)} %\n(黃色:目標輪廓, 綠色:完美外接圓)';
      break;

    case '前後對比':
      final halfWidth = result.width ~/ 2;
      final gray = img.grayscale(decoded.clone());
      for (int y = 0; y < result.height; y++) {
        for (int x = halfWidth; x < result.width; x++) {
          result.setPixel(x, y, gray.getPixel(x, y));
        }
      }
      img.drawLine(result, x1: halfWidth, y1: 0, x2: halfWidth, y2: result.height, color: img.ColorRgb8(255, 255, 255), thickness: 4);
      overlayText = '左：原圖 / 右：灰階濾鏡';
      break;

    case '邊緣偵測 (Sobel)':
      result = img.sobel(img.grayscale(decoded.clone()));
      break;

    case '高斯模糊':
      result = img.gaussianBlur(decoded.clone(), radius: 5);
      break;

    default:
      return null;
  }

  return {
    'bytes': Uint8List.fromList(img.encodeJpg(result, quality: 90)),
    'text': overlayText,
  };
}

Map<String, dynamic>? processInIsolate(Map<String, dynamic> args) => applyAlgorithm(args);

Uint8List? applyMaskToImage(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final rectList = args['rect'] as List<double>;
  final isCircle = args['isCircle'] as bool;

  final image = img.decodeImage(bytes);
  if (image == null) return null;

  int xMin = (rectList[0] * image.width).toInt();
  int yMin = (rectList[1] * image.height).toInt();
  int xMax = (rectList[2] * image.width).toInt();
  int yMax = (rectList[3] * image.height).toInt();

  final realXMin = min(xMin, xMax);
  final realXMax = max(xMin, xMax);
  final realYMin = min(yMin, yMax);
  final realYMax = max(yMin, yMax);

  int cx = (realXMin + realXMax) ~/ 2;
  int cy = (realYMin + realYMax) ~/ 2;
  int rx = (realXMax - realXMin) ~/ 2;
  int ry = (realYMax - realYMin) ~/ 2;

  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      bool inside = false;
      if (isCircle) {
        num dx = x - cx;
        num dy = y - cy;
        inside = (rx > 0 && ry > 0) &&
            ((dx * dx) / (rx * rx) + (dy * dy) / (ry * ry) <= 1.0);
      } else {
        inside = x >= realXMin && x <= realXMax && y >= realYMin && y <= realYMax;
      }
      
      if (!inside) {
        final p = image.getPixel(x, y);
        image.setPixelRgb(x, y, (p.r * 0.3).toInt(), (p.g * 0.3).toInt(), (p.b * 0.3).toInt());
      }
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

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

enum FlowStep { preview, cropType, algorithm, result }
enum CropType { none, rectangle, circle }
enum DragArea { none, center, topLeft, topRight, bottomLeft, bottomRight }

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  bool isSidebarExpanded = true;
  final ImagePicker _picker = ImagePicker();

  Uint8List? _imageData;
  Uint8List? _originalImageData;
  Uint8List? _resultImage;
  String? _resultText;
  ui.Image? _decodedUiImage;

  // 定位狀態
  Rect? _normalizedRect;
  DragArea _currentDragArea = DragArea.none;

  // 手動量測距離狀態
  Offset? _measureStart;
  Offset? _measureEnd;

  FlowStep _step = FlowStep.preview;
  CropType? _cropType;
  bool _isCropping = false;
  bool _cropDone = false;
  bool _isProcessing = false;
  String? _selectedAlgorithm;
  String _measureMode = '距離'; 

  final List<Map<String, dynamic>> _algorithms = [
    {'name': '量測', 'desc': '進行影像特徵或尺寸量測', 'icon': Icons.straighten},
    {'name': '前後對比', 'desc': '檢視原圖與處理後的差異', 'icon': Icons.compare},
    {'name': '邊緣偵測 (Sobel)', 'desc': '找出影像邊緣輪廓', 'icon': Icons.border_style},
    {'name': '高斯模糊', 'desc': '降低雜訊、平滑影像', 'icon': Icons.blur_on},
  ];

  Future<void> _takePhoto() async {
    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera, 
        maxWidth: 1600, 
        maxHeight: 1600, 
        imageQuality: 90
      );
      if (photo != null) {
        final bytes = await photo.readAsBytes();
        if (!mounted) return;
        setState(() => _isProcessing = true);
        await _decodeUiImage(bytes);
        setState(() {
          _imageData = bytes;
          _originalImageData = bytes;
          _resetFlow();
          isSidebarExpanded = false;
          _isProcessing = false;
        });
      }
    } catch (e) {
      debugPrint('無法開啟相機：$e');
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _decodeUiImage(Uint8List bytes) async {
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    final ui.FrameInfo frame = await codec.getNextFrame();
    _decodedUiImage?.dispose();
    _decodedUiImage = frame.image;
  }

  void _resetFlow() {
    _step = FlowStep.preview;
    _cropType = null;
    _isCropping = false;
    _cropDone = false;
    _selectedAlgorithm = null;
    _resultImage = null;
    _resultText = null;
    _normalizedRect = null;
    _measureStart = null;
    _measureEnd = null;
  }

  void _clearPhoto() {
    _decodedUiImage?.dispose();
    _decodedUiImage = null;
    setState(() {
      _imageData = null;
      _originalImageData = null;
      _resetFlow();
      isSidebarExpanded = true;
    });
  }

  bool get _canGoNext {
    if (_isProcessing) return false;
    switch (_step) {
      case FlowStep.preview: return true;
      case FlowStep.cropType: return _cropType != null && _cropDone && !_isCropping;
      case FlowStep.algorithm: return _selectedAlgorithm != null;
      case FlowStep.result: return true;
    }
  }

  void _goNext() {
    if (!_canGoNext) return;
    switch (_step) {
      case FlowStep.preview: setState(() => _step = FlowStep.cropType); break;
      case FlowStep.cropType: setState(() => _step = FlowStep.algorithm); break;
      case FlowStep.algorithm: _runAlgorithm(); break;
      case FlowStep.result: _clearPhoto(); break;
    }
  }

  void _goBack() {
    if (_isProcessing) return;
    setState(() {
      switch (_step) {
        case FlowStep.preview: break;
        case FlowStep.cropType:
          _imageData = _originalImageData;
          _cropType = null;
          _cropDone = false;
          _isCropping = false;
          _normalizedRect = null;
          _step = FlowStep.preview;
          break;
        case FlowStep.algorithm: _step = FlowStep.cropType; break;
        case FlowStep.result: 
          _resultImage = null; 
          _resultText = null;
          _measureStart = null;
          _measureEnd = null;
          _step = FlowStep.algorithm; 
          break;
      }
    });
  }

  Future<void> _runAlgorithm() async {
    if (_imageData == null || _selectedAlgorithm == null) return;
    setState(() => _isProcessing = true);

    if (_selectedAlgorithm == '量測' && _measureMode == '距離') {
      setState(() {
        _isProcessing = false;
        _resultImage = _imageData; 
        _resultText = '請在上方圖片拖曳滑動，拉取測量線';
        _measureStart = null;
        _measureEnd = null;
        _step = FlowStep.result;
      });
      return;
    }

    Map<String, dynamic>? result;
    try {
      final String algoName = _selectedAlgorithm == '量測' ? '量測 - $_measureMode' : _selectedAlgorithm!;
      List<double>? rectCoords;
      if (_normalizedRect != null) {
        rectCoords = [_normalizedRect!.left, _normalizedRect!.top, _normalizedRect!.right, _normalizedRect!.bottom];
      }

      result = await compute(processInIsolate, {
        'bytes': _imageData!, 
        'algo': algoName,
        'rect': rectCoords
      });
    } catch (e) {
      debugPrint('處理失敗：$e');
    }
    
    if (!mounted) return;
    if (result == null) {
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('影像處理失敗，請重試')));
      return;
    }
    setState(() {
      _isProcessing = false;
      _resultImage = result!['bytes'] as Uint8List;
      _resultText = result!['text'] as String?;
      _step = FlowStep.result;
    });
  }

  void _selectCropType(CropType type) {
    setState(() {
      _cropType = type;
      _imageData = _originalImageData;
      if (type == CropType.none) {
        _cropDone = true;
        _isCropping = false;
        _normalizedRect = null;
      } else {
        _cropDone = false;
        _isCropping = true;
        _normalizedRect = const Rect.fromLTRB(0.2, 0.2, 0.8, 0.8);
      }
    });
  }

  void _cancelCrop() {
    setState(() {
      _isCropping = false;
      _cropType = null;
      _cropDone = false;
      _imageData = _originalImageData;
      _normalizedRect = null;
    });
  }

  Future<void> _confirmLocate() async {
    if (_normalizedRect == null) return;
    setState(() => _isProcessing = true);

    Uint8List? result;
    try {
      result = await compute(applyMaskToImage, {
        'bytes': _originalImageData!,
        'rect': [_normalizedRect!.left, _normalizedRect!.top, _normalizedRect!.right, _normalizedRect!.bottom],
        'isCircle': _cropType == CropType.circle,
      });
    } catch (e) {
      debugPrint('Mask處理失敗：$e');
    }

    if (!mounted) return;
    setState(() {
      _isProcessing = false;
      if (result != null) {
        _imageData = result;
        _cropDone = true;
        _isCropping = false;
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('定位處理失敗，請重試')));
      }
    });
  }

  Rect _calculateImageRect(Size widgetSize, ui.Image image) {
    final double widgetRatio = widgetSize.width / widgetSize.height;
    final double imageRatio = image.width / image.height;
    double drawWidth, drawHeight, offsetX, offsetY;
    if (widgetRatio > imageRatio) {
      drawHeight = widgetSize.height;
      drawWidth = drawHeight * imageRatio;
      offsetX = (widgetSize.width - drawWidth) / 2;
      offsetY = 0;
    } else {
      drawWidth = widgetSize.width;
      drawHeight = drawWidth / imageRatio;
      offsetX = 0;
      offsetY = (widgetSize.height - drawHeight) / 2;
    }
    return Rect.fromLTWH(offsetX, offsetY, drawWidth, drawHeight);
  }

  Offset _mapToImage(Offset localPos, Rect imageRect) {
    double dx = (localPos.dx - imageRect.left) / imageRect.width;
    double dy = (localPos.dy - imageRect.top) / imageRect.height;
    return Offset(dx, dy); 
  }

  Widget _buildImageView({Uint8List? data}) {
    final bytes = data ?? _imageData!;
    return Center(child: Image.memory(bytes, fit: BoxFit.contain));
  }

  Widget _buildCropper() {
    if (_decodedUiImage == null) return const Center(child: CircularProgressIndicator());

    return Stack(
      fit: StackFit.expand,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final imageRect = _calculateImageRect(constraints.biggest, _decodedUiImage!);
            return GestureDetector(
              onPanStart: (details) {
                if (_normalizedRect == null) return;
                final tap = _mapToImage(details.localPosition, imageRect);
                final rect = _normalizedRect!;
                final tolX = 35.0 / imageRect.width;
                final tolY = 35.0 / imageRect.height;
                if ((tap.dx - rect.left).abs() < tolX && (tap.dy - rect.top).abs() < tolY) _currentDragArea = DragArea.topLeft;
                else if ((tap.dx - rect.right).abs() < tolX && (tap.dy - rect.top).abs() < tolY) _currentDragArea = DragArea.topRight;
                else if ((tap.dx - rect.left).abs() < tolX && (tap.dy - rect.bottom).abs() < tolY) _currentDragArea = DragArea.bottomLeft;
                else if ((tap.dx - rect.right).abs() < tolX && (tap.dy - rect.bottom).abs() < tolY) _currentDragArea = DragArea.bottomRight;
                else if (rect.contains(tap)) _currentDragArea = DragArea.center;
                else _currentDragArea = DragArea.none;
              },
              onPanUpdate: (details) {
                if (_currentDragArea == DragArea.none || _normalizedRect == null) return;
                final deltaX = details.delta.dx / imageRect.width;
                final deltaY = details.delta.dy / imageRect.height;
                double newLeft = _normalizedRect!.left, newTop = _normalizedRect!.top, newRight = _normalizedRect!.right, newBottom = _normalizedRect!.bottom;
                if (_currentDragArea == DragArea.center) {
                  newLeft += deltaX; newRight += deltaX; newTop += deltaY; newBottom += deltaY;
                  if (newLeft < 0) { newRight -= newLeft; newLeft = 0; }
                  if (newTop < 0) { newBottom -= newTop; newTop = 0; }
                  if (newRight > 1) { newLeft -= (newRight - 1); newRight = 1; }
                  if (newBottom > 1) { newTop -= (newBottom - 1); newBottom = 1; }
                } else {
                  if (_currentDragArea == DragArea.topLeft) { newLeft += deltaX; newTop += deltaY; }
                  if (_currentDragArea == DragArea.topRight) { newRight += deltaX; newTop += deltaY; }
                  if (_currentDragArea == DragArea.bottomLeft) { newLeft += deltaX; newBottom += deltaY; }
                  if (_currentDragArea == DragArea.bottomRight) { newRight += deltaX; newBottom += deltaY; }
                  if (newRight - newLeft < 0.1) {
                    if (_currentDragArea == DragArea.topLeft || _currentDragArea == DragArea.bottomLeft) newLeft = newRight - 0.1;
                    else newRight = newLeft + 0.1;
                  }
                  if (newBottom - newTop < 0.1) {
                    if (_currentDragArea == DragArea.topLeft || _currentDragArea == DragArea.topRight) newTop = newBottom - 0.1;
                    else newBottom = newTop + 0.1;
                  }
                }
                setState(() => _normalizedRect = Rect.fromLTRB(newLeft.clamp(0.0, 1.0), newTop.clamp(0.0, 1.0), newRight.clamp(0.0, 1.0), newBottom.clamp(0.0, 1.0)));
              },
              onPanEnd: (_) => _currentDragArea = DragArea.none,
              child: Stack(fit: StackFit.expand, children: [
                Image.memory(_imageData!, fit: BoxFit.contain),
                CustomPaint(painter: CustomLocatePainter(imageDrawRect: imageRect, normalizedRect: _normalizedRect, isCircle: _cropType == CropType.circle)),
              ]),
            );
          },
        ),
        Positioned(
          right: 20, bottom: 20,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            FloatingActionButton(heroTag: 'cancelLocate', onPressed: _cancelCrop, backgroundColor: Colors.redAccent, child: const Icon(Icons.close, color: Colors.white)),
            const SizedBox(width: 16),
            FloatingActionButton(heroTag: 'confirmLocate', onPressed: _normalizedRect == null ? null : _confirmLocate, backgroundColor: _normalizedRect == null ? Colors.grey : Colors.green, child: const Icon(Icons.check, color: Colors.white)),
          ]),
        ),
      ],
    );
  }

  // ==================== 排版與控制元件 ====================
  Widget _buildSidebarContent(bool expanded) {
    return Column(children: [
      const SizedBox(height: 40),
      SingleChildScrollView(scrollDirection: Axis.horizontal, physics: const NeverScrollableScrollPhysics(), child: SizedBox(width: expanded ? 200 : 70, child: Column(children: [const CircleAvatar(radius: 20, backgroundColor: Colors.blue, child: Icon(Icons.person, color: Colors.white)), if (expanded) ...[const SizedBox(height: 12), const Text('User', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), const SizedBox(height: 4), const Text('Dept', style: TextStyle(fontSize: 14, color: Colors.grey))]]))),
      const SizedBox(height: 20), const Divider(height: 1),
    ]);
  }

  Widget _buildSidebar() {
    return AnimatedContainer(duration: const Duration(milliseconds: 300), width: isSidebarExpanded ? 200 : 70, color: Colors.grey.shade200, child: Column(children: [_buildSidebarContent(isSidebarExpanded), IconButton(icon: const Icon(Icons.menu), onPressed: () => setState(() => isSidebarExpanded = !isSidebarExpanded)), const SizedBox(height: 20), Icon(Icons.home, color: Colors.grey.shade600)]));
  }

  Widget _buildDrawer() {
    return Drawer(width: 220, child: Container(color: Colors.grey.shade200, child: Column(children: [_buildSidebarContent(true), ListTile(leading: Icon(Icons.home, color: Colors.grey.shade700), title: const Text('首頁'), onTap: () => Navigator.of(context).pop())])));
  }

  Widget _buildHeader() {
    String title; String? subtitle;
    switch (_step) {
      case FlowStep.preview: title = '檢視照片'; break;
      case FlowStep.cropType: title = '選擇定位類型'; subtitle = '步驟 1 / 2'; break;
      case FlowStep.algorithm: title = '選擇演算法'; subtitle = '步驟 2 / 2'; break;
      case FlowStep.result: title = '處理結果'; break;
    }
    return Container(
      width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10), color: Colors.white,
      child: Row(children: [
        SizedBox(width: 110, child: _step == FlowStep.preview ? TextButton.icon(onPressed: _clearPhoto, icon: const Icon(Icons.close, size: 18, color: Colors.redAccent), label: const Text('取消重拍', style: TextStyle(color: Colors.redAccent, fontSize: 14))) : null),
        Expanded(child: Column(children: [Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), if (subtitle != null) Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.grey))])),
        const SizedBox(width: 110),
      ]),
    );
  }

  Widget _buildBottomNav() {
    String nextLabel;
    switch (_step) {
      case FlowStep.preview: nextLabel = '確認'; break;
      case FlowStep.cropType: nextLabel = '下一步'; break;
      case FlowStep.algorithm: nextLabel = '套用'; break;
      case FlowStep.result: nextLabel = '完成'; break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), decoration: BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black.withAlpha(20), blurRadius: 6, offset: const Offset(0, -2))]),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        _step == FlowStep.preview ? const SizedBox(width: 100) : OutlinedButton.icon(onPressed: _isProcessing ? null : _goBack, icon: const Icon(Icons.arrow_back_ios, size: 16), label: const Text('上一步'), style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)))),
        ElevatedButton(onPressed: _canGoNext ? _goNext : null, style: ElevatedButton.styleFrom(backgroundColor: _step == FlowStep.result ? Colors.green : Colors.blue, disabledBackgroundColor: Colors.grey.shade300, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))), child: Text(nextLabel, style: const TextStyle(color: Colors.white, fontSize: 16))),
      ]),
    );
  }

  Widget _buildCompactOption(IconData icon, String label, bool selected, VoidCallback onTap) {
    return Expanded(
      child: InkWell(
        onTap: onTap, 
        borderRadius: BorderRadius.circular(14),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6), 
          padding: const EdgeInsets.symmetric(vertical: 12), 
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14), 
            border: Border.all(color: selected ? Colors.blue : Colors.grey.shade300, width: selected ? 2 : 1)
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min, 
            children: [
              Icon(icon, color: selected ? Colors.blue : Colors.grey, size: 28), 
              const SizedBox(height: 4), 
              Text(label, style: const TextStyle(fontSize: 13))
            ]
          ),
        ),
      ),
    );
  }

  Widget _buildCropTypeStep() {
    if (_isCropping) return _buildCropper();
    return Column(children: [
      Expanded(child: _buildImageView()),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10), 
        child: Row(children: [
          _buildCompactOption(Icons.crop_square, '矩形定位', _cropType == CropType.rectangle, () => _selectCropType(CropType.rectangle)),
          _buildCompactOption(Icons.lens_outlined, '圓形定位', _cropType == CropType.circle, () => _selectCropType(CropType.circle)),
          _buildCompactOption(Icons.image_outlined, '使用全圖', _cropType == CropType.none, () => _selectCropType(CropType.none)),
        ]),
      ),
    ]);
  }

  Widget _buildAlgorithmStep() {
    return Column(children: [
      SizedBox(height: 160, child: _buildImageView()), const Divider(height: 1),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 6), 
          children: _algorithms.map((algo) {
            final selected = _selectedAlgorithm == algo['name'];
            return Card(
              elevation: selected ? 3 : 0, 
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5), 
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: selected ? Colors.blue : Colors.grey.shade300, width: selected ? 2 : 1)),
              child: Column(
                children: [
                  ListTile(
                    onTap: () => setState(() => _selectedAlgorithm = algo['name'] as String), 
                    leading: Icon(algo['icon'] as IconData, color: selected ? Colors.blue : Colors.grey, size: 28), 
                    title: Text(algo['name'] as String, style: const TextStyle(fontWeight: FontWeight.bold)), 
                    subtitle: Text(algo['desc'] as String), 
                    trailing: selected ? const Icon(Icons.check_circle, color: Colors.blue) : const Icon(Icons.radio_button_unchecked, color: Colors.grey)
                  ),
                  if (selected && algo['name'] == '量測')
                    Padding(
                      padding: const EdgeInsets.only(left: 72, right: 16, bottom: 12),
                      child: Row(
                        children: [
                          ChoiceChip(label: const Text('距離'), selected: _measureMode == '距離', onSelected: (v) => setState(() => _measureMode = '距離'), selectedColor: Colors.blue.shade100),
                          const SizedBox(width: 12),
                          ChoiceChip(label: const Text('真圓度'), selected: _measureMode == '真圓度', onSelected: (v) => setState(() => _measureMode = '真圓度'), selectedColor: Colors.blue.shade100),
                        ],
                      ),
                    )
                ],
              ),
            );
          }).toList()
        )
      ),
    ]);
  }

  // ==================== 結果頁 ====================
  Widget _buildResultStep() {
    final bool isDistanceMode = _selectedAlgorithm == '量測' && _measureMode == '距離';

    return Column(children: [
      Expanded(
        child: isDistanceMode
            ? LayoutBuilder(
                builder: (context, constraints) {
                  if (_decodedUiImage == null) return _buildImageView(data: _resultImage ?? _imageData);
                  final imageRect = _calculateImageRect(constraints.biggest, _decodedUiImage!);
                  return GestureDetector(
                    onPanStart: (details) {
                      setState(() {
                        _measureStart = _mapToImage(details.localPosition, imageRect);
                        _measureEnd = _measureStart;
                      });
                    },
                    onPanUpdate: (details) {
                      setState(() {
                        _measureEnd = _mapToImage(details.localPosition, imageRect);
                        if (_measureStart != null && _measureEnd != null) {
                          double dx = (_measureEnd!.dx - _measureStart!.dx) * _decodedUiImage!.width;
                          double dy = (_measureEnd!.dy - _measureStart!.dy) * _decodedUiImage!.height;
                          double dist = sqrt(dx * dx + dy * dy);
                          _resultText = '直線距離：${dist.toStringAsFixed(1)} px';
                        }
                      });
                    },
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _buildImageView(data: _resultImage ?? _imageData),
                        if (_measureStart != null && _measureEnd != null)
                          CustomPaint(
                            painter: MeasureLinePainter(
                              imageDrawRect: imageRect,
                              start: _measureStart!,
                              end: _measureEnd!,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              )
            : _buildImageView(data: _resultImage ?? _imageData),
      ),
      
      Container(
        width: double.infinity,
        color: Colors.white,
        padding: const EdgeInsets.all(16), 
        child: Column(
          children: [
            Text('已套用：${_selectedAlgorithm ?? ''}', style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
            if (_resultText != null) ...[
              const SizedBox(height: 8),
              Text(
                _resultText!, 
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.blue), 
                textAlign: TextAlign.center
              ),
            ]
          ],
        )
      ),
    ]);
  }

  Widget _buildContent() {
    if (_imageData == null) return const Center(child: Text('主畫面內容', style: TextStyle(fontSize: 24, color: Colors.grey)));
    Widget content;
    switch (_step) {
      case FlowStep.preview: content = _buildImageView(); break;
      case FlowStep.cropType: content = _buildCropTypeStep(); break;
      case FlowStep.algorithm: content = _buildAlgorithmStep(); break;
      case FlowStep.result: content = _buildResultStep(); break;
    }
    return Stack(children: [
      Positioned.fill(child: content),
      if (_isProcessing) Positioned.fill(child: Container(color: Colors.black38, child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 12), Text('處理中...', style: TextStyle(color: Colors.white, fontSize: 16))])))),
    ]);
  }

  Widget _buildSearchBar(bool isPhone) {
    return Padding(padding: const EdgeInsets.all(12.0), child: Row(children: [
      if (isPhone) IconButton(icon: const Icon(Icons.menu), onPressed: () => _scaffoldKey.currentState?.openDrawer()),
      Expanded(child: TextField(decoration: InputDecoration(hintText: '搜尋...', prefixIcon: const Icon(Icons.search), suffixIcon: IconButton(icon: const Icon(Icons.camera_alt, color: Colors.blue), onPressed: _takePhoto), border: OutlineInputBorder(borderRadius: BorderRadius.circular(30.0)), contentPadding: const EdgeInsets.symmetric(horizontal: 20)))),
    ]));
  }

  @override
  Widget build(BuildContext context) {
    final bool isPhone = MediaQuery.of(context).size.width < 600;
    return Scaffold(
      key: _scaffoldKey, drawer: isPhone ? _buildDrawer() : null,
      body: SafeArea(child: Row(children: [
        if (!isPhone) _buildSidebar(),
        Expanded(child: Column(children: [
          if (_imageData == null) _buildSearchBar(isPhone) else _buildHeader(),
          Expanded(child: _buildContent()),
          if (_imageData != null && !_isCropping) _buildBottomNav(),
        ])),
      ])),
    );
  }
}

// ==================== 自訂定位遮罩的畫筆 ====================
class CustomLocatePainter extends CustomPainter {
  final Rect imageDrawRect;
  final Rect? normalizedRect;
  final bool isCircle;

  CustomLocatePainter({required this.imageDrawRect, this.normalizedRect, required this.isCircle});

  @override
  void paint(Canvas canvas, Size size) {
    if (normalizedRect == null) return;
    Path path = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final realRect = Rect.fromLTRB(
      imageDrawRect.left + normalizedRect!.left * imageDrawRect.width,
      imageDrawRect.top + normalizedRect!.top * imageDrawRect.height,
      imageDrawRect.left + normalizedRect!.right * imageDrawRect.width,
      imageDrawRect.top + normalizedRect!.bottom * imageDrawRect.height,
    );
    if (isCircle) path.addOval(realRect); else path.addRect(realRect);
    
    path.fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = Colors.black.withOpacity(0.7));

    final borderPaint = Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2;
    if (isCircle) canvas.drawOval(realRect, borderPaint); else canvas.drawRect(realRect, borderPaint);

    final handlePaint = Paint()..color = Colors.blue..style = PaintingStyle.fill;
    final handleStroke = Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5;
    for (var offset in [realRect.topLeft, realRect.topRight, realRect.bottomLeft, realRect.bottomRight]) {
      canvas.drawCircle(offset, 6, handlePaint);
      canvas.drawCircle(offset, 6, handleStroke);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// ==================== 手拉測量線的專用畫筆 ====================
class MeasureLinePainter extends CustomPainter {
  final Rect imageDrawRect;
  final Offset start;
  final Offset end;

  MeasureLinePainter({required this.imageDrawRect, required this.start, required this.end});

  @override
  void paint(Canvas canvas, Size size) {
    final p1 = Offset(
      imageDrawRect.left + start.dx * imageDrawRect.width,
      imageDrawRect.top + start.dy * imageDrawRect.height,
    );
    final p2 = Offset(
      imageDrawRect.left + end.dx * imageDrawRect.width,
      imageDrawRect.top + end.dy * imageDrawRect.height,
    );

    final linePaint = Paint()
      ..color = Colors.redAccent
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(p1, p2, linePaint);

    final pointPaint = Paint()..color = Colors.blue..style = PaintingStyle.fill;
    final strokePaint = Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5;

    canvas.drawCircle(p1, 5, pointPaint);
    canvas.drawCircle(p1, 5, strokePaint);
    canvas.drawCircle(p2, 5, pointPaint);
    canvas.drawCircle(p2, 5, strokePaint);
  }

  @override
  bool shouldRepaint(covariant MeasureLinePainter oldDelegate) => true;
}