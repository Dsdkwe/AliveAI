import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

class ModelPage extends StatefulWidget {
  const ModelPage({super.key});
  @override
  State<ModelPage> createState() => _ModelPageState();
}

class _ModelPageState extends State<ModelPage> {
  final String modelDir = '/storage/emulated/0/HTA/Models';
  List<FileSystemEntity> _models = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _initDir();
  }

  Future<void> _initDir() async {
    // 请求存储权限（Android 13+需要细分权限，先确保老方式）
    if (await Permission.manageExternalStorage.request().isGranted ||
        await Permission.storage.request().isGranted) {
      final dir = Directory(modelDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await _refreshList();
    } else {
      // 权限被拒，引导去设置
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('需要存储权限才能管理模型文件')),
        );
      }
    }
  }

  Future<void> _refreshList() async {
    setState(() => _loading = true);
    final dir = Directory(modelDir);
    if (await dir.exists()) {
      final files = dir.listSync().where((f) => f is File).toList();
      setState(() {
        _models = files;
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _pickAndCopyModel() async {
    // 打开文件选择器，支持常见模型格式
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['moc3', 'model3.json', 'glb', 'gltf', 'vrm', 'fbx', 'obj', 'dat', 'bin', 'zip'],
    );
    if (result == null || result.files.isEmpty) return;

    final sourcePath = result.files.single.path!;
    final fileName = p.basename(sourcePath);
    final destPath = p.join(modelDir, fileName);

    try {
      await File(sourcePath).copy(destPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('模型 "$fileName" 已导入')),
        );
      }
      await _refreshList();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _models.isEmpty
              ? Center(
                  child: IconButton(
                    icon: const Icon(Icons.add_circle_outline, size: 64),
                    onPressed: _pickAndCopyModel,
                  ),
                )
              : ListView.builder(
                  itemCount: _models.length,
                  itemBuilder: (context, index) {
                    final file = _models[index];
                    return ListTile(
                      leading: const Icon(Icons.view_in_ar),
                      title: Text(p.basename(file.path)),
                      subtitle: Text(file.path),
                    );
                  },
                ),
      floatingActionButton: _models.isNotEmpty
          ? FloatingActionButton(
              onPressed: _pickAndCopyModel,
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}
