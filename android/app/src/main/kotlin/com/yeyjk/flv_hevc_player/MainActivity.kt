package com.yeyjk.flv_hevc_player

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader

class MainActivity : FlutterActivity() {
    private val CHANNEL = "m3u_player/io"
    private val PIP_CHANNEL = "m3u_player/pip"
    private var pickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 播放期间保持屏幕唤醒不自动熄屏（监控场景必需）
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // IO / 偏好存储 / 文件选择
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getAppDir" -> {
                    result.success(filesDir.absolutePath)
                }
                "pickM3U" -> {
                    pickResult = result
                    val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        // 只显示 M3U / M3U8 / TXT 等播放列表文件
                        putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(
                            "audio/x-mpegurl",
                            "audio/mpegurl",
                            "application/x-mpegURL",
                            "application/x-mpegurl",
                            "application/vnd.apple.mpegurl",
                            "audio/x-mpegURL",
                            "text/plain",
                            "text/xml"
                        ))
                    }
                    try {
                        startActivityForResult(intent, REQUEST_PICK_M3U)
                    } catch (e: Exception) {
                        result.error("PICK_FAILED", e.message, null)
                        pickResult = null
                    }
                }
                "prefsGetString" -> {
                    val key = call.argument<String>("key") ?: ""
                    val v = getSharedPreferences(PREFS, MODE_PRIVATE).getString(key, null)
                    android.util.Log.d("M3UPREFS", "prefsGetString $key = $v")
                    result.success(v)
                }
                "prefsGetInt" -> {
                    val key = call.argument<String>("key") ?: ""
                    val sp = getSharedPreferences(PREFS, MODE_PRIVATE)
                    val v = if (sp.contains(key)) sp.getInt(key, 0) else null
                    android.util.Log.d("M3UPREFS", "prefsGetInt $key = $v")
                    result.success(v)
                }
                "prefsGetBool" -> {
                    val key = call.argument<String>("key") ?: ""
                    val sp = getSharedPreferences(PREFS, MODE_PRIVATE)
                    val v = if (sp.contains(key)) sp.getBoolean(key, false) else null
                    android.util.Log.d("M3UPREFS", "prefsGetBool $key = $v")
                    result.success(v)
                }
                "prefsSet" -> {
                    val key = call.argument<String>("key") ?: ""
                    val type = call.argument<String>("type") ?: "string"
                    val sp = getSharedPreferences(PREFS, MODE_PRIVATE)
                    val editor = sp.edit()
                    when (type) {
                        "string" -> editor.putString(key, call.argument<String>("value"))
                        // 用 Number 兼容 Flutter 传过来的 Int/Long，避免 argument<Int> 为 null
                        "int" -> {
                            val v: Number? = call.argument<Number>("value")
                            android.util.Log.d("M3UPREFS", "prefsSet int $key = $v")
                            editor.putInt(key, v?.toInt() ?: 0)
                        }
                        "bool" -> editor.putBoolean(
                            key,
                            call.argument<Boolean>("value") ?: false
                        )
                    }
                    editor.apply()
                    android.util.Log.d("M3UPREFS", "prefsSet done $key type=$type")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // 画中画
        MethodChannel(messenger, PIP_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "enter" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                        packageManager.hasSystemFeature(
                            android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE
                        )
                    ) {
                        try {
                            val w = (call.argument<Number>("width") ?: 16).toInt()
                            val h = (call.argument<Number>("height") ?: 9).toInt()
                            val params = PictureInPictureParams.Builder()
                                .setAspectRatio(Rational(w, h))
                                .build()
                            enterPictureInPictureMode(params)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    } else {
                        result.success(false)
                    }
                }
                "isPip" -> {
                    result.success(
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && isInPictureInPictureMode
                    )
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        // 通知 Flutter 侧画中画状态变化
        try {
            val engine = flutterEngine
            if (engine != null) {
                MethodChannel(engine.dartExecutor.binaryMessenger, PIP_CHANNEL)
                    .invokeMethod("onPipChanged", isInPictureInPictureMode)
            }
        } catch (_: Exception) {
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_PICK_M3U) {
            val result = pickResult ?: return
            pickResult = null
            if (resultCode != RESULT_OK || data?.data == null) {
                result.success(null)
                return
            }
            val uri: Uri = data.data!!
            try {
                val content = contentResolver.openInputStream(uri)?.use { input ->
                    BufferedReader(InputStreamReader(input, Charsets.UTF_8)).readText()
                } ?: ""
                result.success(content)
            } catch (e: Exception) {
                result.error("READ_FAILED", e.message, null)
            }
        }
    }

    companion object {
        private const val REQUEST_PICK_M3U = 1001
        private const val PREFS = "m3u_prefs"
    }
}

