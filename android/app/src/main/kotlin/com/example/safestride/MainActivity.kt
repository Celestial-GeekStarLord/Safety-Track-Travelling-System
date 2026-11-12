package com.example.safestride

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                "alerts", "SafeStride alerts", NotificationManager.IMPORTANCE_HIGH)
            channel.description = "Unexpected stops, boundary crossings and distance alerts"
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }
}