package com.hta.halfhearted;

import android.graphics.ImageFormat;
import android.graphics.Rect;
import android.graphics.YuvImage;
import android.app.Activity;
import android.hardware.Camera;
import android.os.Handler;
import android.os.HandlerThread;
import android.graphics.SurfaceTexture;
import android.os.SystemClock;
import android.util.Log;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import java.util.Locale;

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
	private volatile int openTries = 0;
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
				android.graphics.Point p = new android.graphics.Point();
				actA.getWindowManager().getDefaultDisplay().getRealSize(p);
				int sm = Math.max(p.x, p.y);
				int sn = Math.min(p.x, p.y);
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
			Log.i("HHCamera", "sizes=" + sb.toString() + " chosen=" + (best != null ? (best.width + "x" + best.height) : "none") + " maxW=" + maxW);
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
				extSt = new SurfaceTexture(externalTexId);
				extSt.setDefaultBufferSize(se.width, se.height);
				extSt.setOnFrameAvailableListener(new SurfaceTexture.OnFrameAvailableListener() {
					@Override
					public void onFrameAvailable(SurfaceTexture st) {
						extInFrames++;
					}
				});
				c.setPreviewTexture(extSt);
				c.startPreview();
				dbg = dbg + "|ext " + se.width + "x" + se.height;
				Log.i("HHCamera", "ext attach " + se.width + "x" + se.height);
				startExtPump();
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

	// ===== 内置 TTS 桥（修复回前台无声）=====
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
	public void onMainResume() {
		super.onMainResume();
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