package app.resona.client

import android.content.Context
import android.content.Intent
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var channel: MethodChannel? = null
    private var audioManager: AudioManager? = null
    private var deviceCallback: AudioDeviceCallback? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.resona/android_audio")
        channel = ch
        audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        registerAudioDeviceChanges()

        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "getAudioOutputs" -> result.success(currentOutputs())
                "acquireMulticastLock" -> {
                    acquireMulticastLock()
                    result.success(null)
                }
                "releaseMulticastLock" -> {
                    releaseMulticastLock()
                    result.success(null)
                }
                "openOutputSwitcher" -> {
                    openOutputSwitcher()
                    result.success(null)
                }
                "openBluetoothSettings" -> {
                    openBluetoothSettings()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun registerAudioDeviceChanges() {
        val manager = audioManager ?: return
        val cb = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
                channel?.invokeMethod("outputsChanged", mapOf("devices" to currentOutputs()))
            }

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
                val bluetoothRemoved = removedDevices?.any { isBluetoothType(it.type) } == true
                channel?.invokeMethod(
                    "outputsChanged",
                    mapOf("devices" to currentOutputs(), "bluetoothDisconnected" to bluetoothRemoved)
                )
            }
        }
        deviceCallback = cb
        manager.registerAudioDeviceCallback(cb, Handler(Looper.getMainLooper()))
    }

    private fun isBluetoothType(type: Int): Boolean {
        if (type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP || type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO) {
            return true
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && type == AudioDeviceInfo.TYPE_HEARING_AID) {
            return true
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            (type == AudioDeviceInfo.TYPE_BLE_HEADSET || type == AudioDeviceInfo.TYPE_BLE_SPEAKER)
        ) {
            return true
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            type == AudioDeviceInfo.TYPE_BLE_BROADCAST
        ) {
            return true
        }
        return false
    }

    private fun classifyOutputType(type: Int): String {
        if (isBluetoothType(type)) return "bluetooth"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && type == AudioDeviceInfo.TYPE_USB_HEADSET) {
            return "usb"
        }
        return when (type) {
            AudioDeviceInfo.TYPE_USB_DEVICE -> "usb"
            AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "headphones"
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "speaker"
            else -> "other"
        }
    }

    private fun currentOutputs(): List<Map<String, Any>> {
        val manager = audioManager ?: return emptyList()
        val devices = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val seen = HashSet<String>()
        val items = ArrayList<Map<String, Any>>()
        for (device in devices) {
            val kind = classifyOutputType(device.type)
            val label = device.productName?.toString()?.trim().orEmpty()
                .ifEmpty {
                    when (kind) {
                        "bluetooth" -> "蓝牙音频设备"
                        "headphones" -> "有线耳机"
                        "usb" -> "USB 音频"
                        "speaker" -> "手机扬声器"
                        else -> "音频输出"
                    }
                }
            val key = "${device.id}:$kind"
            if (!seen.add(key)) continue
            items.add(
                mapOf(
                    "id" to device.id.toString(),
                    "name" to label,
                    "type" to kind,
                    "bluetooth" to (kind == "bluetooth")
                )
            )
        }
        return items
    }

    private fun acquireMulticastLock() {
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
        if (multicastLock == null) {
            multicastLock = wifi.createMulticastLock("resona-dlna").apply {
                setReferenceCounted(false)
            }
        }
        if (multicastLock?.isHeld == false) {
            multicastLock?.acquire()
        }
    }

    private fun releaseMulticastLock() {
        try {
            if (multicastLock?.isHeld == true) {
                multicastLock?.release()
            }
        } catch (_: RuntimeException) {
            /* Ignore lock already released across Wi-Fi state changes. */
        }
    }

    private fun openOutputSwitcher() {
        val mediaSwitcher = Intent("com.android.systemui.action.LAUNCH_MEDIA_OUTPUT_DIALOG").apply {
            setPackage("com.android.systemui")
            putExtra("package_name", packageName)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (tryStart(mediaSwitcher)) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val panel = Intent(Settings.Panel.ACTION_VOLUME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (tryStart(panel)) return
        }
        openBluetoothSettings()
    }

    private fun openBluetoothSettings() {
        tryStart(Intent(Settings.ACTION_BLUETOOTH_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun tryStart(intent: Intent): Boolean {
        return try {
            startActivity(intent)
            true
        } catch (_: RuntimeException) {
            false
        }
    }

    override fun onDestroy() {
        val cb = deviceCallback
        if (cb != null) {
            audioManager?.unregisterAudioDeviceCallback(cb)
            deviceCallback = null
        }
        releaseMulticastLock()
        channel?.setMethodCallHandler(null)
        super.onDestroy()
    }
}
