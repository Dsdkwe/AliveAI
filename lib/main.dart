import 'package:flutter/material.dart';

void main() {
  runApp(const HalfHeartedAIApp());
}

class HalfHeartedAIApp extends StatelessWidget {
  const HalfHeartedAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Half-hearted AI',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MainPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ============================================
// 公告内容（你自己改这里的文字就行）
// ============================================
const String announcementTitle = '公告';
const String announcementContent = '''
欢迎使用 Half-hearted AI！

这是一条可以自己修改的公告内容。
你可以在代码里找到 announcementContent 变量，把它改成任何你想说的话。
''';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  int _currentIndex = 0;

  final List<Widget> _pages = const [
    // 模型
    Center(child: Text('模型页面', style: TextStyle(fontSize: 18))),
    // 配置
    Center(child: Text('配置页面', style: TextStyle(fontSize: 18))),
    // 对话
    Center(child: Text('对话页面', style: TextStyle(fontSize: 18))),
    // 插件
    Center(child: Text('插件页面', style: TextStyle(fontSize: 18))),
  ];

  @override
  void initState() {
    super.initState();
    // 刚进去时弹出公告悬浮窗
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showAnnouncement();
    });
  }

  void _showAnnouncement() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(announcementTitle),
        content: const SingleChildScrollView(
          child: Text(announcementContent),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // ===== 顶部栏 =====
      appBar: AppBar(
        title: const Text('Half-hearted AI'),
        leading: IconButton(
          icon: const Icon(Icons.settings),
          tooltip: '设置',
          onPressed: () {
            // TODO: 设置页面
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.menu),
            tooltip: '多功能菜单',
            onPressed: () {
              // TODO: 多功能菜单
            },
          ),
        ],
      ),
      // ===== 中间留白区域（根据底部按钮切换） =====
      body: _pages[_currentIndex],
      // ===== 底部四个功能键 =====
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.model_training),
            label: '模型',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.tune),
            label: '配置',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.chat_bubble_outline),
            label: '对话',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.extension),
            label: '插件',
          ),
        ],
      ),
    );
  }
}
