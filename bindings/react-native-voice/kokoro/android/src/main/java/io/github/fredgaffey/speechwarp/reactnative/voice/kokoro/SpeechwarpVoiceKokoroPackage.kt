package io.github.fredgaffey.speechwarp.reactnative.voice.kokoro

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider

class SpeechwarpVoiceKokoroPackage : BaseReactPackage() {
    override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? =
        if (name == SpeechwarpVoiceKokoroModule.NAME) SpeechwarpVoiceKokoroModule(reactContext) else null

    override fun getReactModuleInfoProvider() = ReactModuleInfoProvider {
        mapOf(
            SpeechwarpVoiceKokoroModule.NAME to ReactModuleInfo(
                name = SpeechwarpVoiceKokoroModule.NAME,
                className = SpeechwarpVoiceKokoroModule.NAME,
                canOverrideExistingModule = false,
                needsEagerInit = false,
                isCxxModule = false,
                isTurboModule = true,
            )
        )
    }
}
