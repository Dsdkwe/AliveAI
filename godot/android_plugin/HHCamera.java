package com.hta.halfhearted;

import android.graphics.ImageFormat;
import android.graphics.Rect;
import android.graphics.YuvImage;
import android.hardware.Camera;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.SystemClock;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.UsedByGodot;

import java.io.ByteArrayOutputStream;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;

/**
 * HHCamera — Half-hearted AI 的 Android 相机插件。
 * 打开后置摄像头，把预览帧压缩为 JPEG（NV21 -> YuvImage -> JPEG），
 * 由 GDScript 侧每帧 poll() 拉取并显示为 AR 背景。
 */
public class HHCamera extends GodotPlugin {
	private final Object lock = new Object();
	private Camera camera = null;
	private HandlerThread camThread = null;
	private Handler camHandler = null;
	private final AtomicReference<byte[]> latestJpeg = new AtomicReference<>();
	private volatile int rotationDegrees = 90;
	private volatile int frameCount = 0;
	private volatile boolean wantActive = false;
	private long lastProcMs = 0;

	public HHCamera(Godot godot) {
		super(godot);
	}

	@Override
	public String getPluginName() {
		return "HHCamera";
	}

	@UsedByGodot
	public void start() {
		synchronized (lock) {
			if (camera != null) {
				return;
			}
			wantActive = true;
			startInternalLocked();
		}
	}

	private void startInternalLocked() {
		camThread = new HandlerThread("HHCamera");
		camThread.start();
		camHandler = new Handler(camThread.getLooper());
		camHandler.post(new Runnable() {
			@Override
			public void run() {
				openCamera();
			}
		});
	}

	private void openCamera() {
		try {
			int camId = -1;
			Camera.CameraInfo info = new Camera.CameraInfo();
			int n = Camera.getNumberOfCameras();
			for (int i = 0; i < n; i++) {
				Camera.getCameraInfo(i, info);
				if (info.facing == Camera.CameraInfo.CAMERA_FACING_BACK) {
					camId = i;
					rotationDegrees = info.orientation;
					break;
				}
			}
			if (camId < 0) {
				return;
			}
			final Camera c = Camera.open(camId);
			if (c == null) {
				return;
			}
			synchronized (lock) {
				if (!wantActive) {
					try {
						c.release();
					} catch (Throwable ignored) {
					}
					return;
				}
				camera = c;
			}
			Camera.Parameters params = c.getParameters();
			List<Camera.Size> sizes = params.getSupportedPreviewSizes();
			Camera.Size best = null;
			for (Camera.Size s : sizes) {
				if (s.width <= 1280) {
					if (best == null || (long) s.width * s.height > (long) best.width * best.height) {
						best = s;
					}
				}
			}
			if (best != null) {
				params.setPreviewSize(best.width, best.height);
			}
			params.setPreviewFormat(ImageFormat.NV21);
			try {
				params.setPreviewFpsRange(15000, 30000);
			} catch (Throwable ignored) {
			}
			c.setParameters(params);
			Camera.Size sz = c.getParameters().getPreviewSize();
			final int fw = sz.width;
			final int fh = sz.height;
			int bufSize = fw * fh * ImageFormat.getBitsPerPixel(ImageFormat.NV21) / 8;
			c.addCallbackBuffer(new byte[bufSize]);
			c.addCallbackBuffer(new byte[bufSize]);
			c.setPreviewCallbackWithBuffer(new Camera.PreviewCallback() {
				@Override
				public void onPreviewFrame(byte[] data, Camera cam) {
					if (data == null) {
						return;
					}
					try {
						long now = SystemClock.elapsedRealtime();
						if (now - lastProcMs >= 33) {
							lastProcMs = now;
							YuvImage yuv = new YuvImage(data, ImageFormat.NV21, fw, fh, null);
							ByteArrayOutputStream os = new ByteArrayOutputStream();
							yuv.compressToJpeg(new Rect(0, 0, fw, fh), 60, os);
							latestJpeg.set(os.toByteArray());
							frameCount++;
						}
					} catch (Throwable ignored) {
					}
					try {
						cam.addCallbackBuffer(data);
					} catch (Throwable ignored) {
					}
				}
			});
			c.startPreview();
		} catch (Throwable t) {
			synchronized (lock) {
				releaseCamera();
			}
		}
	}

	@UsedByGodot
	public byte[] poll() {
		return latestJpeg.getAndSet(null);
	}

	@UsedByGodot
	public int getRotationDegrees() {
		return rotationDegrees;
	}

	@UsedByGodot
	public int getFrameCount() {
		return frameCount;
	}

	@UsedByGodot
	public boolean isActive() {
		return camera != null;
	}

	@UsedByGodot
	public void stop() {
		synchronized (lock) {
			wantActive = false;
			releaseCamera();
		}
	}

	private void releaseCamera() {
		try {
			if (camera != null) {
				camera.setPreviewCallbackWithBuffer(null);
				camera.stopPreview();
			}
		} catch (Throwable ignored) {
		}
		try {
			if (camera != null) {
				camera.release();
			}
		} catch (Throwable ignored) {
		}
		camera = null;
		if (camThread != null) {
			try {
				camThread.quitSafely();
			} catch (Throwable ignored) {
			}
			camThread = null;
			camHandler = null;
		}
	}

	@Override
	public void onMainPause() {
		synchronized (lock) {
			releaseCamera();
		}
	}

	@Override
	public void onMainResume() {
		synchronized (lock) {
			if (wantActive && camera == null) {
				startInternalLocked();
			}
		}
	}
}