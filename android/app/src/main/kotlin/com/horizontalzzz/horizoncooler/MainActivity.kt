package com.horizontalzzz.horizoncooler

import android.content.Intent
import android.content.IntentFilter
import android.location.LocationManager
import android.os.BatteryManager
import android.provider.Settings
import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "horizon_cooler/battery_temp"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getBatteryTemperature" -> {
                    result.success(readBatteryTemperature())
                }

                "openLocationSettings" -> {
                    result.success(openLocationSettings())
                }

                "isLocationServiceEnabled" -> {
                    result.success(isLocationServiceEnabled())
                }

                "enableLocation" -> {
                    result.success(openLocationSettings())
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun readBatteryTemperature(): Double {
        return try {
            val filter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
            val batteryIntent = registerReceiver(null, filter)

            val rawTemp = batteryIntent?.getIntExtra(
                BatteryManager.EXTRA_TEMPERATURE,
                Int.MIN_VALUE
            ) ?: Int.MIN_VALUE

            if (rawTemp == Int.MIN_VALUE) {
                return -1.0
            }

            val temperature = rawTemp / 10.0

            if (temperature < 0.0 || temperature > 100.0) {
                -1.0
            } else {
                temperature
            }
        } catch (e: Exception) {
            -1.0
        }
    }

    private fun isLocationServiceEnabled(): Boolean {
        return try {
            val manager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
            manager.isLocationEnabled
        } catch (e: Exception) {
            false
        }
    }

    private fun openLocationSettings(): Boolean {
        return try {
            val intent = Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}
