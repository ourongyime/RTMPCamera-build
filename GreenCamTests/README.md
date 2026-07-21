# GreenCam Tests ? 3 iOS Virtual Camera Tweak Approaches

Three independent, minimal jailbreak tweaks for testing camera frame replacement on iOS 16 rootless/roothide.

Each tweak injects a **solid green frame** into the system camera pipeline using a different hook technique.

## Quick Comparison

| Tweak | Technique | Source | Pros | Cons |
|---|---|---|---|---|
| **GreenCam-CFunc** | MSHookFunction on C function CMSampleBufferGetImageBuffer | VCAMClone | Catches ALL callers; no ObjC dispatch overhead | Modifies buffer in-place |
| **GreenCam-Swizzle** | Proxy-delegate swizzle on AVCaptureVideoDataOutput | DiCoy | Clean delegate intercept; no NSObject pollution | Complex; may miss non-AVCaptureVideoDataOutput paths |
| **GreenCam-NSObject** | Direct %hook NSObject on captureOutput:didOutputSampleBuffer:fromConnection: | Generic | Simplest; broadest ObjC coverage | Hooks ALL NSObject instances (tiny perf hit) |

## Build

On your Mac/WSL with Theos installed:

`ash
cd GreenCamTests/green-cfunc
make package
# -> packages/com.greencam.cfunc_1.0.0_iphoneos-arm64e.deb

cd GreenCamTests/green-swizzle
make package

cd GreenCamTests/green-nsobject
make package
`

Or build all three:

`ash
for d in green-cfunc green-swizzle green-nsobject; do
    (cd  && make package)
done
`

## Install & Test

`ash
# Install (pick ONE to test at a time)
ssh root@<device-ip> "dpkg -i /path/to/green-cfunc.deb && killall -9 SpringBoard"

# Verify loaded
ssh root@<device-ip> "cat /var/tmp/greencam_cfunc_loaded.txt"

# Open Camera app or any camera app -> should see solid GREEN

# Uninstall before testing next
ssh root@<device-ip> "dpkg -r com.greencam.cfunc && killall -9 SpringBoard"
`

## Uninstall

`ash
ssh root@<device-ip> "dpkg -r com.greencam.cfunc && dpkg -r com.greencam.swizzle && dpkg -r com.greencam.nsobject"
ssh root@<device-ip> "killall -9 SpringBoard"
`

## Troubleshooting

- If camera app crashes: try another tweak approach
- If no green: check if tweak loaded (ls /var/tmp/greencam_*_loaded.txt)
- If camera app uses non-AVFoundation API (rare): none of these will work
