package io.github.fredgaffey.speechwarp.reactnative.voice.espeak

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider

class SpeechwarpVoiceEspeakPackage : BaseReactPackage() {
    override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? =
        if (name == SpeechwarpVoiceEspeakModule.NAME) SpeechwarpVoiceEspeakModule(reactContext) else null

    override fun getReactModuleInfoProvider() = ReactModuleInfoProvider {
        mapOf(
            SpeechwarpVoiceEspeakModule.NAME to ReactModuleInfo(
                name = SpeechwarpVoiceEspeakModule.NAME,
                className = SpeechwarpVoiceEspeakModule.NAME,
                canOverrideExistingModule = false,
                needsEagerInit = false,
                isCxxModule = false,
                isTurboModule = true,
            )
        )
    }
}
