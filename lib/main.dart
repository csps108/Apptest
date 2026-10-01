import 'package:flutter/material.dart';

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

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  // 控制側邊欄是否展開的變數
  bool isSidebarExpanded = true;

  // 顯示尚未開放功能的對話框
  void _showNotAvailableDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('提示'),
          content: const Text('尚未有這功能'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // 關閉對話框
              },
              child: const Text('確定'),
            ),
          ],
        );
      },
    );
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
                const SizedBox(height: 40), // 頂部留白
                
                // --- 使用者資訊區塊 ---
                // 使用 SingleChildScrollView 防止縮放動畫時文字溢出報錯
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const NeverScrollableScrollPhysics(), // 禁用手動滑動
                  child: SizedBox(
                    width: isSidebarExpanded ? 200 : 70, // 鎖定與外層相同寬度
                    child: Column(
                      children: [
                        // 使用者頭像 (無論縮放都顯示)
                        const CircleAvatar(
                          radius: 20,
                          backgroundColor: Colors.blue,
                          child: Icon(Icons.person, color: Colors.white),
                        ),
                        // 只有在展開時，才顯示名稱與部門文字
                        if (isSidebarExpanded) ...[
                          const SizedBox(height: 12),
                          const Text(
                            'User',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Dept',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                
                const SizedBox(height: 20),
                const Divider(height: 1), // 分隔線
                const SizedBox(height: 10),

                // --- 漢堡選單按鈕 ---
                IconButton(
                  icon: const Icon(Icons.menu),
                  onPressed: () {
                    setState(() {
                      isSidebarExpanded = !isSidebarExpanded;
                    });
                  },
                ),
                const SizedBox(height: 20),
                
                // 預設的 Home 圖示 (未來可擴充為清單)
                Icon(Icons.home, color: Colors.grey.shade600),
              ],
            ),
          ),

          // ==================== 中間主內容區塊 ====================
          Expanded(
            child: Column(
              children: [
                // --- 頂部搜尋欄 ---
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: '搜尋...',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.camera_alt, color: Colors.blue),
                        onPressed: _showNotAvailableDialog, // 點擊觸發提示視窗
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(30.0),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    ),
                  ),
                ),

                // --- 下方主要內容區 ---
                const Expanded(
                  child: Center(
                    child: Text(
                      '主畫面內容',
                      style: TextStyle(fontSize: 24, color: Colors.grey),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}