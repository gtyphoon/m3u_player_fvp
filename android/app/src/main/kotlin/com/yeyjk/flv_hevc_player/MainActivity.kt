package com.yeyjk.flv_hevc_player

import android.app.PictureInPictureParams
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
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
                // 截图/录制落盘：直接存到公共"下载/M3U播放器/子目录"
                // API 29+ 走 MediaStore（免权限），API 24~28 需要存储权限
                "saveCaptureFile" -> {
                    val name = call.argument<String>("name")
                    val subdir = call.argument<String>("subdir") ?: ""
                    val bytes = call.argument<ByteArray>("bytes")
                    val mime = call.argument<String>("mime") ?: "application/octet-stream"
                    if (name == null || bytes == null) {
                        result.error("BAD_ARGS", "name/bytes is null", null)
                    } else {
                        saveCaptureAsync(name, subdir, bytes, mime, result)
                    }
                }
                // 录制文件（可能几百 MB）：从应用私有目录流式复制到公共下载目录
                "publishCaptureFile" -> {
                    val srcPath = call.argument<String>("path")
                    val name = call.argument<String>("name")
                    val subdir = call.argument<String>("subdir") ?: ""
                    val mime = call.argument<String>("mime") ?: "application/octet-stream"
                    if (srcPath == null || name == null || !File(srcPath).exists()) {
                        result.error("BAD_ARGS", "source file not found", null)
                    } else {
                        publishFileAsync(File(srcPath), name, subdir, mime, result)
                    }
                }
                // 打开外部链接（关于页项目主页 / 新版本下载页）
                "openUrl" -> {
                    val url = call.argument<String>("url") ?: ""
                    if (url.isEmpty()) {
                        result.error("BAD_ARGS", "url is empty", null)
                    } else {
                        try {
                            val intent = Intent(
                                Intent.ACTION_VIEW,
                                android.net.Uri.parse(url)
                            )
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("OPEN_FAILED", e.message, null)
                        }
                    }
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

    // ---------- 截图 / 录制保存到公共"下载"目录 ----------

    private data class PendingSave(
        val name: String,
        val subdir: String,
        val bytes: ByteArray,
        val mime: String,
        val result: MethodChannel.Result
    )

    private var pendingSave: PendingSave? = null

    private fun saveCaptureAsync(
        name: String,
        subdir: String,
        bytes: ByteArray,
        mime: String,
        result: MethodChannel.Result
    ) {
        // API 24~28 写公共目录需要存储权限；没有就先申请，授权后继续写
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            pendingSave = PendingSave(name, subdir, bytes, mime, result)
            requestPermissions(
                arrayOf(android.Manifest.permission.WRITE_EXTERNAL_STORAGE),
                REQUEST_WRITE_STORAGE
            )
            return
        }
        Thread {
            try {
                val path = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    saveToDownloads(name, subdir, bytes, mime)
                } else {
                    saveLegacy(name, subdir, bytes)
                }
                runOnUiThread { result.success(path) }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("SAVE_FAILED", e.message ?: "save failed", null)
                }
            }
        }.start()
    }

    /** API 29+：MediaStore Downloads（免权限，卸载应用后文件仍在下载目录） */
    private fun saveToDownloads(
        name: String,
        subdir: String,
        bytes: ByteArray,
        mime: String
    ): String {
        val relative = "Download/${CAPTURE_ROOT}" +
                (if (subdir.isEmpty()) "" else "/$subdir")
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, relative)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = contentResolver.insert(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI, values
        ) ?: throw IOException("MediaStore insert failed")
        try {
            contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                ?: throw IOException("openOutputStream failed")
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
        } catch (e: Exception) {
            try {
                contentResolver.delete(uri, null, null)
            } catch (_: Exception) {
            }
            throw e
        }
        return "$relative/$name"
    }

    /** API 24~28：直接写外部存储公共下载目录（已获存储权限） */
    private fun saveLegacy(name: String, subdir: String, bytes: ByteArray): String {
        val root = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            CAPTURE_ROOT
        )
        val dir = if (subdir.isEmpty()) root else File(root, subdir)
        if (!dir.exists() && !dir.mkdirs() && !dir.exists()) {
            throw IOException("mkdirs failed: ${dir.absolutePath}")
        }
        val f = File(dir, name)
        FileOutputStream(f).use { it.write(bytes) }
        MediaScannerConnection.scanFile(this, arrayOf(f.absolutePath), null, null)
        return f.absolutePath
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_WRITE_STORAGE) {
            val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
            val p = pendingSave
            if (p != null) {
                pendingSave = null
                if (granted) {
                    saveCaptureAsync(p.name, p.subdir, p.bytes, p.mime, p.result)
                } else {
                    p.result.error("PERMISSION_DENIED", "storage permission denied", null)
                }
                return
            }
            val q = pendingPublish
            if (q != null) {
                pendingPublish = null
                if (granted) {
                    publishFileAsync(q.src, q.name, q.subdir, q.mime, q.result)
                } else {
                    q.result.error("PERMISSION_DENIED", "storage permission denied", null)
                }
            }
        }
    }

    // ---------- 录制文件发布：私有目录 → 公共"下载"目录（流式复制，支持大文件） ----------

    private data class PendingPublish(
        val src: File,
        val name: String,
        val subdir: String,
        val mime: String,
        val result: MethodChannel.Result
    )

    private var pendingPublish: PendingPublish? = null

    private fun publishFileAsync(
        src: File,
        name: String,
        subdir: String,
        mime: String,
        result: MethodChannel.Result
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            pendingPublish = PendingPublish(src, name, subdir, mime, result)
            requestPermissions(
                arrayOf(android.Manifest.permission.WRITE_EXTERNAL_STORAGE),
                REQUEST_WRITE_STORAGE
            )
            return
        }
        Thread {
            try {
                val path = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    publishToDownloads(src, name, subdir, mime)
                } else {
                    publishLegacy(src, name, subdir)
                }
                runOnUiThread { result.success(path) }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("PUBLISH_FAILED", e.message ?: "publish failed", null)
                }
            }
        }.start()
    }

    /** API 29+：流式复制到 MediaStore Downloads */
    private fun publishToDownloads(
        src: File,
        name: String,
        subdir: String,
        mime: String
    ): String {
        val relative = "Download/${CAPTURE_ROOT}" +
                (if (subdir.isEmpty()) "" else "/$subdir")
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, relative)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = contentResolver.insert(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI, values
        ) ?: throw IOException("MediaStore insert failed")
        try {
            contentResolver.openOutputStream(uri)?.use { out ->
                src.inputStream().use { input ->
                    input.copyTo(out, 1024 * 1024)
                }
            } ?: throw IOException("openOutputStream failed")
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
        } catch (e: Exception) {
            try {
                contentResolver.delete(uri, null, null)
            } catch (_: Exception) {
            }
            throw e
        }
        return "$relative/$name"
    }

    /** API 24~28：流式复制到外部存储公共下载目录 */
    private fun publishLegacy(src: File, name: String, subdir: String): String {
        val root = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            CAPTURE_ROOT
        )
        val dir = if (subdir.isEmpty()) root else File(root, subdir)
        if (!dir.exists() && !dir.mkdirs() && !dir.exists()) {
            throw IOException("mkdirs failed: ${dir.absolutePath}")
        }
        val f = File(dir, name)
        src.inputStream().use { input ->
            FileOutputStream(f).use { out ->
                input.copyTo(out, 1024 * 1024)
            }
        }
        MediaScannerConnection.scanFile(this, arrayOf(f.absolutePath), null, null)
        return f.absolutePath
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
        private const val REQUEST_WRITE_STORAGE = 1002
        private const val PREFS = "m3u_prefs"
        // 下载目录下的软件子目录（与 Dart 端 CaptureStore.androidRoot 保持一致）
        private const val CAPTURE_ROOT = "M3U播放器"
    }
}

