package com.example.ping_files

import io.flutter.embedding.android.FlutterActivity
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import org.maplibre.android.module.http.HttpRequestUtil

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // v95j: set a custom User-Agent for all MapLibre HTTP tile
        // requests. The OSM Tile Usage Policy
        // (https://operations.osmfoundation.org/policies/tiles/)
        // blocks traffic that uses a generic User-Agent
        // (e.g. MapLibreNative/x.y). Naming the app + a contact
        // (User-Agent + email per their example) keeps us out of
        // the block list. This MUST run before any MapView is
        // created, so it goes in MainActivity.onCreate before
        // super.onCreate.
        val pingmeeClient = OkHttpClient.Builder()
            .addInterceptor(Interceptor { chain ->
                val req = chain.request().newBuilder()
                    .header(
                        "User-Agent",
                        "Pingmee/1.0 (+https://pingmee.app; contact:nkanadavid74@gmail.com)"
                    )
                    .build()
                chain.proceed(req)
            })
            .build()
        HttpRequestUtil.setOkHttpClient(pingmeeClient)

        super.onCreate(savedInstanceState)
    }
}
