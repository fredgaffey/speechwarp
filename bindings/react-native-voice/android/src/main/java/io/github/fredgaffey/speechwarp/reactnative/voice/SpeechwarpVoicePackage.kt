package io.github.fredgaffey.speechwarp.reactnative.voice

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider

class SpeechwarpVoicePackage : BaseReactPackage() {
    override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? =
        if (name == SpeechwarpVoiceModule.NAME) SpeechwarpVoiceModule(reactContext) else null

    override fun getReactModuleInfoProvider() = ReactModuleInfoProvider {
        mapOf(
            SpeechwarpVoiceModule.NAME to ReactModuleInfo(
                name = SpeechwarpVoiceModule.NAME,
                className = SpeechwarpVoiceModule.NAME,
                canOverrideExistingModule = false,
                needsEagerInit = false,
                isCxxModule = false,
                isTurboModule = true,
            )
        )
    }
}
