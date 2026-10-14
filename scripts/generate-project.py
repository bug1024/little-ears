from pathlib import Path
import hashlib
root = Path(__file__).resolve().parent.parent
def uid(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
objects = []
def obj(key, value):
    key = uid(key); objects.append(f'{key} = {{ {value} }};'); return key
files = sorted((root/'Sources/LittleEars').glob('*.swift'))
refs=[]; builds=[]
for f in files:
    r=obj(str(f.name), f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {f.name}; sourceTree = "<group>";')
    refs.append(r); builds.append(obj('build'+f.name, f'isa = PBXBuildFile; fileRef = {r};'))
product=obj('product','isa = PBXFileReference; explicitFileType = wrapper.application; path = "Little Ears.app"; sourceTree = BUILT_PRODUCTS_DIR;')
sourcegroup=obj('sources', 'isa = PBXGroup; path = Sources/LittleEars; sourceTree = "<group>"; children = ('+','.join(refs)+');')
icon=obj('icon','isa = PBXFileReference; lastKnownFileType = image.icns; path = Resources/AppIcon.icns; sourceTree = "<group>";')
iconbuild=obj('iconbuild', f'isa = PBXBuildFile; fileRef = {icon};')
plist=obj('plist','isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Resources/Info.plist; sourceTree = "<group>";')
products=obj('products', f'isa = PBXGroup; name = Products; sourceTree = "<group>"; children = ({product});')
group=obj('group', f'isa = PBXGroup; sourceTree = "<group>"; children = ({sourcegroup},{icon},{plist},{products});')
package=obj('package', 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/groue/GRDB.swift.git"; requirement = { kind = exactVersion; version = 7.0.0; };')
dep=obj('dep', f'isa = XCSwiftPackageProductDependency; package = {package}; productName = GRDB;')
depbuild=obj('depbuild', f'isa = PBXBuildFile; productRef = {dep};')
sources=obj('sourcephase','isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ('+','.join(builds)+'); runOnlyForDeploymentPostprocessing = 0;')
frameworks=obj('frameworkphase', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({depbuild}); runOnlyForDeploymentPostprocessing = 0;')
resources=obj('resourcephase', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({iconbuild}); runOnlyForDeploymentPostprocessing = 0;')
pconfigs=[]; tconfigs=[]
for name in ['Debug','Release']:
    pconfigs.append(obj('project'+name, f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ MACOSX_DEPLOYMENT_TARGET = 14.0; SDKROOT = macosx; SWIFT_VERSION = 5.0; }};'))
    extra='SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;' if name == 'Debug' else 'SWIFT_OPTIMIZATION_LEVEL = "-O";'
    tconfigs.append(obj('target'+name, f'''isa = XCBuildConfiguration; name = {name}; buildSettings = {{
        PRODUCT_NAME = "Little Ears"; PRODUCT_BUNDLE_IDENTIFIER = com.bug1024.littleears;
        INFOPLIST_FILE = Resources/Info.plist; GENERATE_INFOPLIST_FILE = NO;
        CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; ENABLE_APP_SANDBOX = NO;
        COMBINE_HIDPI_IMAGES = YES; EXECUTABLE_NAME = LittleEars; PRODUCT_MODULE_NAME = LittleEars; ENABLE_DEBUG_DYLIB = NO; ALWAYS_SEARCH_USER_PATHS = NO; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";
        {extra} }};'''))
pc=obj('projectconfigs','isa = XCConfigurationList; buildConfigurations = ('+','.join(pconfigs)+'); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
tc=obj('targetconfigs','isa = XCConfigurationList; buildConfigurations = ('+','.join(tconfigs)+'); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target=obj('target', f'isa = PBXNativeTarget; name = LittleEars; productName = "Little Ears"; productReference = {product}; productType = "com.apple.product-type.application"; buildConfigurationList = {tc}; buildPhases = ({sources},{frameworks},{resources}); buildRules = (); dependencies = (); packageProductDependencies = ({dep});')
project=obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {pc}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target}); packageReferences = ({package});')
p=root/'LittleEars.xcodeproj'; p.mkdir(exist_ok=True)
(p/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {project}; }}\n')
