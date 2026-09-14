package com.hta.halfhearted;

import android.graphics.ImageFormat;
import android.graphics.Rect;
import android.graphics.YuvImage;
import android.app.Activity;
import android.view.SurfaceView;
import android.view.TextureView;
import android.view.SurfaceHolder;
import android.view.View;
import android.view.ViewGroup;
import android.opengl.GLSurfaceView;
import android.graphics.PixelFormat;
import android.hardware.Camera;
import android.os.Handler;
import android.os.HandlerThread;
import android.graphics.SurfaceTexture;
import android.os.SystemClock;
import android.util.Log;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import java.util.Locale;
import android.opengl.EGL14;

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
	private volatile int sensorOrientation = 90;
	private volatile boolean highQuality = true;
	private volatile boolean externalMode = false;
	private volatile int externalTexId = 0;
	private volatile int extReqW = 1920;
	private volatile int extReqH = 1080;
	private volatile SurfaceTexture extSt = null;
	private volatile boolean extPump = false;
	private volatile int lastPreviewWidth = 0;
	private volatile int lastPreviewHeight = 0;
	private HandlerThread pumpThread = null;
	private Handler pumpHandler = null;
	private final Runnable extUpdateTask = new Runnable() {
		@Override
		public void run() {
			SurfaceTexture st = extSt;
			if (st == null) {
				return;
			}
			try {
					st.updateTexImage();
					extUp++;
				} catch (Throwable t) {
					if (extErr.length() == 0) {
						extErr = t.getClass().getSimpleName() + ":" + t.getMessage();
						Log.e("HHCamera", "updateTexImage fail", t);
					}
				}
		}
	};
	private volatile int frameCount = 0;
	private volatile boolean wantActive = false;
	private long lastProcMs = 0;
	private volatile int cbCount = 0;
	private volatile int jpgCount = 0;
	private volatile int extInFrames = 0;
	private volatile int extUp = 0;
	private volatile String extErr = "";
	private TextToSpeech tts = null;
	private volatile boolean ttsReady = false;
	private volatile boolean ttsSpeaking = false;
	private volatile String ttsPending = null;
	private volatile int ttsGen = 0;
	private volatile long extImage = 0;
	private volatile long extImgCount = 0;
	private long extImgPrev1 = 0;
	private long extImgPrev2 = 0;
	private volatile String extV2Err = "";
	private volatile int openTries = 0;
	private volatile String dbg = "init";
	private SurfaceTexture dummySt = null;
	private volatile SurfaceView nativeView = null;
	private volatile Camera nativeCam = null;
	private HandlerThread nativeThread = null;
	private Handler nativeHandler = null;
	private volatile boolean nativeMode = false;
	private volatile int nativeRetries = 0;
	private volatile SurfaceView layerAppliedView = null;
	private volatile boolean cam2Probed = false;
	private volatile TextureView nativeTexView = null;
	private volatile android.hardware.camera2.CameraDevice cam2Device = null;
	private volatile android.hardware.camera2.CameraCaptureSession cam2Session = null;
	private volatile android.view.Surface cam2Surface = null;
	private volatile boolean cam2Failed = false;
	private volatile boolean cam2FallbackDone = false;
	private volatile int cam2BufW = 0;
	private volatile int cam2BufH = 0;
	private volatile int debugRotOffset = 0;
	private volatile float extraScaleX = 1.0f;
	private volatile float extraScaleY = 0.25f;
	private final java.util.concurrent.atomic.AtomicInteger frmCount = new java.util.concurrent.atomic.AtomicInteger(0);
	private volatile long frmWindowStart = 0;

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
		externalMode = false;
		extInFrames = 0;
		openTries = 0;
		cbCount = 0;
		jpgCount = 0;
		frameCount = 0;
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
		camHandler.postDelayed(new Runnable() {
			@Override
			public void run() {
				openCamera();
			}
		}, 600);
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
				sensorOrientation = info.orientation;
				break;
			}
		}
		if (camId < 0) {
			dbg = dbg + "|no_cam n=" + n;
			retryOpen();
			return;
		}
		dbg = dbg + "|opening#" + camId;
		Log.i("HHCamera", "opening cam#" + camId);
		int dispRot = 0;
		try {
			Activity act = getActivity();
			if (act != null) {
				dispRot = act.getWindowManager().getDefaultDisplay().getRotation() * 90;
			}
		} catch (Throwable ignored) {
		}
		rotationDegrees = (sensorOrientation - dispRot + 360) % 360;
		dbg = dbg + "|rot=" + rotationDegrees;
		final Camera c = Camera.open(camId);
		if (c == null) {
			dbg = dbg + "|open_null";
			retryOpen();
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
			openTries = 0;
		}
		Camera.Parameters params = c.getParameters();
		List<Camera.Size> sizes = params.getSupportedPreviewSizes();
		int maxW = externalMode ? extReqW : (highQuality ? 3840 : 1280);
		Camera.Size best = null;
		double scrAsp = 2.222;
		try {
			Activity actA = getActivity();
			if (actA != null) {
				android.view.Display dsp = actA.getWindowManager().getDefaultDisplay();
				android.graphics.Point p = new android.graphics.Point();
				dsp.getRealSize(p);
				int sm = Math.max(p.x, p.y);
				int sn = Math.min(p.x, p.y);
				android.view.Display.Mode md = dsp.getMode();
				if (md != null) {
					int mm = Math.max(md.getPhysicalWidth(), md.getPhysicalHeight());
					int mn = Math.min(md.getPhysicalWidth(), md.getPhysicalHeight());
					if (mm > 0 && mn > 0 && (double) mm / mn > 1.4) {
						sm = mm;
						sn = mn;
					}
				}
				if (sn > 0) {
					scrAsp = (double) sm / sn;
				}
			}
		} catch (Throwable ignored) {
		}
		double bestScore = -1.0;
		for (Camera.Size s : sizes) {
			if (s.width > maxW) {
				continue;
			}
			double diff = Math.abs(((double) s.width / s.height) - scrAsp);
			long area = (long) s.width * s.height;
			double score = area / (1.0 + 8.0 * diff);
			if (score > bestScore) {
				bestScore = score;
				best = s;
			}
		}
		if (best != null) {
			params.setPreviewSize(best.width, best.height);
		}
		{
			StringBuilder sb = new StringBuilder();
			for (Camera.Size s : sizes) {
				sb.append(s.width).append("x").append(s.height).append(",");
			}
			Log.i("HHCamera", "sizes=" + sb.toString() + " chosen=" + (best != null ? (best.width + "x" + best.height) : "none") + " maxW=" + maxW + " scrAsp=" + scrAsp);
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
		{
			try {
				List<int[]> rng2 = params.getSupportedPreviewFpsRange();
				int[] bestR = null;
				if (rng2 != null) {
					for (int[] r : rng2) {
						if (r[1] <= 60000) {
							if (bestR == null || r[1] > bestR[1] || (r[1] == bestR[1] && r[0] > bestR[0])) {
								bestR = r;
							}
						}
					}
				}
				if (bestR != null) {
					params.setPreviewFpsRange(bestR[0], bestR[1]);
					Log.i("HHCamera", "fpsRange=" + bestR[0] + "-" + bestR[1]);
				}
			} catch (Throwable t) {
				dbg = dbg + "|fps2E:" + t.getClass().getSimpleName();
			}
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
		Log.i("HHCamera", "open ok rot=" + rotationDegrees + " " + note);
		if (externalMode) {
			try {
				Camera.Parameters pe = c.getParameters();
				Camera.Size se = pe.getPreviewSize();
				lastPreviewWidth = se.width;
				lastPreviewHeight = se.height;
				extSt = new SurfaceTexture(0);
				extSt.setDefaultBufferSize(se.width, se.height);
				extSt.setOnFrameAvailableListener(new SurfaceTexture.OnFrameAvailableListener() {
					@Override
					public void onFrameAvailable(SurfaceTexture st) {
						extInFrames++;
					if (extInFrames == 1) {
						Log.i("HHCamera", "extV2 cb1");
					}
					grabExtFrame(st);
					}
				});
				try {
					c.stopPreview();
				} catch (Throwable t) {
				}
				c.setPreviewTexture(extSt);
				c.startPreview();
				dbg = dbg + "|ext " + se.width + "x" + se.height;
				Log.i("HHCamera", "ext attach " + se.width + "x" + se.height);
				/*v2-noop*/
			} catch (Throwable t) {
				dbg = dbg + "|extE:" + t.getClass().getSimpleName() + ":" + t.getMessage();
				synchronized (lock) {
					releaseCamera();
				}
			}
			return;
		}
		Camera.Parameters pActual = c.getParameters();
		Camera.Size sz = pActual.getPreviewSize();
		final int fw = sz.width;
		final int fh = sz.height;
		lastPreviewWidth = fw;
		lastPreviewHeight = fh;
		int actualFmt = pActual.getPreviewFormat();
		final int yuvFmt = (actualFmt == ImageFormat.NV21 || actualFmt == ImageFormat.YUY2) ? actualFmt : ImageFormat.NV21;
		int bpp = ImageFormat.getBitsPerPixel(yuvFmt);
		if (bpp <= 0) {
			bpp = 12;
		}
		final int bufSize = fw * fh * bpp / 8;
		dbg = dbg + "|sz " + fw + "x" + fh + " f=" + actualFmt + " bpp=" + bpp;
		Log.i("HHCamera", "sz=" + fw + "x" + fh + " f=" + actualFmt);
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
						Log.i("HHCamera", "first callback");
					}
					long now = SystemClock.elapsedRealtime();
					if (now - lastProcMs >= (highQuality ? 33 : 16)) {
						lastProcMs = now;
						if (latestJpeg.get() == null) {
							YuvImage yuv = new YuvImage(data, yuvFmt, fw, fh, null);
							ByteArrayOutputStream os = new ByteArrayOutputStream();
							yuv.compressToJpeg(new Rect(0, 0, fw, fh), highQuality ? 80 : 62, os);
							latestJpeg.set(os.toByteArray());
							jpgCount++;
						}
						frameCount++;
						if (frameCount % 120 == 0) {
							try {
								Activity act = getActivity();
								if (act != null) {
									int dr = act.getWindowManager().getDefaultDisplay().getRotation() * 90;
									rotationDegrees = (sensorOrientation - dr + 360) % 360;
								}
							} catch (Throwable ignored) {
							}
						}
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
		try {
			dummySt = new SurfaceTexture(0);
			dummySt.setDefaultBufferSize(fw, fh);
			c.setPreviewTexture(dummySt);
			dbg = dbg + "|dummy0";
		} catch (Throwable t) {
			dbg = dbg + "|dummyE";
		}
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
		Log.e("HHCamera", "openCamera exception", t);
		synchronized (lock) {
			releaseCamera();
		}
	}
}

	@UsedByGodot
	public boolean startExternal(int texId, int reqW, int reqH) {
		if (texId == 0) {
			return false;
		}
		synchronized (lock) {
			externalMode = true;
			externalTexId = texId;
			extInFrames = 0;
			if (reqW > 0) {
				extReqW = reqW;
			}
			if (reqH > 0) {
				extReqH = reqH;
			}
			wantActive = true;
			if (camera == null) {
				startInternalLocked();
			}
		}
		return true;
	}

	@UsedByGodot
	public void setHighQuality(boolean hq) {
		highQuality = hq;
	}

	@UsedByGodot
	public String getDebugInfo() {
		return dbg + " cb=" + cbCount + " jpg=" + jpgCount + " extIn=" + extInFrames + " extUp=" + extUp + " extE=" + extErr + " act=" + (camera != null);
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
	public int getExtInFrames() {
		return extInFrames;
	}

		// ===== 直通v2：硬件缓冲 → EGLImage → Godot外部纹理（反射版）=====
	private static java.lang.reflect.Method mGetHb = null;
	private static boolean mGetHbTried = false;
	private static java.lang.reflect.Method mCreateImg = null;
	private static boolean mCreateImgTried = false;
	private static java.lang.reflect.Method mDestroyImg = null;
	private static boolean mDestroyImgTried = false;
	private static java.lang.reflect.Method mHbClose = null;

	private Object hbOf(SurfaceTexture st) {
		try {
			if (!mGetHbTried) {
				mGetHbTried = true;
				mGetHb = SurfaceTexture.class.getMethod("getHardwareBuffer");
				Log.i("HHCamera", "extV2 getHardwareBuffer found");
			}
			if (mGetHb == null) {
				return null;
			}
			return mGetHb.invoke(st);
		} catch (Throwable t) {
			extV2Err = "getHB:" + t;
			Log.w("HHCamera", "extV2 " + extV2Err);
			return null;
		}
	}

	private long imgFromHb(Object hb) {
		try {
			if (!mCreateImgTried) {
				mCreateImgTried = true;
				Class<?> cExt = Class.forName("android.opengl.EGLExt");
				Class<?> cDpy = Class.forName("android.opengl.EGLDisplay");
				Class<?> cHb = Class.forName("android.hardware.HardwareBuffer");
				mCreateImg = cExt.getMethod("eglCreateImageFromHardwareBuffer", cDpy, cHb);
				Log.i("HHCamera", "extV2 eglCreateImageFromHardwareBuffer found");
			}
			if (mCreateImg == null) {
				return 0;
			}
			Object r = mCreateImg.invoke(null, EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY), hb);
			return r == null ? 0 : ((Long) r).longValue();
		} catch (Throwable t) {
			extV2Err = "mkImg:" + t;
			Log.w("HHCamera", "extV2 " + extV2Err);
			return 0;
		}
	}

	private void imgDestroy(long img) {
		if (img == 0) {
			return;
		}
		try {
			if (!mDestroyImgTried) {
				mDestroyImgTried = true;
				Class<?> cExt = Class.forName("android.opengl.EGLExt");
				Class<?> cDpy = Class.forName("android.opengl.EGLDisplay");
				mDestroyImg = cExt.getMethod("eglDestroyImageKHR", cDpy, long.class);
			}
			if (mDestroyImg == null) {
				return;
			}
			mDestroyImg.invoke(null, EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY), img);
		} catch (Throwable t) {
		}
	}

	private void hbClose(Object hb) {
		try {
			if (mHbClose == null) {
				mHbClose = hb.getClass().getMethod("close");
			}
			mHbClose.invoke(hb);
		} catch (Throwable t) {
		}
	}

	private void extDestroyImages() {
		long a = extImage;
		long b = extImgPrev1;
		long c = extImgPrev2;
		extImage = 0;
		extImgPrev1 = 0;
		extImgPrev2 = 0;
		imgDestroy(a);
		imgDestroy(b);
		imgDestroy(c);
	}

	private void grabExtFrame(SurfaceTexture st) {
		try {
			Object hb = hbOf(st);
			if (hb == null) {
				return;
			}
			long img = imgFromHb(hb);
			hbClose(hb);
			if (img != 0) {
				long old2 = extImgPrev2;
				extImgPrev2 = extImgPrev1;
				extImgPrev1 = extImage;
				extImage = img;
				extImgCount++;
				if (extImgCount <= 4 || extImgCount % 300 == 0) {
					Log.i("HHCamera", "extV2 img n=" + extImgCount);
				}
				imgDestroy(old2);
			} else {
				extV2Err = "img0";
			}
		} catch (Throwable t) {
			extV2Err = "grab:" + t;
			Log.w("HHCamera", "extV2 " + extV2Err);
		}
	}

	@UsedByGodot
	public long takeExtImage() {
		long v = extImage;
		extImage = 0;
		return v;
	}

	@UsedByGodot
	public long getExtImgCount() {
		return extImgCount;
	}

	@UsedByGodot
	public String getExtV2Err() {
		return extV2Err;
	}

	// ===== 内置 TTS 桥（修复回前台无声）=====（修复回前台无声）=====
	private void destroyTts() {
		try {
			if (tts != null) {
				tts.stop();
				tts.shutdown();
			}
		} catch (Throwable t) {
		}
		tts = null;
		ttsReady = false;
		ttsSpeaking = false;
	}

	private void ensureTts() {
		if (tts != null) {
			return;
		}
		try {
			final Activity act = getActivity();
			if (act == null) {
				return;
			}
			tts = new TextToSpeech(act, new TextToSpeech.OnInitListener() {
				@Override
				public void onInit(int status) {
					if (status == TextToSpeech.SUCCESS && tts != null) {
						try {
							int r = tts.setLanguage(Locale.CHINA);
							if (r == TextToSpeech.LANG_MISSING_DATA || r == TextToSpeech.LANG_NOT_SUPPORTED) {
								tts.setLanguage(Locale.getDefault());
							}
							tts.setSpeechRate(1.0f);
							tts.setPitch(1.0f);
						} catch (Throwable t) {
						}
						ttsReady = true;
						String pd = ttsPending;
						if (pd != null) {
							ttsPending = null;
							speakNow(pd);
						}
					} else {
						ttsReady = false;
					}
				}
			});
			tts.setOnUtteranceProgressListener(new UtteranceProgressListener() {
				@Override
				public void onStart(String id) {
					ttsSpeaking = true;
				}

				@Override
				public void onDone(String id) {
					ttsSpeaking = false;
				}

				@Override
				public void onError(String id) {
					ttsSpeaking = false;
				}
			});
		} catch (Throwable t) {
			tts = null;
		}
	}

	private void speakNow(String text) {
		try {
			ttsSpeaking = true;
			int r = tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "hh" + (++ttsGen));
			if (r == TextToSpeech.ERROR) {
				ttsSpeaking = false;
				destroyTts();
				ensureTts();
				ttsPending = text;
			}
		} catch (Throwable t) {
			ttsSpeaking = false;
		}
	}

	@UsedByGodot
	public void ttsSpeak(String text) {
		if (text == null || text.length() == 0) {
			return;
		}
		ensureTts();
		if (tts == null) {
			return;
		}
		if (!ttsReady) {
			ttsPending = text;
			return;
		}
		speakNow(text);
	}

	@UsedByGodot
	public void ttsStop() {
		ttsPending = null;
		ttsSpeaking = false;
		try {
			if (tts != null) {
				tts.stop();
			}
		} catch (Throwable t) {
		}
	}

	@UsedByGodot
	public boolean ttsIsSpeaking() {
		return ttsSpeaking;
	}

	@Override
	public void onMainDestroy() {
		destroyTts();
		super.onMainDestroy();
	}

	@UsedByGodot
	public boolean isActive() {
		return camera != null;
	}

	@UsedByGodot
	public void stop() {
		synchronized (lock) {
			wantActive = false;
			Log.i("HHCamera", "stop()");
			releaseCamera();
		}
	}

	private void retryOpen() {
		openTries++;
		if (openTries > 2 || !wantActive) {
			dbg = dbg + "|giveup";
			return;
		}
		dbg = dbg + "|retry" + openTries;
		final Handler h = camHandler;
		if (h != null) {
			h.postDelayed(new Runnable() {
				@Override
				public void run() {
					if (wantActive && camera == null) {
						openCamera();
					}
				}
			}, 800);
		}
	}
	private void releaseCamera() {
		extDestroyImages();
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
		stopExtPump();
		try {
			if (extSt != null) {
				extSt.release();
			}
		} catch (Throwable ignored) {
		}
		extSt = null;
		try {
			if (dummySt != null) {
				dummySt.release();
			}
		} catch (Throwable ignored) {
		}
		dummySt = null;
		if (camHandler != null) {
			try {
				camHandler.removeCallbacksAndMessages(null);
			} catch (Throwable ignored) {
			}
		}
		if (camThread != null) {
			try {
				camThread.quitSafely();
			} catch (Throwable ignored) {
			}
			camThread = null;
			camHandler = null;
		}
	}

	private void startExtPump() {
		stopExtPump();
		extPump = true;
		pumpThread = new HandlerThread("HHCameraGL");
		pumpThread.start();
		pumpHandler = new Handler(pumpThread.getLooper());
		final Runnable tick = new Runnable() {
			@Override
			public void run() {
				if (!extPump) {
					return;
				}
				try {
					getGodot().runOnRenderThread(extUpdateTask);
				} catch (Throwable ignored) {
				}
				Handler h = pumpHandler;
				if (h != null) {
					h.postDelayed(this, 16);
				}
			}
		};
		pumpHandler.post(tick);
	}

	private void stopExtPump() {
		extPump = false;
		Handler h = pumpHandler;
		pumpHandler = null;
		try {
			if (h != null) {
				h.removeCallbacksAndMessages(null);
			}
		} catch (Throwable ignored) {
		}
		HandlerThread th = pumpThread;
		pumpThread = null;
		try {
			if (th != null) {
				th.quitSafely();
			}
		} catch (Throwable ignored) {
		}
	}

	@UsedByGodot
	public int getPreviewWidth() {
		return lastPreviewWidth;
	}

	@UsedByGodot
	public int getPreviewHeight() {
		return lastPreviewHeight;
	}

	// ================= 原生相机预览（透明叠加模式） =================
	@UsedByGodot
	public boolean isNativeOn() {
		return nativeMode;
	}
	@UsedByGodot
	public boolean isNativeCamOk() {
		return nativeCam != null || cam2Device != null;
	}
	@UsedByGodot
	public void showNativePreview() {
		final Activity act = getActivity();
		if (act == null) {
			return;
		}
		nativeMode = true;
		nativeRetries = 0;
		act.runOnUiThread(new Runnable() {
			@Override
			public void run() {
				try {
					if (nativeView != null || nativeTexView != null) {
						return;
					}
					ViewGroup root = (ViewGroup) act.findViewById(android.R.id.content);
					if (root.getChildCount() > 0 && root.getChildAt(0) instanceof ViewGroup) {
						root = (ViewGroup) root.getChildAt(0);
					}
					final TextureView tv = new TextureView(act);
					tv.setLayoutParams(new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
					tv.setClickable(false);
					tv.setFocusable(false);
					root.addView(tv, 0);
					nativeTexView = tv;
					tv.setSurfaceTextureListener(new TextureView.SurfaceTextureListener() {
						@Override
						public void onSurfaceTextureAvailable(android.graphics.SurfaceTexture st, int width, int height) {
							Log.i("HHCamera", "tex surface available " + width + "x" + height);
							openNativeTexture(st);
						}
						@Override
						public void onSurfaceTextureSizeChanged(android.graphics.SurfaceTexture st, int width, int height) {
							Log.i("HHCamera", "tex size changed " + width + "x" + height);
							if (width > 0 && height > 0) {
								cam2BufW = width;
								cam2BufH = height;
							}
							applyTexTransform();
						}
						@Override
						public boolean onSurfaceTextureDestroyed(android.graphics.SurfaceTexture st) {
							closeNativeCam();
							return true;
						}
						@Override
						public void onSurfaceTextureUpdated(android.graphics.SurfaceTexture st) {
							try {
								frmCount.incrementAndGet();
								long now2 = android.os.SystemClock.elapsedRealtime();
								if (frmWindowStart == 0) {
									frmWindowStart = now2;
								}
								long dt = now2 - frmWindowStart;
								if (dt >= 2000) {
									int cw2 = frmCount.getAndSet(0);
									frmWindowStart = now2;
									Log.i("HHCamera", "tex fps=" + (cw2 * 1000 / dt));
								}
							} catch (Throwable ignored) {
							}
						}
					});
					try {
						attachTransparentLayers((ViewGroup) act.getWindow().getDecorView());
					} catch (Throwable ignoredA) {
					}
					Log.i("HHCamera", "native preview tex view added");
				} catch (Throwable t) {
					Log.e("HHCamera", "showNativePreview fail", t);
				}
			}
		});
		scheduleLayerAttach();
	}
	private void attachTransparentLayers(ViewGroup root) {
		int found = 0;
		try {
			for (int i = 0; i < root.getChildCount(); i++) {
				View v = root.getChildAt(i);
				if (v instanceof SurfaceView && v != nativeView) {
					String cn = v.getClass().getName();
					if (cn.contains("GodotGLRenderView") || cn.contains("GLSurfaceView")) {
						found++;
						if (layerAppliedView != v) {
							layerAppliedView = (SurfaceView) v;
							try {
								final SurfaceView gv = (SurfaceView) v;
								gv.setVisibility(View.INVISIBLE);
								gv.postDelayed(new Runnable() {
									@Override
									public void run() {
										try {
											gv.getHolder().setFormat(PixelFormat.TRANSLUCENT);
											gv.setZOrderOnTop(true);
											gv.setVisibility(View.VISIBLE);
											Log.i("HHCamera", "translucent layer set on " + gv.getClass().getName());
										} catch (Throwable t) {
											Log.e("HHCamera", "translucent set fail: " + t.getMessage());
										}
									}
								}, 150);
							} catch (Throwable t2) {
								Log.e("HHCamera", "layer dance fail: " + t2.getMessage());
							}
						}
					}
				}
				if (v instanceof ViewGroup) {
					attachTransparentLayers((ViewGroup) v);
				}
			}
		} catch (Throwable ignored) {
		}
		Log.i("HHCamera", "attach walk found=" + found);
	}
	private void closeCam2() {
		try {
			if (cam2Session != null) {
				cam2Session.close();
			}
		} catch (Throwable ignored) {
		}
		cam2Session = null;
		try {
			if (cam2Device != null) {
				cam2Device.close();
			}
		} catch (Throwable ignored) {
		}
		cam2Device = null;
		try {
			if (cam2Surface != null) {
				cam2Surface.release();
			}
		} catch (Throwable ignored) {
		}
		cam2Surface = null;
	}
	private void startNativeClassicFallback() {
		if (cam2FallbackDone) {
			return;
		}
		cam2FallbackDone = true;
		cam2Failed = true;
		closeCam2();
		final Activity act = getActivity();
		if (act == null) {
			return;
		}
		act.runOnUiThread(new Runnable() {
			@Override
			public void run() {
				try {
					if (nativeTexView != null) {
						ViewGroup p1 = (ViewGroup) nativeTexView.getParent();
						if (p1 != null) {
							p1.removeView(nativeTexView);
						}
						nativeTexView = null;
					}
					if (nativeView != null) {
						return;
					}
					ViewGroup root = (ViewGroup) act.findViewById(android.R.id.content);
					if (root.getChildCount() > 0 && root.getChildAt(0) instanceof ViewGroup) {
						root = (ViewGroup) root.getChildAt(0);
					}
					final SurfaceView sv = new SurfaceView(act);
					sv.setLayoutParams(new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
					sv.setClickable(false);
					sv.setFocusable(false);
					root.addView(sv, 0);
					nativeView = sv;
					sv.getHolder().addCallback(new SurfaceHolder.Callback() {
						@Override
						public void surfaceCreated(SurfaceHolder holder) {
							Log.i("HHCamera", "fallback surface created");
							openNativeCam(holder);
						}
						@Override
						public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
						}
						@Override
						public void surfaceDestroyed(SurfaceHolder holder) {
							closeNativeCam();
						}
					});
					Log.i("HHCamera", "classic fallback view added");
				} catch (Throwable t) {
					Log.e("HHCamera", "fallback fail: " + t.getMessage());
				}
			}
		});
	}
	private void openNativeTexture(final android.graphics.SurfaceTexture st) {
		if (cam2Device != null || cam2Failed || !nativeMode) {
			return;
		}
		synchronized (lock) {
			if (nativeThread == null) {
				nativeThread = new HandlerThread("HHCamNative");
				nativeThread.start();
				nativeHandler = new Handler(nativeThread.getLooper());
			}
		}
		final Handler h = nativeHandler;
		if (h == null) {
			return;
		}
		h.post(new Runnable() {
			@Override
			public void run() {
				try {
					if (!cam2Probed) {
						cam2Probed = true;
						probeCam2();
					}
					final android.hardware.camera2.CameraManager mgr = (android.hardware.camera2.CameraManager) getActivity().getSystemService(android.content.Context.CAMERA_SERVICE);
					if (mgr == null) {
						startNativeClassicFallback();
						return;
					}
					String camId = "0";
					try {
						for (String cid : mgr.getCameraIdList()) {
							Integer lens = mgr.getCameraCharacteristics(cid).get(android.hardware.camera2.CameraCharacteristics.LENS_FACING);
							if (lens != null && lens == android.hardware.camera2.CameraCharacteristics.LENS_FACING_BACK) {
								camId = cid;
								break;
							}
						}
					} catch (Throwable ignored) {
					}
					final String camIdF = camId;
					int cw = 3200;
					int ch = 1440;
					android.util.Range<Integer> fpsR = null;
					try {
						android.hardware.camera2.CameraCharacteristics cc2 = mgr.getCameraCharacteristics(camIdF);
						android.hardware.camera2.params.StreamConfigurationMap map = cc2.get(android.hardware.camera2.CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
						android.util.Size pick = null;
						if (map != null) {
							android.util.Size[] sizes = map.getOutputSizes(android.graphics.SurfaceTexture.class);
							if (sizes != null) {
								for (android.util.Size sz : sizes) {
									if (sz.getWidth() == 3200 && sz.getHeight() == 1440) {
										pick = sz;
										break;
									}
								}
								if (pick == null) {
									for (android.util.Size sz : sizes) {
										if (sz.getWidth() == 2800 && sz.getHeight() == 1260) {
											pick = sz;
											break;
										}
									}
								}
								if (pick == null) {
									double bestScore = 1e9;
									for (android.util.Size sz : sizes) {
										if (sz.getWidth() < 1920) {
											continue;
										}
										double asp = (double) sz.getWidth() / (double) sz.getHeight();
										double score = Math.abs(asp - 2.2222);
										if (score < bestScore) {
											bestScore = score;
											pick = sz;
										}
									}
								}
							}
						}
						if (pick != null) {
							cw = pick.getWidth();
							ch = pick.getHeight();
						}
						android.util.Range<Integer>[] rs = cc2.get(android.hardware.camera2.CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES);
						if (rs != null) {
							for (android.util.Range<Integer> rrr : rs) {
								if (rrr.getUpper() == 60 && rrr.getLower() == 60) {
									fpsR = rrr;
								}
							}
							if (fpsR == null) {
								for (android.util.Range<Integer> rrr : rs) {
									if (rrr.getUpper() == 60 && rrr.getLower() <= 15) {
										fpsR = rrr;
									}
								}
							}
						}
					} catch (Throwable t) {
						Log.e("HHCamera", "cam2 config read fail: " + t.getMessage());
					}
					cam2BufW = cw;
					cam2BufH = ch;
					final android.util.Range<Integer> fpsRF = fpsR;
					Log.i("HHCamera", "cam2 buffer=" + cw + "x" + ch + " fps=" + fpsRF);
					st.setDefaultBufferSize(cw, ch);
					final android.view.Surface surf = new android.view.Surface(st);
					cam2Surface = surf;
					try {
						if (android.os.Build.VERSION.SDK_INT >= 30) {
							surf.setFrameRate(60.0f, android.view.Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE);
						}
					} catch (Throwable ignored) {
					}
					mgr.openCamera(camIdF, new android.hardware.camera2.CameraDevice.StateCallback() {
						@Override
						public void onOpened(android.hardware.camera2.CameraDevice dev) {
							cam2Device = dev;
							try {
								dev.createCaptureSession(java.util.Collections.singletonList(surf), new android.hardware.camera2.CameraCaptureSession.StateCallback() {
									@Override
									public void onConfigured(android.hardware.camera2.CameraCaptureSession session) {
										cam2Session = session;
										try {
											android.hardware.camera2.CaptureRequest.Builder b = dev.createCaptureRequest(android.hardware.camera2.CameraDevice.TEMPLATE_PREVIEW);
											b.addTarget(surf);
											b.set(android.hardware.camera2.CaptureRequest.CONTROL_AF_MODE, android.hardware.camera2.CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO);
											if (fpsRF != null) {
												b.set(android.hardware.camera2.CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fpsRF);
											}
											try {
												session.setRepeatingRequest(b.build(), null, nativeHandler);
												Log.i("HHCamera", "cam2 preview started fps=" + fpsRF);
												final android.graphics.SurfaceTexture stF = st;
												nativeHandler.postDelayed(new Runnable() {
													@Override
													public void run() {
														try {
															float[] tm = new float[16];
															stF.getTransformMatrix(tm);
															Log.i("HHCamera", "st tm: " + tm[0] + " " + tm[1] + " " + tm[4] + " " + tm[5]);
														} catch (Throwable ignored) {
														}
													}
												}, 900);
											} catch (Throwable t) {
												Log.e("HHCamera", "cam2 fps req fail, retry default: " + t.getMessage());
												b.set(android.hardware.camera2.CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, null);
												session.setRepeatingRequest(b.build(), null, nativeHandler);
												Log.i("HHCamera", "cam2 preview started (default fps)");
											}
											applyTexTransform();
										} catch (Throwable t) {
											Log.e("HHCamera", "cam2 request fail: " + t.getMessage());
										}
									}
									@Override
									public void onConfigureFailed(android.hardware.camera2.CameraCaptureSession session) {
										Log.e("HHCamera", "cam2 session failed");
										startNativeClassicFallback();
									}
								}, nativeHandler);
							} catch (Throwable t) {
								Log.e("HHCamera", "cam2 session create fail: " + t.getMessage());
								startNativeClassicFallback();
							}
						}
						@Override
						public void onDisconnected(android.hardware.camera2.CameraDevice dev) {
							Log.e("HHCamera", "cam2 disconnected");
							dev.close();
							cam2Device = null;
						}
						@Override
						public void onError(android.hardware.camera2.CameraDevice dev, int error) {
							Log.e("HHCamera", "cam2 error " + error);
							dev.close();
							cam2Device = null;
							startNativeClassicFallback();
						}
					}, nativeHandler);
				} catch (Throwable t) {
					Log.e("HHCamera", "cam2 start fail: " + t.getMessage());
					startNativeClassicFallback();
				}
			}
		});
	}
	private void applyTexTransform() {
		final TextureView tv = nativeTexView;
		if (tv == null || cam2BufW <= 0) {
			return;
		}
		final Activity act = getActivity();
		if (act == null) {
			return;
		}
		act.runOnUiThread(new Runnable() {
			@Override
			public void run() {
				try {
					int rot = act.getWindowManager().getDefaultDisplay().getRotation();
					int rd = rot * 90;
					int sensor = 90;
					int dispOri = (sensor - rd + 360) % 360;
					// vivo HAL 实测将流顺时针转了 90 度，反向逆时针校正；按钮可再叠 0/90/180/270
					dispOri = (dispOri + 270 + debugRotOffset) % 360;
					int vw = tv.getWidth();
					int vh = tv.getHeight();
					if (vw <= 0 || vh <= 0) {
						return;
					}
					float cx = vw * 0.5f;
					float cy = vh * 0.5f;
					android.graphics.Matrix m = new android.graphics.Matrix();
					m.postRotate(dispOri, cx, cy);
					int fw = (dispOri % 180 == 90) ? vh : vw;
					int fh = (dispOri % 180 == 90) ? vw : vh;
					float s = Math.max((float) vw / fw, (float) vh / fh);
					m.postScale(s, s, cx, cy);
					if (extraScaleX != 1.0f || extraScaleY != 1.0f) {
						m.postScale(extraScaleX, extraScaleY, cx, cy);
					}
					tv.setTransform(m);
					Log.i("HHCamera", "tex transform rot=" + dispOri + " k=" + s + " ex=" + extraScaleX + "," + extraScaleY + " view=" + vw + "x" + vh);
				} catch (Throwable t) {
					Log.e("HHCamera", "tex transform fail: " + t.getMessage());
				}
			}
		});
	}
	@UsedByGodot
	public void setExtraScale(float sx, float sy) {
		extraScaleX = sx;
		extraScaleY = sy;
		applyTexTransform();
	}
	@UsedByGodot
	public void cycleRotation() {
		debugRotOffset = (debugRotOffset + 90) % 360;
		Log.i("HHCamera", "debug rot offset=" + debugRotOffset);
		applyTexTransform();
	}
	@UsedByGodot
	public void refreshNativeTransform() {
		applyTexTransform();
	}
	@UsedByGodot
	public void probeCam2() {
		try {
			android.hardware.camera2.CameraManager mgr = (android.hardware.camera2.CameraManager) getActivity().getSystemService(android.content.Context.CAMERA_SERVICE);
			if (mgr == null) {
				Log.i("HHCamera", "cam2: no manager");
				return;
			}
			String[] ids = mgr.getCameraIdList();
			Log.i("HHCamera", "cam2 ids: " + java.util.Arrays.toString(ids));
			for (String id : ids) {
				try {
					android.hardware.camera2.CameraCharacteristics cc = mgr.getCameraCharacteristics(id);
					Integer lens = cc.get(android.hardware.camera2.CameraCharacteristics.LENS_FACING);
					android.hardware.camera2.params.StreamConfigurationMap map = cc.get(android.hardware.camera2.CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
					StringBuilder sb = new StringBuilder();
					boolean has4k = false;
					if (map != null) {
						android.util.Size[] sizes = map.getOutputSizes(android.graphics.SurfaceTexture.class);
						if (sizes != null) {
							for (android.util.Size sz : sizes) {
								sb.append(sz.getWidth()).append("x").append(sz.getHeight()).append(" ");
								if (sz.getWidth() >= 3840) {
									has4k = true;
								}
							}
						}
					}
					Log.i("HHCamera", "cam2 " + id + " lens=" + lens + " st: " + sb.toString());
					Log.i("HHCamera", "cam2 " + id + " hasUhd=" + has4k);
					android.util.Range<Integer>[] ae = cc.get(android.hardware.camera2.CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES);
					StringBuilder sb2 = new StringBuilder();
					if (ae != null) {
						for (android.util.Range<Integer> rg : ae) {
							sb2.append(rg.getLower()).append("-").append(rg.getUpper()).append(" ");
						}
					}
					Log.i("HHCamera", "cam2 " + id + " fps: " + sb2.toString());
				} catch (Throwable t) {
					Log.e("HHCamera", "cam2 " + id + " fail: " + t.getMessage());
				}
			}
		} catch (Throwable t) {
			Log.e("HHCamera", "cam2 probe fail: " + t.getMessage());
		}
	}
	private void scheduleLayerAttach() {
		final Activity act = getActivity();
		if (act == null) {
			return;
		}
		final View decor = act.getWindow().getDecorView();
		final long[] delays = { 60L, 200L, 500L, 1000L, 2000L, 3500L };
		for (final long d : delays) {
			decor.postDelayed(new Runnable() {
				@Override
				public void run() {
					try {
						if (decor instanceof ViewGroup) {
							attachTransparentLayers((ViewGroup) decor);
						}
					} catch (Throwable ignored) {
					}
				}
			}, d);
		}
	}
	private void openNativeCam(final SurfaceHolder holder) {
		synchronized (lock) {
			if (nativeThread == null) {
				nativeThread = new HandlerThread("HHCamNative");
				nativeThread.start();
				nativeHandler = new Handler(nativeThread.getLooper());
			}
		}
		final Handler h = nativeHandler;
		if (h == null) {
			return;
		}
		h.post(new Runnable() {
			@Override
			public void run() {
				try {
					if (nativeCam != null) {
						return;
					}
					if (!cam2Probed) {
						cam2Probed = true;
						probeCam2();
					}
					Camera cam = Camera.open(0);
					Camera.CameraInfo info = new Camera.CameraInfo();
					Camera.getCameraInfo(0, info);
					Camera.Parameters p = cam.getParameters();
					List<Camera.Size> sizes = p.getSupportedPreviewSizes();
					if (sizes == null) {
						sizes = new java.util.ArrayList<Camera.Size>();
					}
					StringBuilder sb = new StringBuilder();
					for (Camera.Size s : sizes) {
						sb.append(s.width).append("x").append(s.height).append(" ");
					}
					Log.i("HHCamera", "native sizes: " + sb.toString());
					Camera.Size best = null;
					for (Camera.Size s : sizes) {
						if (s.width == 2800 && s.height == 1260) {
							best = s;
							break;
						}
					}
					if (best == null) {
						double bestScore = 1e9;
						for (Camera.Size s : sizes) {
							if (s.width < 1920) {
								continue;
							}
							double asp = (double) s.width / (double) s.height;
							double score = Math.abs(asp - 2.2222);
							if (score < bestScore) {
								bestScore = score;
								best = s;
							}
						}
					}
					if (best == null) {
						for (Camera.Size s : sizes) {
							if (best == null || (long) s.width * s.height > (long) best.width * best.height) {
								best = s;
							}
						}
					}
					Log.i("HHCamera", "native chosen=" + (best != null ? (best.width + "x" + best.height) : "none"));
					if (best != null) {
						p.setPreviewSize(best.width, best.height);
					}
					try {
						List<String> fm = p.getSupportedFocusModes();
						StringBuilder sf = new StringBuilder();
						if (fm != null) {
							for (String m2 : fm) {
								sf.append(m2).append(" ");
							}
						}
						Log.i("HHCamera", "native focus modes: " + sf.toString());
						if (fm != null) {
							if (fm.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_VIDEO)) {
								p.setFocusMode(Camera.Parameters.FOCUS_MODE_CONTINUOUS_VIDEO);
							} else if (fm.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE)) {
								p.setFocusMode(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE);
							} else if (fm.contains(Camera.Parameters.FOCUS_MODE_AUTO)) {
								p.setFocusMode(Camera.Parameters.FOCUS_MODE_AUTO);
							}
						}
					} catch (Throwable tf) {
						Log.e("HHCamera", "focus set fail: " + tf.getMessage());
					}
					try {
						List<int[]> frs = p.getSupportedPreviewFpsRange();
						StringBuilder sr = new StringBuilder();
						int[] bestR = null;
						if (frs != null) {
							for (int[] rr : frs) {
								sr.append(rr[0]).append("-").append(rr[1]).append(" ");
								if (bestR == null || rr[1] > bestR[1]) {
									bestR = rr;
								}
							}
						}
						Log.i("HHCamera", "native fps ranges: " + sr.toString());
						if (bestR != null) {
							p.setPreviewFpsRange(bestR[0], bestR[1]);
						}
					} catch (Throwable tf2) {
						Log.e("HHCamera", "fps set fail: " + tf2.getMessage());
					}
					try {
						cam.setParameters(p);
					} catch (Throwable t) {
						Log.e("HHCamera", "native setParameters fail: " + t.getMessage());
						try {
							Camera.Parameters p2 = cam.getParameters();
							if (best != null) {
								p2.setPreviewSize(best.width, best.height);
							}
							cam.setParameters(p2);
						} catch (Throwable t2) {
							Log.e("HHCamera", "native setParameters retry fail: " + t2.getMessage());
						}
					}
					Camera.Parameters pc = cam.getParameters();
					Log.i("HHCamera", "native confirm sz=" + pc.getPreviewSize().width + "x" + pc.getPreviewSize().height);
					int dispOri = 90;
					try {
						int rot = getActivity().getWindowManager().getDefaultDisplay().getRotation();
						dispOri = (info.orientation - rot * 90 + 360) % 360;
					} catch (Throwable ignoredR) {
					}
					cam.setDisplayOrientation(dispOri);
					Log.i("HHCamera", "native sensor=" + info.orientation + " disp=" + dispOri);
					cam.setPreviewDisplay(holder);
					cam.startPreview();
					nativeCam = cam;
					lastPreviewWidth = (best != null) ? best.width : 0;
					lastPreviewHeight = (best != null) ? best.height : 0;
					Log.i("HHCamera", "native cam started sz=" + lastPreviewWidth + "x" + lastPreviewHeight);
				} catch (Throwable t) {
					Log.e("HHCamera", "native cam fail", t);
					nativeRetries++;
					final Handler hh = nativeHandler;
					if (hh != null && nativeMode && nativeCam == null && nativeRetries < 4) {
						hh.postDelayed(new Runnable() {
							@Override
							public void run() {
								if (nativeMode && nativeCam == null) {
									openNativeCam(holder);
								}
							}
						}, 700);
					}
				}
			}
		});
	}
	private void closeNativeCam() {
		closeCam2();
		final Handler h = nativeHandler;
		if (h == null) {
			try {
				if (nativeCam != null) {
					nativeCam.stopPreview();
					nativeCam.release();
				}
			} catch (Throwable ignored) {
			}
			nativeCam = null;
			return;
		}
		h.post(new Runnable() {
			@Override
			public void run() {
				try {
					if (nativeCam != null) {
						try {
							nativeCam.setPreviewDisplay(null);
						} catch (Throwable ignored) {
						}
						try {
							nativeCam.stopPreview();
						} catch (Throwable ignored) {
						}
						nativeCam.release();
						nativeCam = null;
						Log.i("HHCamera", "native cam closed");
					}
				} catch (Throwable t) {
					Log.e("HHCamera", "native close fail", t);
				}
			}
		});
	}
	@UsedByGodot
	public void hideNativePreview() {
		nativeMode = false;
		closeNativeCam();
		final Activity act = getActivity();
		if (act == null) {
			return;
		}
		act.runOnUiThread(new Runnable() {
			@Override
			public void run() {
				try {
					if (nativeTexView != null) {
						ViewGroup parentT = (ViewGroup) nativeTexView.getParent();
						if (parentT != null) {
							parentT.removeView(nativeTexView);
						}
						nativeTexView = null;
						Log.i("HHCamera", "native tex view removed");
					}
					if (nativeView != null) {
						ViewGroup parent = (ViewGroup) nativeView.getParent();
						if (parent != null) {
							parent.removeView(nativeView);
						}
						nativeView = null;
						Log.i("HHCamera", "native preview view removed");
					}
				} catch (Throwable t) {
					Log.e("HHCamera", "hideNativePreview fail", t);
				}
			}
		});
	}
	@Override
	public void onMainPause() {
		synchronized (lock) {
			releaseCamera();
		}
		closeNativeCam();
	}

	@Override
	public void onMainResume() {
		synchronized (lock) {
			if (wantActive && camera == null) {
				startInternalLocked();
			}
		}
		if (nativeMode) {
			scheduleLayerAttach();
			if (nativeCam == null && nativeView != null) {
				openNativeCam(nativeView.getHolder());
			}
			if (cam2Device == null && nativeTexView != null && !cam2Failed) {
				android.graphics.SurfaceTexture st2 = nativeTexView.getSurfaceTexture();
				if (st2 != null) {
					openNativeTexture(st2);
				}
			}
			applyTexTransform();
		}
		if (tts == null || !ttsReady) {
			ensureTts();
		} else {
			try {
				tts.getVoices();
			} catch (Throwable t) {
				destroyTts();
				ensureTts();
			}
		}
	}
}