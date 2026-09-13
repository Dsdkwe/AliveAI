package com.hta.halfhearted;

import android.graphics.ImageFormat;
import android.graphics.Rect;
import android.graphics.YuvImage;
import android.hardware.Camera;
import android.os.Handler;
import android.os.HandlerThread;
import android.graphics.SurfaceTexture;
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
	private volatile int cbCount = 0;
	private volatile int jpgCount = 0;
	private volatile String dbg = "init";
	private SurfaceTexture dummySt = null;

	public HHCamera(Godot godot) {
		super(godot);
	}

	@Override
	public String getPluginName() {
		return "HHCamera";
	}

	@UsedByGodot
	public void start() {
		dbg = "init";
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
			dbg = dbg + "|no_cam n=" + n;
			return;
		}
		dbg = dbg + "|opening#" + camId;
		final Camera c = Camera.open(camId);
		if (c == null) {
			dbg = dbg + "|open_null";
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
		try {
			List<Integer> fmts = params.getSupportedPreviewFormats();
			if (fmts != null && fmts.contains(ImageFormat.NV21)) {
				params.setPreviewFormat(ImageFormat.NV21);
			} else {
				dbg = dbg + "|fmt_no_nv21";
			}
		} catch (Throwable t) {
			dbg = dbg + "|fmtE:" + t.getClass().getSimpleName();
		}
		String note = "";
		boolean applied = false;
		try {
			c.setParameters(params);
			applied = true;
			note = "ok1";
		} catch (Throwable t1) {
			note = "1E:" + t1.getMessage();
		}
		if (!applied) {
			try {
				Camera.Parameters p2 = c.getParameters();
				if (best != null) {
					p2.setPreviewSize(best.width, best.height);
				}
				c.setParameters(p2);
				applied = true;
				note = note + "|ok2";
			} catch (Throwable t2) {
				note = note + "|2E:" + t2.getMessage();
			}
		}
		if (!applied) {
			try {
				Camera.Parameters p3 = c.getParameters();
				Camera.Size small = null;
				for (Camera.Size s3 : p3.getSupportedPreviewSizes()) {
					if (s3.width <= 640) {
						if (small == null || (long) s3.width * s3.height > (long) small.width * small.height) {
							small = s3;
						}
					}
				}
				if (small != null) {
					p3.setPreviewSize(small.width, small.height);
				}
				c.setParameters(p3);
				applied = true;
				note = note + "|ok3";
			} catch (Throwable t3) {
				note = note + "|3E:" + t3.getMessage();
			}
		}
		dbg = dbg + "|setp[" + note + "]";
		Camera.Parameters pActual = c.getParameters();
		Camera.Size sz = pActual.getPreviewSize();
		final int fw = sz.width;
		final int fh = sz.height;
		int actualFmt = pActual.getPreviewFormat();
		final int yuvFmt = (actualFmt == ImageFormat.NV21 || actualFmt == ImageFormat.YUY2) ? actualFmt : ImageFormat.NV21;
		int bpp = ImageFormat.getBitsPerPixel(yuvFmt);
		if (bpp <= 0) {
			bpp = 12;
		}
		final int bufSize = fw * fh * bpp / 8;
		dbg = dbg + "|sz " + fw + "x" + fh + " f=" + actualFmt + " bpp=" + bpp;
		final Camera.PreviewCallback frameCb = new Camera.PreviewCallback() {
			@Override
			public void onPreviewFrame(byte[] data, Camera cam) {
				if (data == null) {
					return;
				}
				try {
					cbCount++;
					if (cbCount == 1) {
						dbg = dbg + "|cb1";
					}
					long now = SystemClock.elapsedRealtime();
					if (now - lastProcMs >= 33) {
						lastProcMs = now;
						YuvImage yuv = new YuvImage(data, yuvFmt, fw, fh, null);
						ByteArrayOutputStream os = new ByteArrayOutputStream();
						yuv.compressToJpeg(new Rect(0, 0, fw, fh), 60, os);
						latestJpeg.set(os.toByteArray());
						jpgCount++;
						frameCount++;
						if (jpgCount == 1) {
							dbg = dbg + "|jpg1";
						}
					}
				} catch (Throwable t) {
					dbg = dbg + "|jpgE:" + t.getClass().getSimpleName();
				}
				try {
					cam.addCallbackBuffer(data);
				} catch (Throwable ignored) {
				}
			}
		};
		c.setPreviewCallbackWithBuffer(frameCb);
		c.addCallbackBuffer(new byte[bufSize]);
		c.addCallbackBuffer(new byte[bufSize]);
		c.startPreview();
		try {
			c.addCallbackBuffer(new byte[bufSize]);
		} catch (Throwable ignored) {
		}
		dbg = dbg + "|started";
		camHandler.postDelayed(new Runnable() {
			@Override
			public void run() {
				if (camera == c && cbCount == 0 && wantActive) {
					dbg = dbg + "|legacy_fb";
					try {
						c.setPreviewCallbackWithBuffer(null);
						c.setPreviewCallback(frameCb);
					} catch (Throwable t) {
						dbg = dbg + "|legE:" + t.getClass().getSimpleName();
					}
				}
			}
		}, 4500);
		camHandler.postDelayed(new Runnable() {
			@Override
			public void run() {
				if (camera == c && cbCount == 0 && wantActive) {
					dbg = dbg + "|sf_fb";
					try {
						c.stopPreview();
						dummySt = new SurfaceTexture(0);
						dummySt.setDefaultBufferSize(fw, fh);
						c.setPreviewTexture(dummySt);
						c.setPreviewCallbackWithBuffer(frameCb);
						c.addCallbackBuffer(new byte[bufSize]);
						c.addCallbackBuffer(new byte[bufSize]);
						c.startPreview();
					} catch (Throwable t) {
						dbg = dbg + "|sfE:" + t.getClass().getSimpleName();
					}
				}
			}
		}, 7500);
	} catch (Throwable t) {
		dbg = dbg + "|E:" + t.getClass().getSimpleName() + ":" + t.getMessage();
		synchronized (lock) {
			releaseCamera();
		}
	}
}

	@UsedByGodot
	public String getDebugInfo() {
		return dbg + " cb=" + cbCount + " jpg=" + jpgCount + " act=" + (camera != null);
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