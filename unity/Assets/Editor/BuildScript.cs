#if UNITY_EDITOR
using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

public static class BuildScript
{
    public static void PerformBuild()
    {
        PlayerSettings.companyName = "HTA";
        PlayerSettings.productName = "Half-hearted AI";
        PlayerSettings.SetApplicationIdentifier(BuildTargetGroup.Android, "com.hta.halfhearted");
        PlayerSettings.SetScriptingBackend(BuildTargetGroup.Android, ScriptingImplementation.IL2CPP);
        PlayerSettings.Android.targetArchitectures = AndroidArchitecture.ARM64;
        PlayerSettings.Android.minSdkVersion = AndroidSdkVersions.AndroidApiLevel24;
        PlayerSettings.Android.targetSdkVersion = AndroidSdkVersions.AndroidApiLevelAuto;
        PlayerSettings.Android.bundleVersionCode = 1;
        PlayerSettings.bundleVersion = "1.0.0";

        var scene = EditorSceneManager.NewScene(NewSceneSetup.DefaultGameObjects, NewSceneMode.Single);
        string dir = "Assets/Scenes";
        if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
        string path = dir + "/Main.unity";
        EditorSceneManager.SaveScene(scene, path);
        EditorBuildSettings.scenes = new[] { new EditorBuildSettingsScene(path, true) };

        if (!Directory.Exists("build")) Directory.CreateDirectory("build");
        var options = new BuildPlayerOptions
        {
            scenes = new[] { path },
            locationPathName = "build/HTA.apk",
            target = BuildTarget.Android,
            options = BuildOptions.None
        };
        var report = BuildPipeline.BuildPlayer(options);
        if (report.summary.result != UnityEditor.Build.Reporting.BuildResult.Succeeded)
            throw new System.Exception("构建失败: " + report.summary.result);
        Debug.Log("构建成功: " + options.locationPathName);
    }
}
#endif
