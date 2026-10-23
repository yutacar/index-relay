#!/usr/bin/env python3
"""Generate an isolated simulator-only XCTest UI driver; never modifies app projects."""
from pathlib import Path
import json
import subprocess

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'work/ios-scene-ui'
OUT.mkdir(parents=True,exist_ok=True)
objects={}
def obj(isa,**values):
    key=f'{len(objects)+1:024X}';objects[key]=dict(isa=isa,**values);return key
hostFile=obj('PBXFileReference',lastKnownFileType='sourcecode.swift',path='Host.swift',sourceTree='<group>')
testFile=obj('PBXFileReference',lastKnownFileType='sourcecode.swift',path='LifecycleTests.swift',sourceTree='<group>')
hostProduct=obj('PBXFileReference',explicitFileType='wrapper.application',path='LifecycleHost.app',sourceTree='BUILT_PRODUCTS_DIR')
testProduct=obj('PBXFileReference',explicitFileType='wrapper.cfbundle',path='LifecycleTests.xctest',sourceTree='BUILT_PRODUCTS_DIR')
products=obj('PBXGroup',children=[hostProduct,testProduct],name='Products',sourceTree='<group>')
group=obj('PBXGroup',children=[hostFile,testFile,products],sourceTree='<group>')
def configs(extra):
    config=obj('XCBuildConfiguration',name='Debug',buildSettings=dict(SDKROOT='iphoneos',IPHONEOS_DEPLOYMENT_TARGET='26.0',SUPPORTED_PLATFORMS='iphonesimulator',TARGETED_DEVICE_FAMILY='1',SWIFT_VERSION='6.0',CODE_SIGNING_ALLOWED='NO',GENERATE_INFOPLIST_FILE='YES',PRODUCT_NAME='$(TARGET_NAME)',**extra))
    return obj('XCConfigurationList',buildConfigurations=[config],defaultConfigurationIsVisible=0,defaultConfigurationName='Debug')
def phases(file):
    build=obj('PBXBuildFile',fileRef=file)
    return [obj('PBXSourcesBuildPhase',buildActionMask=2147483647,files=[build],runOnlyForDeploymentPostprocessing=0),obj('PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0)]
host=obj('PBXNativeTarget',name='LifecycleHost',productName='LifecycleHost',productReference=hostProduct,productType='com.apple.product-type.application',buildConfigurationList=configs(dict(PRODUCT_BUNDLE_IDENTIFIER='dev.example.indexRelayLifecycleHost',INFOPLIST_KEY_UIApplicationSceneManifest_Generation='YES',INFOPLIST_KEY_UILaunchScreen_Generation='YES')),buildPhases=phases(hostFile),buildRules=[],dependencies=[])
test=obj('PBXNativeTarget',name='LifecycleTests',productName='LifecycleTests',productReference=testProduct,productType='com.apple.product-type.bundle.ui-testing',buildConfigurationList=configs(dict(PRODUCT_BUNDLE_IDENTIFIER='dev.example.indexRelayLifecycleTests',TEST_TARGET_NAME='LifecycleHost')),buildPhases=phases(testFile),buildRules=[],dependencies=[])
project=obj('PBXProject',attributes=dict(LastUpgradeCheck='2700',TargetAttributes={host:dict(CreatedOnToolsVersion='27.0'),test:dict(CreatedOnToolsVersion='27.0',TestTargetID=host)}),buildConfigurationList=configs({}),compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','Base'],mainGroup=group,productRefGroup=products,projectDirPath='',projectRoot='',targets=[host,test])
proxy=obj('PBXContainerItemProxy',containerPortal=project,proxyType=1,remoteGlobalIDString=host,remoteInfo='LifecycleHost')
objects[test]['dependencies']=[obj('PBXTargetDependency',target=host,targetProxy=proxy)]
p=OUT/'Lifecycle.xcodeproj';p.mkdir(exist_ok=True)
f=OUT/'project.json';f.write_text(json.dumps(dict(archiveVersion='1',classes={},objectVersion='56',objects=objects,rootObject=project)))
subprocess.run(['plutil','-convert','xml1','-o',str(p/'project.pbxproj'),str(f)],check=True)
schemes=p/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
def ref(key,name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{key}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:Lifecycle.xcodeproj"/>'
(schemes/'Lifecycle.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref(test,'LifecycleTests.xctest')}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref(test,'LifecycleTests.xctest')}</TestableReference></Testables></TestAction></Scheme>''')
(OUT/'Host.swift').write_text('import SwiftUI\n@main struct Host: App { var body: some Scene { WindowGroup { Text("Lifecycle test host") } } }\n')
(OUT/'LifecycleTests.swift').write_text('''import XCTest
final class LifecycleTests: XCTestCase {
    @MainActor func testThreeStartsAndResume() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.example.indexRelayProbe")
        app.launchEnvironment = ["INDEX_RELAY_SCENE_PROBE": "1"]
        for _ in 1...3 {
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
            // Native JSON evidence independently verifies Dart callback execution.
            Thread.sleep(forTimeInterval: 4)
            XCUIDevice.shared.press(.home)
            let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
            settings.activate()
            XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 30))
            Thread.sleep(forTimeInterval: 3)
            XCTAssertTrue(app.state == .runningBackground || app.state == .runningBackgroundSuspended,
                          "Resume must use the existing process, not relaunch a terminated app")
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
            Thread.sleep(forTimeInterval: 3)
            app.terminate()
        }
    }
}
''')
print('Prepared isolated UI driver')
