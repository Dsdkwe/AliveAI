#!/usr/bin/env python3
# CI：安装 Godot Android build 模板（从 export templates 的 android_source.zip 解压）
# 并注入 HHCamera 相机插件（Java 源码 + AndroidManifest meta-data）。
#
# 用法（仓库根目录执行）：python3 godot/android_plugin/inject.py
import os
import re
import shutil
import stat
import tempfile
import zipfile
import glob

PLUGIN_DIR = os.path.dirname(os.path.abspath(__file__))          # godot/android_plugin
PROJECT_DIR = os.path.dirname(PLUGIN_DIR)                        # godot
BUILD_DIR = os.path.join(PROJECT_DIR, "android", "build")


def find_template_zip():
    pats = [
        os.path.expanduser("~/.local/share/godot/export_templates/*/android_source.zip"),
        os.path.expanduser("~/.local/share/godot/export_templates/*/android_source*.zip"),
    ]
    for p in pats:
        hits = glob.glob(p)
        if hits:
            return hits[0]
    raise SystemExit("[inject] android_source.zip not found in export_templates")


def extract_template(zip_path, dest):
    tmp = tempfile.mkdtemp(prefix="abt_")
    with zipfile.ZipFile(zip_path) as z:
        z.extractall(tmp)
    # 寻找含 build.gradle / gradlew 的模板根
    src_root = None
    for cand in (tmp, os.path.join(tmp, "build"), os.path.join(tmp, "android", "build")):
        if os.path.exists(os.path.join(cand, "build.gradle")) or os.path.exists(os.path.join(cand, "gradlew")):
            src_root = cand
            break
    if src_root is None:
        for root, _dirs, files in os.walk(tmp):
            if "build.gradle" in files or "gradlew" in files:
                src_root = root
                break
    if src_root is None:
        raise SystemExit("[inject] template root not found in android_source.zip")
    os.makedirs(dest, exist_ok=True)
    for item in os.listdir(src_root):
        s = os.path.join(src_root, item)
        d = os.path.join(dest, item)
        if os.path.exists(d):
            if os.path.isdir(d):
                shutil.rmtree(d)
            else:
                os.remove(d)
        shutil.move(s, d)
    print("[inject] template root:", src_root)
    print("[inject] template extracted to", dest)


def main():
    zip_path = find_template_zip()
    print("[inject] using template:", zip_path)
    extract_template(zip_path, BUILD_DIR)

    gradlew = os.path.join(BUILD_DIR, "gradlew")
    if os.path.exists(gradlew):
        os.chmod(gradlew, os.stat(gradlew).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    # 1) 注入 Java 源码
    src_dir = os.path.join(BUILD_DIR, "src", "main", "java", "com", "hta", "halfhearted")
    os.makedirs(src_dir, exist_ok=True)
    shutil.copy(os.path.join(PLUGIN_DIR, "HHCamera.java"), os.path.join(src_dir, "HHCamera.java"))
    print("[inject] HHCamera.java ->", src_dir)

    # 2) 注入插件注册 meta-data
    manifest = os.path.join(BUILD_DIR, "src", "main", "AndroidManifest.xml")
    with open(manifest, "r", encoding="utf-8") as f:
        text = f.read()
    if "org.godotengine.plugin.v1.HHCamera" in text:
        print("[inject] meta-data already present")
    else:
        m = re.search(r"<application\b[^>]*>", text)
        if not m:
            raise SystemExit("[inject] <application> tag not found in AndroidManifest.xml")
        meta = '\n        <meta-data android:name="org.godotengine.plugin.v1.HHCamera" android:value="com.hta.halfhearted.HHCamera" />'
        text = text[:m.end()] + meta + text[m.end():]
        with open(manifest, "w", encoding="utf-8") as f:
            f.write(text)
        print("[inject] HHCamera meta-data injected")
    print("[inject] done")


if __name__ == "__main__":
    main()