package com.horizontalzzz.horizoncooler

import android.content.Context
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
            when (call.method) {
                "getBatteryTemperature" -> {
                    val temp = readBatteryTemperature()
                    result.success(temp)
                }
                "enableLocation" -> {
                    try {
                        val intent = Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun readBatteryTemperature(): Double {
        return try {
            val batteryStatus: Intent? = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val rawTemp = batteryStatus?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1
            if (rawTemp > 0) {
                rawTemp / 10.0
            } else {
                0.0
            }
        } catch (e: Exception) {
            0.0
        }
    }
}
