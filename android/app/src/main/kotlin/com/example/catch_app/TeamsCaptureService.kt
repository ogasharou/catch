package com.example.catch_app

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.WindowManager
import android.view.View
import android.widget.Button
import android.widget.Toast
import androidx.core.app.NotificationCompat
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
import org.json.JSONObject

class TeamsCaptureService : Service() {
    companion object {
        const val ACTION_START = "com.example.catch_app.START_CAPTURE"
        const val ACTION_STOP = "com.example.catch_app.STOP_CAPTURE"
        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_RESULT_DATA = "result_data"
        private const val CHANNEL_ID = "catch_screen_capture"
        private const val NOTIFICATION_ID = 7103
        private const val CAPTURE_PREFS = "catch_capture"
        private const val PENDING_RESULT = "pending_result"
    }

    private val handler = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var reader: ImageReader? = null
    private var display: VirtualDisplay? = null
    private var overlay: Button? = null
    private var windowManager: WindowManager? = null
    private var capturing = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        createChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        if (intent?.action == ACTION_START && projection == null) {
            val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
            val resultData = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(EXTRA_RESULT_DATA)
            }
            if (resultCode == Activity.RESULT_OK && resultData != null) {
                startProjection(resultCode, resultData)
            } else {
                saveError("画面共有の許可を取得できませんでした")
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun startProjection(resultCode: Int, data: Intent) {
        if (!Settings.canDrawOverlays(this)) {
            saveError("Catchボタンを表示する権限がありません")
            stopSelf()
            return
        }
        val metrics = resources.displayMetrics
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        val density = metrics.densityDpi
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val activeProjection = manager.getMediaProjection(resultCode, data)
        if (activeProjection == null) {
            saveError("画面共有を開始できませんでした")
            stopSelf()
            return
        }
        activeProjection.registerCallback(
            object : MediaProjection.Callback() {
                override fun onStop() {
                    stopSelf()
                }
            },
            handler,
        )
        projection = activeProjection
        reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        reader?.setOnImageAvailableListener({ source ->
            // 読み取り待機中も古いフレームを捨て、ボタンを押した瞬間の画面を取得できるようにする。
            if (!capturing) source.acquireLatestImage()?.close()
        }, handler)
        display = projection?.createVirtualDisplay(
            "CatchTeamsCapture",
            width,
            height,
            density,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            reader?.surface,
            null,
            handler,
        )
        showOverlayButton()
        Toast.makeText(this, "Teamsの課題を開き、Catchボタンを押してください", Toast.LENGTH_LONG).show()
    }

    private fun showOverlayButton() {
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val button = Button(this).apply {
            text = "Catch"
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.rgb(68, 104, 232))
            elevation = 12f
            setPadding(28, 4, 28, 4)
            setOnClickListener { captureCurrentFrame() }
        }
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            },
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.END or Gravity.CENTER_VERTICAL
            x = 18
            y = 0
        }
        var downX = 0f
        var downY = 0f
        var startX = 0
        var startY = 0
        button.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downY = event.rawY
                    startX = params.x
                    startY = params.y
                    false
                }
                MotionEvent.ACTION_MOVE -> {
                    params.x = startX - (event.rawX - downX).toInt()
                    params.y = startY + (event.rawY - downY).toInt()
                    windowManager?.updateViewLayout(button, params)
                    true
                }
                else -> false
            }
        }
        overlay = button
        windowManager?.addView(button, params)
    }

    private fun captureCurrentFrame() {
        if (capturing) return
        capturing = true
        overlay?.isEnabled = false
        // Catchボタン自身がスクリーンショット/OCRに入らないよう、先に隠す。
        overlay?.visibility = View.GONE
        handler.postDelayed({ acquireFrame() }, 220)
    }

    private fun acquireFrame(attempt: Int = 0) {
        val image = reader?.acquireLatestImage()
        if (image == null) {
            if (attempt < 8) {
                handler.postDelayed({ acquireFrame(attempt + 1) }, 120)
            } else {
                capturing = false
                overlay?.isEnabled = true
                Toast.makeText(this, "画面を取得できませんでした。もう一度押してください", Toast.LENGTH_SHORT).show()
            }
            return
        }
        val bitmap = imageToBitmap(image)
        image.close()

        // Exclude only the system chrome where the device clock / screen-share
        // indicator lives. Keep almost the whole app so headings near the top
        // are not lost.
        val topInset = (bitmap.height * 0.04f).toInt().coerceAtLeast(0)
        val bottomInset = (bitmap.height * 0.03f).toInt().coerceAtLeast(0)
        val contentHeight = (bitmap.height - topInset - bottomInset).coerceAtLeast(1)
        val ocrBitmap = Bitmap.createBitmap(bitmap, 0, topInset, bitmap.width, contentHeight)

        val recognizer = TextRecognition.getClient(JapaneseTextRecognizerOptions.Builder().build())
        recognizer.process(InputImage.fromBitmap(ocrBitmap, 0))
            .addOnSuccessListener { result ->
                val text = result.text.trim()
                if (text.isEmpty()) {
                    saveError("文字を見つけられませんでした。課題名と締切が見える画面で試してください")
                } else {
                    saveText(text)
                }
                if (ocrBitmap !== bitmap) ocrBitmap.recycle()
                bitmap.recycle()
                recognizer.close()
                openCatch()
                stopSelf()
            }
            .addOnFailureListener { error ->
                if (ocrBitmap !== bitmap) ocrBitmap.recycle()
                bitmap.recycle()
                recognizer.close()
                saveError(error.localizedMessage ?: "文字認識に失敗しました")
                openCatch()
                stopSelf()
            }
    }

    private fun imageToBitmap(image: Image): Bitmap {
        val plane = image.planes[0]
        val buffer = plane.buffer
        val pixelStride = plane.pixelStride
        val rowStride = plane.rowStride
        val rowPadding = rowStride - pixelStride * image.width
        val wide = Bitmap.createBitmap(
            image.width + rowPadding / pixelStride,
            image.height,
            Bitmap.Config.ARGB_8888,
        )
        wide.copyPixelsFromBuffer(buffer)
        val cropped = Bitmap.createBitmap(wide, 0, 0, image.width, image.height)
        if (cropped !== wide) wide.recycle()
        return cropped
    }

    private fun saveText(text: String) {
        getSharedPreferences(CAPTURE_PREFS, MODE_PRIVATE)
            .edit()
            .putString(PENDING_RESULT, JSONObject().put("text", text).toString())
            .apply()
    }

    private fun saveError(message: String) {
        getSharedPreferences(CAPTURE_PREFS, MODE_PRIVATE)
            .edit()
            .putString(PENDING_RESULT, JSONObject().put("error", message).toString())
            .apply()
    }

    private fun openCatch() {
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        startActivity(intent)
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "画面から取り込む",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "表示中の画面を一時読み取りする間に表示されます"
            },
        )
    }

    private fun buildNotification(): android.app.Notification {
        val stopIntent = Intent(this, TeamsCaptureService::class.java).apply { action = ACTION_STOP }
        val pendingStop = PendingIntent.getService(
            this,
            0,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Catch：画面から取り込み")
            .setContentText("取り込みたい画面を開いてCatchボタンを押してください")
            .setOngoing(true)
            .addAction(0, "終了", pendingStop)
            .build()
    }

    override fun onDestroy() {
        overlay?.let { view ->
            try {
                windowManager?.removeView(view)
            } catch (_: Exception) {
            }
        }
        overlay = null
        display?.release()
        display = null
        reader?.close()
        reader = null
        projection?.stop()
        projection = null
        super.onDestroy()
    }
}
