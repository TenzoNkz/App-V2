package com.horizontalzzz.horizoncooler

import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "horizon_cooler/battery_temp"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getBatteryTemperature") {
                val temp = getBatteryTemperature()
                result.success(temp.toDouble())
            } else if (call.method == "enableLocation") {
                // MEMAKSA MUNCULNYA HALAMAN AKTIVASI GPS JIKA LOKASI MATI
                val intent = Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
    }

    private fun getBatteryTemperature(): Float {
        // Menggunakan applicationContext agar tidak pernah bocor/hilang
        val intent = context.applicationContext.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val rawTemp = intent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1
        return if (rawTemp != -1) rawTemp / 10.0f else 0.0f
    }
}
