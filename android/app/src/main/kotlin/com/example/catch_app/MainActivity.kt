package com.example.catch_app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.google.mlkit.nl.entityextraction.DateTimeEntity
import com.google.mlkit.nl.entityextraction.EntityExtraction
import com.google.mlkit.nl.entityextraction.EntityExtractorOptions
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "catch/teams_capture"
        private const val CAPTURE_REQUEST = 7102
        private const val CAPTURE_PREFS = "catch_capture"
        private const val PENDING_RESULT = "pending_result"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startCapture" -> startCapture(result)
                    "hasOverlayPermission" -> result.success(Settings.canDrawOverlays(this))
                    "takePendingResult" -> result.success(takePendingResult())
                    "extractDateTimes" -> extractDateTimes(
                        call.argument<String>("text") ?: "",
                        result,
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun extractDateTimes(text: String, result: MethodChannel.Result) {
        if (text.isBlank()) {
            result.success(emptyList<Map<String, Any>>())
            return
        }
        val extractor = EntityExtraction.getClient(
            EntityExtractorOptions.Builder(EntityExtractorOptions.JAPANESE).build(),
        )
        extractor.downloadModelIfNeeded()
            .addOnSuccessListener {
                extractor.annotate(text)
                    .addOnSuccessListener { annotations ->
                        val output = mutableListOf<Map<String, Any>>()
                        for (annotation in annotations) {
                            val matchedText = text.substring(
                                annotation.start.coerceAtLeast(0),
                                annotation.end.coerceAtMost(text.length),
                            )
                            for (entity in annotation.entities) {
                                if (entity is DateTimeEntity) {
                                    output.add(
                                        mapOf(
                                            "timestampMillis" to entity.timestampMillis,
                                            "granularity" to entity.dateTimeGranularity,
                                            "text" to matchedText,
                                        ),
                                    )
                                }
                            }
                        }
                        extractor.close()
                        result.success(output)
                    }
                    .addOnFailureListener { error ->
                        extractor.close()
                        result.error("AI_ANALYSIS_FAILED", error.localizedMessage, null)
                    }
            }
            .addOnFailureListener { error ->
                extractor.close()
                result.error("AI_MODEL_FAILED", error.localizedMessage, null)
            }
    }

    private fun startCapture(result: MethodChannel.Result) {
        if (!Settings.canDrawOverlays(this)) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:$packageName"),
                ),
            )
            result.success(mapOf("status" to "overlay_permission"))
            return
        }
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        startActivityForResult(manager.createScreenCaptureIntent(), CAPTURE_REQUEST)
        result.success(mapOf("status" to "requested"))
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != CAPTURE_REQUEST || resultCode != Activity.RESULT_OK || data == null) return
        val serviceIntent = Intent(this, TeamsCaptureService::class.java).apply {
            action = TeamsCaptureService.ACTION_START
            putExtra(TeamsCaptureService.EXTRA_RESULT_CODE, resultCode)
            putExtra(TeamsCaptureService.EXTRA_RESULT_DATA, data)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
    }

    private fun takePendingResult(): Map<String, Any?>? {
        val prefs = getSharedPreferences(CAPTURE_PREFS, MODE_PRIVATE)
        val raw = prefs.getString(PENDING_RESULT, null) ?: return null
        prefs.edit().remove(PENDING_RESULT).apply()
        return try {
            val json = JSONObject(raw)
            buildMap {
                if (json.has("text")) put("text", json.optString("text"))
                if (json.has("error")) put("error", json.optString("error"))
            }
        } catch (_: Exception) {
            mapOf("error" to "読み取り結果を開けませんでした")
        }
    }
}
