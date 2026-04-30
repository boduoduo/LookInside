Pod::Spec.new do |s|
  s.name             = 'LookinServer'
  s.version          = '1.2.0'
  s.summary          = 'In-app inspection runtime for the LookInside (Lookin) UI debugger.'
  s.description      = <<-DESC
                       LookinServer is the in-app runtime that the LookInside / Lookin
                       desktop app talks to in order to inspect and modify a running
                       iOS, tvOS or macOS application's UI hierarchy.

                       This pod mirrors the `LookinServer` SwiftPM product defined in
                       Package.swift and is intended to be linked into Debug builds of
                       a host application only.
                       DESC
  s.homepage         = 'https://github.com/boduoduo/LookInside'
  s.license          = { :type => 'GPL-3.0', :file => 'LICENSE' }
  s.author           = { 'Lookin' => 'https://lookin.work' }
  s.source           = { :git => 'https://github.com/boduoduo/LookInside.git', :tag => s.version.to_s }

  s.ios.deployment_target     = '12.0'
  s.tvos.deployment_target    = '12.0'
  s.osx.deployment_target     = '11.0'
  s.visionos.deployment_target = '1.0'

  s.requires_arc   = true
  s.swift_versions = ['5.0']

  # Mirrors Package.swift exactly:
  #   - LookinServerBase  (Sources/LookinServerBase)
  #   - LookinCore        (Sources/LookinCore) — canonical "Shared" sources;
  #                       the Sources/LookinServer/Shared mirror is intentionally
  #                       excluded just like SwiftPM's `exclude: ["Shared"]`.
  #   - LookinServerSwift (Sources/LookinServerSwift)
  #   - LookinServer      (Sources/LookinServer/Server)
  s.source_files = [
    'Sources/LookinServerBase/**/*.{h,m}',
    'Sources/LookinCore/**/*.{h,m,mm}',
    'Sources/LookinServerSwift/**/*.{swift}',
    'Sources/LookinServer/include/*.h',
    'Sources/LookinServer/Server/**/*.{c,h,m,mm}',
  ]

  s.public_header_files = [
    'Sources/LookinServer/include/LookinServer.h',
    # Must be public so Swift sources in `LookinServerSwift` can see
    # `LookinIvarTrace` / `LookinIvarTraceRelationValue_Self` / the
    # `NSObject (LookinServerTrace)` category through the pod's umbrella module.
    'Sources/LookinServerBase/LookinIvarTrace.h',
  ]

  s.ios.frameworks     = ['UIKit', 'CoreGraphics', 'QuartzCore']
  s.tvos.frameworks    = ['UIKit', 'CoreGraphics', 'QuartzCore']
  s.osx.frameworks     = ['AppKit', 'CoreGraphics', 'QuartzCore']
  s.visionos.frameworks = ['UIKit', 'CoreGraphics', 'QuartzCore']

  # All platforms (iOS / tvOS / macOS / visionOS) share one source tree; per-platform
  # code paths are gated by `TARGET_OS_IPHONE` / `TARGET_OS_OSX` / `TARGET_OS_VISION`
  # in the .h/.m files (and `canImport(AppKit/UIKit)` in Swift), so no per-platform
  # `source_files` split is required.

  s.pod_target_xcconfig = {
    # NOTE: Do NOT define `SPM_LOOKIN_SERVER_ENABLED` here. That flag is the
    # SwiftPM-only signal that `LookinServerBase` is a separate Swift module
    # (so `LKS_SwiftTraceManager.swift` does `import LookinServerBase`).
    # CocoaPods ships everything as a single `LookinServer` module, and Swift
    # accesses ObjC types like `LookinIvarTrace` via the pod's own auto-generated
    # module map. Defining the SPM flag here would trigger an import of a
    # non-existent module and fail the build.
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) SHOULD_COMPILE_LOOKIN_SERVER=1',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => '$(inherited) SHOULD_COMPILE_LOOKIN_SERVER',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'gnu++17',
    'DEFINES_MODULE' => 'YES',
  }

  # macOS apps are typically signed with the hardened runtime / app sandbox; the
  # inspection runtime is meant for Debug-only integration. Consumers should gate
  # the dependency in their Podfile, e.g.:
  #
  #   pod 'LookinServer', :configurations => ['Debug']
end
