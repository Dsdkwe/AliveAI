import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'config_page.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  List<ApiConfig> _configs = [];
  ApiConfig? _currentConfig;
  final List<Map<String, String>> _messages = [];
  final TextEditingController _textController = TextEditingController();
  bool _isLoading = false;
  final ScrollController _scrollController = ScrollController();

  // 语音
  late stt.SpeechToText _speech;
  bool _isListening = false;
  final FlutterTts _flutterTts = FlutterTts();

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    _loadConfigs();
    _initTts();
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage("zh-CN");
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);
  }

  Future<void> _loadConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    final String? data = prefs.getString('api_configs');
    if (data != null) {
      final List<dynamic> list = jsonDecode(data);
      setState(() {
        _configs = list.map((e) => ApiConfig.fromJson(e)).toList();
        if (_currentConfig == null && _configs.isNotEmpty) {
          _currentConfig = _configs.first;
        }
      });
    }
  }

  void _selectConfig() async {
    if (_configs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在配置页面添加API配置')),
      );
      return;
    }
    final selected = await showDialog<ApiConfig>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择API配置'),
        children: _configs.map((config) {
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, config),
            child: Text(config.name),
          );
        }).toList(),
      ),
    );
    if (selected != null) {
      setState(() {
        _currentConfig = selected;
        _messages.clear();
      });
    }
  }

  Future<void> _sendMessage() async {
    if (_currentConfig == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择一个API配置')),
      );
      return;
    }
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _messages.add({'role': 'user', 'content': text});
      _isLoading = true;
    });
    _textController.clear();
    _scrollToBottom();

    try {
      final response = await http.post(
        Uri.parse(_currentConfig!.baseUrl),
        headers: {
          'Authorization': 'Bearer ${_currentConfig!.apiKey}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': _currentConfig!.model,
          'messages': _messages.map((m) => {'role': m['role'], 'content': m['content']}).toList(),
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final reply = data['choices']?[0]?['message']?['content'] ?? '无回复内容';
        setState(() {
          _messages.add({'role': 'assistant', 'content': reply});
        });
        _speak(reply);
      } else {
        final body = jsonDecode(response.body);
        final errorMsg = body['error']?['message'] ?? '未知错误';
        setState(() {
          _messages.add({'role': 'assistant', 'content': '请求失败: $errorMsg'});
        });
      }
    } catch (e) {
      setState(() {
        _messages.add({'role': 'assistant', 'content': '网络错误: $e'});
      });
    } finally {
      setState(() => _isLoading = false);
      _scrollToBottom();
    }
  }

  Future<void> _startListening() async {
    bool available = await _speech.initialize(
      onStatus: (val) => print('onStatus: $val'),
      onError: (val) => print('onError: $val'),
    );
    if (available) {
      setState(() => _isListening = true);
      _speech.listen(
        onResult: (val) {
          setState(() {
            _textController.text = val.recognizedWords;
          });
          if (val.finalResult) {
            setState(() => _isListening = false);
            _sendMessage();
          }
        },
        localeId: "zh_CN",
      );
    }
  }

  void _stopListening() {
    _speech.stop();
    setState(() => _isListening = false);
  }

  Future<void> _speak(String text) async {
    await _flutterTts.speak(text);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _speech.cancel();
    _flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _currentConfig != null
            ? Text('对话 - ${_currentConfig!.name}')
            : const Text('对话'),
        actions: [
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            tooltip: '切换配置',
            onPressed: _selectConfig,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(child: Text('开始和AI对话吧'))
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final msg = _messages[index];
                      final isUser = msg['role'] == 'user';
                      return Align(
                        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isUser ? Colors.deepPurple.shade100 : Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(msg['content'] ?? ''),
                        ),
                      );
                    },
                  ),
          ),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(8.0),
              child: Text('AI 正在思考...', style: TextStyle(color: Colors.grey)),
            ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    decoration: const InputDecoration(
                      hintText: '输入消息...',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                IconButton(
                  icon: Icon(_isListening ? Icons.mic : Icons.mic_none),
                  color: _isListening ? Colors.red : null,
                  onPressed: _isListening ? _stopListening : _startListening,
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _sendMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
