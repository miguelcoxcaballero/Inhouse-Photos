package com.inhousesoftware.photos

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.ext.SdkExtensions
import com.inhousesoftware.photos.background.BackgroundEngineLock
import com.inhousesoftware.photos.background.BackgroundWorkerApiImpl
import com.inhousesoftware.photos.background.BackgroundWorkerFgHostApi
import com.inhousesoftware.photos.background.BackgroundWorkerLockApi
import com.inhousesoftware.photos.connectivity.ConnectivityApi
import com.inhousesoftware.photos.connectivity.ConnectivityApiImpl
import com.inhousesoftware.photos.core.HttpClientManager
import com.inhousesoftware.photos.core.ImmichPlugin
import com.inhousesoftware.photos.core.NetworkApiPlugin
import me.albemala.native_video_player.NativeVideoPlayerPlugin
import com.inhousesoftware.photos.images.LocalImageApi
import com.inhousesoftware.photos.images.LocalImagesImpl
import com.inhousesoftware.photos.images.RemoteImageApi
import com.inhousesoftware.photos.images.RemoteImagesImpl
import com.inhousesoftware.photos.permission.PermissionApi
import com.inhousesoftware.photos.permission.PermissionApiImpl
import com.inhousesoftware.photos.sync.NativeSyncApi
import com.inhousesoftware.photos.sync.NativeSyncApiImpl26
import com.inhousesoftware.photos.sync.NativeSyncApiImpl30
import com.inhousesoftware.photos.viewintent.ViewIntentPlugin
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterFragmentActivity() {
  private var updateInstaller: UpdateInstaller? = null

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    registerPlugins(this, flutterEngine)
    updateInstaller = UpdateInstaller(this, flutterEngine.dartExecutor.binaryMessenger)
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
  }

  override fun onDestroy() {
    updateInstaller?.dispose()
    updateInstaller = null
    super.onDestroy()
  }

  companion object {
    fun registerPlugins(ctx: Context, flutterEngine: FlutterEngine) {
      HttpClientManager.initialize(ctx)
      NativeVideoPlayerPlugin.dataSourceFactory = HttpClientManager::createDataSourceFactory
      flutterEngine.plugins.add(NetworkApiPlugin())

      val messenger = flutterEngine.dartExecutor.binaryMessenger
      val backgroundEngineLockImpl = BackgroundEngineLock(ctx)
      BackgroundWorkerLockApi.setUp(messenger, backgroundEngineLockImpl)
      val nativeSyncApiImpl =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || SdkExtensions.getExtensionVersion(Build.VERSION_CODES.R) < 1) {
          NativeSyncApiImpl26(ctx)
        } else {
          NativeSyncApiImpl30(ctx)
        }
      val permissionApiImpl = PermissionApiImpl(ctx)
      NativeSyncApi.setUp(messenger, nativeSyncApiImpl)
      PermissionApi.setUp(messenger, permissionApiImpl)
      LocalImageApi.setUp(messenger, LocalImagesImpl(ctx))
      RemoteImageApi.setUp(messenger, RemoteImagesImpl(ctx))

      BackgroundWorkerFgHostApi.setUp(messenger, BackgroundWorkerApiImpl(ctx))
      ConnectivityApi.setUp(messenger, ConnectivityApiImpl(ctx))

      flutterEngine.plugins.add(ViewIntentPlugin())
      flutterEngine.plugins.add(backgroundEngineLockImpl)
      flutterEngine.plugins.add(nativeSyncApiImpl)
      flutterEngine.plugins.add(permissionApiImpl)
    }

    fun cancelPlugins(flutterEngine: FlutterEngine) {
      val nativeApi =
        flutterEngine.plugins.get(NativeSyncApiImpl26::class.java) as ImmichPlugin?
          ?: flutterEngine.plugins.get(NativeSyncApiImpl30::class.java) as ImmichPlugin?
      nativeApi?.detachFromEngine()
      val permissionApi = flutterEngine.plugins.get(PermissionApiImpl::class.java) as ImmichPlugin?
      permissionApi?.detachFromEngine()
    }
  }
}
