# Hypervisor.framework smoke test — local only, not wired into CI

This directory builds and boots the same round-trip smoke test as `Firmware/QEMU`, but for
`arm64-apple-none-macho` under Apple's `Hypervisor.framework` rather than under an emulator.
Run it yourself:

```sh
./Firmware/Hypervisor/build.sh
./Firmware/Hypervisor/run.sh \
    build/embedded/arm64-apple-none-macho/hypervisor/firmware.macho \
    build/embedded/arm64-apple-none-macho/hypervisor/loader
```

It is deliberately **not** part of `.github/workflows/embedded.yml`. Two things stack against
running it in CI specifically, as opposed to the `bare-metal` matrix's `arm64-apple-none-macho`
entry, which still compile-checks this target on every push:

- GitHub's `macos-*` runners are themselves VMs, and whether they expose nested virtualization
  to a guest process — what `hv_vm_create` needs to succeed at all — isn't documented reliably
  enough to build a hard CI requirement on.
- The runner's Xcode-bundled Swift toolchain does not ship the embedded standard library for
  this triple; getting one that does requires installing a separate swift.org toolchain
  (`sudo installer -pkg ... -target /`) as its own CI step, which is more moving parts than the
  value of running this one target's smoke test in CI currently justifies.

If either of those changes — GitHub documents nested-virt support, or the toolchain-install step
gets simpler — reconsider adding a job back. Until then, this is verified locally before each
change that touches it, the same way it was built in the first place.
