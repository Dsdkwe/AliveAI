import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;

class ApiConfig {
  final String id;
  String name;
  String baseUrl;
  String apiKey;
  String model;

  ApiConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.apiKey = '',
    this.model = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
      };

  factory ApiConfig.fromJson(Map<String, dynamic> json) => ApiConfig(
        id: json['id'],
        name: json['name'],
        baseUrl: json['baseUrl'],
        apiKey: json['apiKey'] ?? '',
        model: json['model'] ?? '',
      );
}

const List<Map<String, String>> presets = [
  {
    'name': '硅基流动 (SiliconFlow)',
    'baseUrl': 'https://api.siliconflow.cn/v1/chat/completions',
  },
  {
    'name': 'OpenAI',
    'baseUrl': 'https://api.openai.com/v1/chat/completions',
  },
  {
    'name': 'DeepSeek',
    'baseUrl': 'https://api.deepseek.com/v1/chat/completions',
  },
  {
    'name': 'Groq',
    'baseUrl': 'https://api.groq.com/openai/v1/chat/completions',
  },
  {
    'name': 'Together AI',
    'baseUrl': 'https://api.together.xyz/v1/chat/completions',
  },
];

class ConfigPage extends StatefulWidget {
  const ConfigPage({super.key});
  @override
  State<ConfigPage> createState() => _ConfigPageState();
}

class _ConfigPageState extends State<ConfigPage> {
  List<ApiConfig> _configs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadConfigs();
  }

  Future<void> _loadConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    final String? data = prefs.getString('api_configs');
    if (data != null) {
      final List<dynamic> list = jsonDecode(data);
      setState(() {
        _configs = list.map((e) => ApiConfig.fromJson(e)).toList();
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _saveConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    final data = jsonEncode(_configs.map((e) => e.toJson()).toList());
    await prefs.setString('api_configs', data);
  }

  Future<void> _addConfig() async {
    await showDialog(
      context: context,
      builder: (ctx) => _ApiFormDialog(
        onSave: (config) {
          setState(() {
            _configs.add(config);
          });
          _saveConfigs();
        },
        presets: presets,
      ),
    );
  }

  Future<void> _deleteConfig(String id) async {
    setState(() {
      _configs.removeWhere((c) => c.id == id);
    });
    await _saveConfigs();
  }

  Future<void> _testConnection(ApiConfig config) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在测试连接...'), duration: Duration(seconds: 1)),
    );

    try {
      final response = await http.post(
        Uri.parse(config.baseUrl),
        headers: {
          'Authorization': 'Bearer ${config.apiKey}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': config.model,
          'messages': [
            {'role': 'user', 'content': 'Hi'}
          ],
          'max_tokens': 5,
        }),
      );

      if (response.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('连接成功！'), backgroundColor: Colors.green),
        );
      } else {
        final body = jsonDecode(response.body);
        final errorMsg = body['error']?['message'] ?? '未知错误';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('连接失败: $errorMsg (${response.statusCode})'), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('连接失败: $e'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _configs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline, size: 64),
                        onPressed: _addConfig,
                      ),
                      const SizedBox(height: 8),
                      const Text('添加AI配置', style: TextStyle(fontSize: 16)),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _configs.length,
                  itemBuilder: (context, index) {
                    final config = _configs[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: ListTile(
                        title: Text(config.name),
                        subtitle: Text(
                            '模型: ${config.model}\n密钥: ${config.apiKey.isEmpty ? "未填写" : "●●●${config.apiKey.substring(config.apiKey.length - 4)}"}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.wifi_find, color: Colors.blue),
                              tooltip: '测试连接',
                              onPressed: () => _testConnection(config),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () => _deleteConfig(config.id),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
      floatingActionButton: _configs.isNotEmpty
          ? FloatingActionButton(
              onPressed: _addConfig,
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}

class _ApiFormDialog extends StatefulWidget {
  final Function(ApiConfig) onSave;
  final List<Map<String, String>> presets;

  const _ApiFormDialog({required this.onSave, required this.presets});

  @override
  State<_ApiFormDialog> createState() => _ApiFormDialogState();
}

class _ApiFormDialogState extends State<_ApiFormDialog> {
  final _formKey = GlobalKey<FormState>();
  String? _selectedPreset;
  final _baseUrlController = TextEditingController();
  final _nameController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController();

  @override
  void dispose() {
    _baseUrlController.dispose();
    _nameController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  void _onPresetChanged(String? value) {
    if (value == null) return;
    final preset = widget.presets.firstWhere((p) => p['name'] == value);
    _baseUrlController.text = preset['baseUrl']!;
    _nameController.text = preset['name']!;
  }

  void _save() {
    if (_formKey.currentState!.validate()) {
      final config = ApiConfig(
        id: const Uuid().v4(),
        name: _nameController.text.trim(),
        baseUrl: _baseUrlController.text.trim(),
        apiKey: _apiKeyController.text.trim(),
        model: _modelController.text.trim(),
      );
      widget.onSave(config);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加AI配置'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: '选择预置API'),
                value: _selectedPreset,
                items: widget.presets.map((preset) {
                  return DropdownMenuItem<String>(
                    value: preset['name'],
                    child: Text(preset['name']!),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedPreset = value;
                    _onPresetChanged(value);
                  });
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: '配置名称'),
                validator: (v) => v == null || v.trim().isEmpty ? '请输入名称' : null,
              ),
              TextFormField(
                controller: _baseUrlController,
                decoration: const InputDecoration(labelText: 'API地址'),
                validator: (v) => v == null || v.trim().isEmpty ? '请输入API地址' : null,
              ),
              TextFormField(
                controller: _apiKeyController,
                decoration: const InputDecoration(labelText: 'API密钥'),
                validator: (v) => v == null || v.trim().isEmpty ? '请输入密钥' : null,
              ),
              TextFormField(
                controller: _modelController,
                decoration: const InputDecoration(labelText: '模型名称'),
                validator: (v) => v == null || v.trim().isEmpty ? '请输入模型名称' : null,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
