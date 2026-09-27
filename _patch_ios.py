import os, subprocess
os.chdir(os.path.expanduser('~/dsh-ios-lab/apps/home-iptv'))

s = open('project.yml').read()
s = s.replace('platform: tvOS', 'platform: iOS')
s = s.replace('tvos:', 'ios:')
s = s.replace('TARGETED_DEVICE_FAMILY: "3"', 'TARGETED_DEVICE_FAMILY: "1,2"')
s = s.replace('SDKROOT: appletvos', 'SDKROOT: iphoneos')
s = s.replace('SUPPORTED_PLATFORMS: appletvos appletvsimulator', 'SUPPORTED_PLATFORMS: iphoneos iphonesimulator')
open('project.yml','w').write(s)

os.environ['PATH'] = os.path.expanduser('~/.local/bin') + ':' + os.environ['PATH']
subprocess.run(['rm','-rf','HomeIPTV.xcodeproj'])
subprocess.run(['xcodegen','generate'], check=True)
r = subprocess.run(['xcodebuild','-project','HomeIPTV.xcodeproj','-scheme','HomeIPTV',
    '-destination','id=098EC470-E181-419F-846B-476BBAC23327',
    '-configuration','Debug','build','CODE_SIGNING_ALLOWED=NO'],
    capture_output=True, text=True)
out = (r.stdout + '\n' + r.stderr).splitlines()
print('\n'.join(out[-30:]))
print('EXIT:', r.returncode)
